//
//  FileIndexer.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation
import SQLite3
import os
import Vision
import AppKit
import ImageIO
import PDFKit

/// Tells SQLite to copy bound strings, so Swift temporaries can't dangle.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Indexing progress, published on its own so only the views that show it redraw as it ticks
/// (twice a second during a run), not everything that observes the indexer.
final class IndexingProgress: ObservableObject {
    /// Files scanned so far in the current run
    @Published fileprivate(set) var filesChecked = 0
    /// File whose text is being extracted, when that is what the run is waiting on
    @Published fileprivate(set) var currentFileName: String?
}

struct IndexStats: Equatable {
    var count = 0
    var totalSize: Int64 = 0
}

enum AddFolderResult {
    case added(String)
    case alreadyIndexed
    case coveredBy(String)
}

final class FileIndexer: ObservableObject {
    private var db: OpaquePointer?
    let dbPath: String
    private let configPath: String
    /// Read-only connection for searches and the folder picker. The database is in WAL mode,
    /// so these reads don't wait while indexing writes on `db`.
    private var readDB: OpaquePointer?
    private let readQueue = DispatchQueue(label: "com.mattgrilli.dexxer.read", qos: .userInitiated)
    /// All writes (and indexing's own reads) go through this serial queue. Never call `dbQueue.sync` from code already on it.
    private let dbQueue = DispatchQueue(label: "com.mattgrilli.dexxer.db", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.mattgrilli.dexxer", category: "indexing")

    static let isoFormatter = ISO8601DateFormatter()

    @Published private(set) var indexedFolders: [String] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var isCancellingIndex = false
    @Published private(set) var currentlyIndexing: String?
    let progress = IndexingProgress()
    @Published private(set) var stats = IndexStats()
    @Published private(set) var folderFileCounts: [String: Int] = [:]
    /// Last known reachability per indexed folder. Checked off the main thread because a hung
    /// network mount can block file system calls for a long time.
    @Published private(set) var reachability: [String: Bool] = [:]
    /// Folders the last run skipped because they were offline
    @Published private(set) var lastSkippedFolders: [String] = []
    /// Set when text recognition stopped responding during the last run, so scans were skipped
    @Published private(set) var textRecognitionStalled = false
    /// When each folder last finished a complete scan (stopped or interrupted runs don't count)
    @Published private(set) var lastIndexed: [String: Date] = [:]

    @Published var excludePatternsEnabled: Bool {
        didSet { UserDefaults.standard.set(excludePatternsEnabled, forKey: Keys.excludePatterns) }
    }
    @Published var ocrEnabled: Bool {
        didSet { UserDefaults.standard.set(ocrEnabled, forKey: Keys.ocr) }
    }
    @Published var autoReindexEnabled: Bool {
        didSet { UserDefaults.standard.set(autoReindexEnabled, forKey: Keys.autoReindex) }
    }

    let excludedFolders = [".git", ".svn", "node_modules", ".Trash", "__pycache__", ".cache", "venv", "build", "dist", ".idea", ".vscode"]
    let excludedFiles = [".DS_Store", "Thumbs.db", "desktop.ini", "._*"]

    private let cancelRequested = OSAllocatedUnfairLock(initialState: false)
    private var isCancelled: Bool { cancelRequested.withLock { $0 } }

    // Text recognition safeguards. Only touched from the indexing thread during a run.
    /// Longest a single OCR call may take. Vision can stop responding entirely (seen on macOS 27.0.1),
    /// and without a limit that hangs indexing, and Stop, forever.
    private static let ocrTimeout: TimeInterval = 60
    /// After this many timeouts in one run, skip OCR for the rest of it
    private static let maxOCRTimeouts = 2
    private var ocrTimeouts = 0
    /// Set when the current file's text couldn't be fully extracted, so it's retried next run
    private var extractionIncomplete = false
    /// Folders requested while a run was in progress; indexed when it finishes
    private var queuedFolders: [String] = []
    private var reachabilityCheckInFlight = false

    private enum Keys {
        static let excludePatterns = "DexxerExcludePatternsEnabled"
        static let ocr = "DexxerOCREnabled"
        static let autoReindex = "DexxerAutoReindex"
    }

    /// Bump when text extraction improves so existing rows get re-extracted.
    /// v1: full PDF text layer plus OCR of scanned pages (v0 only OCR'd page 1).
    static let textExtractionVersion = 1
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]
    private static let maxTextLength = 200_000
    private static let maxOCRPagesPerPDF = 20
    private static let batchSize = 500

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        dbPath = directory.appendingPathComponent(".dexxer.db").path
        configPath = directory.appendingPathComponent(".dexxer_config.json").path

        let defaults = UserDefaults.standard
        excludePatternsEnabled = defaults.object(forKey: Keys.excludePatterns) as? Bool ?? true
        ocrEnabled = defaults.object(forKey: Keys.ocr) as? Bool ?? false
        autoReindexEnabled = defaults.object(forKey: Keys.autoReindex) as? Bool ?? true
        // Leftovers from the old crash-recovery scheme, which deleted data on relaunch
        defaults.removeObject(forKey: "DexxerIndexingInProgress")
        defaults.removeObject(forKey: "DexxerLastIndexedFolder")

        openDatabase()
        if sqlite3_open_v2(dbPath, &readDB, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            logger.error("Could not open read connection; searches will share the write connection")
            sqlite3_close(readDB)
            readDB = nil
        }
        loadConfig()

        // The OCR setting used to reset on every launch. If the index already has
        // extracted text, keep extracting so re-indexing doesn't silently stop.
        if defaults.object(forKey: Keys.ocr) == nil, hasExtractedText() {
            ocrEnabled = true
            defaults.set(true, forKey: Keys.ocr)
        }

        verifyFTSIndex()
        refreshStats()
        refreshReachability()
    }

    deinit {
        sqlite3_close(readDB)
        sqlite3_close(db)
    }

    // MARK: - SQLite helpers

    private enum SQLValue {
        case text(String)
        case int(Int64)
        case null
    }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    /// The connection for search reads, falling back to the main one if it couldn't open
    private var searchDB: OpaquePointer? { readDB ?? db }
    private var searchQueue: DispatchQueue { readDB == nil ? dbQueue : readQueue }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            logger.error("SQL failed: \(message, privacy: .public)")
            return false
        }
        return true
    }

    private func bind(_ params: [SQLValue], to statement: OpaquePointer) {
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
    }

    /// Runs a statement and calls `row` for each result row. Call on the queue that owns
    /// `connection`: `dbQueue` for the main connection (the default), `searchQueue` for `searchDB`.
    @discardableResult
    private func query(_ sql: String, _ params: [SQLValue] = [], on connection: OpaquePointer? = nil,
                       row: (OpaquePointer) -> Void = { _ in }) -> Bool {
        let connection = connection ?? db
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            logger.error("Prepare failed: \(String(cString: sqlite3_errmsg(connection)), privacy: .public)")
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(params, to: statement)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return true
            default:
                logger.error("Step failed: \(String(cString: sqlite3_errmsg(connection)), privacy: .public)")
                return false
            }
        }
    }

    private static func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func likeEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Schema

    private func openDatabase() {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            logger.error("Could not open database at \(self.dbPath, privacy: .public)")
            return
        }

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE,
            name TEXT,
            extension TEXT,
            size INTEGER,
            modified_time TEXT,
            indexed_time TEXT,
            folder_root TEXT,
            ocr_text TEXT,
            text_version INTEGER NOT NULL DEFAULT 0
        )
        """)

        // Migrations for databases created by earlier versions
        if !columnExists("ocr_text") { exec("ALTER TABLE files ADD COLUMN ocr_text TEXT") }
        if !columnExists("text_version") { exec("ALTER TABLE files ADD COLUMN text_version INTEGER NOT NULL DEFAULT 0") }

        exec("CREATE INDEX IF NOT EXISTS idx_name ON files(name)")
        exec("CREATE INDEX IF NOT EXISTS idx_extension ON files(extension)")
        exec("CREATE INDEX IF NOT EXISTS idx_folder_root ON files(folder_root)")
        exec("CREATE INDEX IF NOT EXISTS idx_modified ON files(modified_time)")

        createFTSTable()

        var hasFolderState = false
        query("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'folder_state')") {
            hasFolderState = sqlite3_column_int($0, 0) == 1
        }
        exec("""
        CREATE TABLE IF NOT EXISTS folder_state (
            root TEXT PRIMARY KEY,
            last_indexed TEXT NOT NULL
        )
        """)
        if !hasFolderState {
            // Upgrading: approximate from the newest row written for each folder
            exec("INSERT INTO folder_state SELECT folder_root, MAX(indexed_time) FROM files WHERE folder_root IS NOT NULL GROUP BY folder_root")
        }
        query("SELECT root, last_indexed FROM folder_state") {
            lastIndexed[Self.columnText($0, 0)] = Self.isoFormatter.date(from: Self.columnText($0, 1))
        }
    }

    private func columnExists(_ column: String) -> Bool {
        var exists = false
        query("SELECT COUNT(*) FROM pragma_table_info('files') WHERE name = ?", [.text(column)]) {
            exists = sqlite3_column_int($0, 0) > 0
        }
        return exists
    }

    private func createFTSTable() {
        // Early versions created the index without ocr_text, and CREATE ... IF NOT EXISTS never
        // upgrades it, so extracted text was stored but never searchable. Recreate it here;
        // verifyFTSIndex then sees it's empty and rebuilds it from the files table.
        var hasTextColumn = true
        query("SELECT COUNT(*) FROM pragma_table_info('files_fts') WHERE name = 'ocr_text'") {
            hasTextColumn = sqlite3_column_int($0, 0) > 0
        }
        var ftsExists = false
        query("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'files_fts')") {
            ftsExists = sqlite3_column_int($0, 0) == 1
        }
        let recreating = ftsExists && !hasTextColumn
        if recreating {
            logger.warning("Search index is missing extracted text; recreating it")
            exec("DROP TRIGGER IF EXISTS files_fts_insert")
            exec("DROP TRIGGER IF EXISTS files_fts_delete")
            exec("DROP TRIGGER IF EXISTS files_fts_update")
            exec("DROP TABLE files_fts")
        }

        exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
            name, path, ocr_text,
            content='files', content_rowid='id'
        )
        """)

        // Triggers keep the FTS index in sync with the files table
        exec("""
        CREATE TRIGGER IF NOT EXISTS files_fts_insert AFTER INSERT ON files BEGIN
            INSERT INTO files_fts(rowid, name, path, ocr_text)
            VALUES (new.id, new.name, new.path, new.ocr_text);
        END
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS files_fts_delete AFTER DELETE ON files BEGIN
            INSERT INTO files_fts(files_fts, rowid, name, path, ocr_text)
            VALUES ('delete', old.id, old.name, old.path, old.ocr_text);
        END
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS files_fts_update AFTER UPDATE ON files BEGIN
            INSERT INTO files_fts(files_fts, rowid, name, path, ocr_text)
            VALUES ('delete', old.id, old.name, old.path, old.ocr_text);
            INSERT INTO files_fts(rowid, name, path, ocr_text)
            VALUES (new.id, new.name, new.path, new.ocr_text);
        END
        """)

        // Fill the recreated index now (about half a second for 50k files), so searches,
        // which use a separate connection, never see it empty
        if recreating {
            exec("INSERT INTO files_fts(files_fts) VALUES('rebuild')")
        }
    }

    private func hasExtractedText() -> Bool {
        var found = false
        query("SELECT EXISTS(SELECT 1 FROM files WHERE ocr_text IS NOT NULL AND ocr_text != '')") {
            found = sqlite3_column_int($0, 0) == 1
        }
        return found
    }

    // MARK: - FTS5 maintenance

    /// Rebuilds the FTS index if it has drifted from the files table.
    /// `files_fts_docsize` holds one row per indexed document; counting `files_fts`
    /// itself would just count the content table and never show a mismatch.
    private func verifyFTSIndex() {
        dbQueue.async {
            var files = 0
            var indexed = 0
            self.query("SELECT COUNT(*) FROM files") { files = Int(sqlite3_column_int64($0, 0)) }
            self.query("SELECT COUNT(*) FROM files_fts_docsize") { indexed = Int(sqlite3_column_int64($0, 0)) }

            if files != indexed {
                self.logger.warning("FTS index out of sync (\(files) files, \(indexed) indexed); rebuilding")
                self.exec("INSERT INTO files_fts(files_fts) VALUES('rebuild')")
            }
        }
    }

    /// Rebuilds the full-text index from the files table, then compacts it.
    func rebuildSearchIndex(completion: @escaping () -> Void) {
        dbQueue.async {
            self.exec("INSERT INTO files_fts(files_fts) VALUES('rebuild')")
            self.exec("INSERT INTO files_fts(files_fts) VALUES('optimize')")
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - Folders

    private func loadConfig() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let folders = try? JSONDecoder().decode([String].self, from: data) else { return }
        var seen = Set<String>()
        indexedFolders = folders.filter { seen.insert($0).inserted }
    }

    private func saveConfig() {
        do {
            try JSONEncoder().encode(indexedFolders).write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch {
            logger.error("Failed to save folder list: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds a folder the user picked or dropped, remembering sandbox access to it.
    func addFolder(_ url: URL) -> AddFolderResult {
        // Resolve symlinks (e.g. /var -> /private/var) so the root matches the paths the scan records.
        // realpath, because URL.resolvingSymlinksInPath deliberately strips /private again.
        let standardized = url.standardizedFileURL.path
        let path = realpath(standardized, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        } ?? standardized
        if indexedFolders.contains(path) {
            BookmarkStore.save(path: path, url: url)  // refresh access anyway
            return .alreadyIndexed
        }
        if let root = indexedFolders.first(where: { path.hasPrefix($0 + "/") }) {
            return .coveredBy(root)
        }

        BookmarkStore.save(path: path, url: url)
        indexedFolders.append(path)
        saveConfig()
        refreshReachability()
        return .added(path)
    }

    func removeFolder(_ path: String) {
        indexedFolders.removeAll { $0 == path }
        queuedFolders.removeAll { $0 == path }
        saveConfig()
        BookmarkStore.remove(path: path)
        reachability[path] = nil
        lastIndexed[path] = nil

        dbQueue.async {
            self.query("DELETE FROM files WHERE folder_root = ?", [.text(path)])
            self.query("DELETE FROM folder_state WHERE root = ?", [.text(path)])
            self.refreshStatsOnQueue()
        }
    }

    /// Re-records sandbox access after the user re-selects a folder that lost it.
    func grantAccess(to path: String, using url: URL) {
        BookmarkStore.save(path: path, url: url)
        refreshReachability()
    }

    // MARK: - Status

    func refreshStats() {
        dbQueue.async { self.refreshStatsOnQueue() }
    }

    private func refreshStatsOnQueue() {
        var stats = IndexStats()
        var counts: [String: Int] = [:]
        query("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files") {
            stats = IndexStats(count: Int(sqlite3_column_int64($0, 0)), totalSize: sqlite3_column_int64($0, 1))
        }
        query("SELECT folder_root, COUNT(*) FROM files GROUP BY folder_root") {
            counts[Self.columnText($0, 0)] = Int(sqlite3_column_int64($0, 1))
        }
        DispatchQueue.main.async {
            self.stats = stats
            self.folderFileCounts = counts
        }
    }

    func refreshReachability() {
        guard !reachabilityCheckInFlight else { return }
        reachabilityCheckInFlight = true
        let folders = indexedFolders

        DispatchQueue.global(qos: .utility).async {
            let result = Dictionary(folders.map { ($0, self.isReachableFolder($0)) }, uniquingKeysWith: { first, _ in first })
            DispatchQueue.main.async {
                self.reachability = result
                self.reachabilityCheckInFlight = false
            }
        }
    }

    func isReachable(_ folder: String) -> Bool {
        reachability[folder] ?? true
    }

    // MARK: - Indexing

    private struct IndexOptions {
        let extractText: Bool
        let excludedFolders: Set<String>
        let excludedFiles: [String]
    }

    private struct ExistingRow {
        let size: Int64
        let modified: String
        let hasText: Bool
        let textVersion: Int
    }

    private struct FileRecord {
        let path: String
        let name: String
        let ext: String
        let size: Int64
        let modified: String
        let text: String?
        let textVersion: Int
    }

    /// Re-indexes folders that are online and haven't finished a scan within `maxAge`.
    /// Cheap when little has changed, since only new and changed files are read.
    func indexStaleFolders(olderThan maxAge: TimeInterval) {
        guard autoReindexEnabled, !isIndexing else { return }
        let stale = indexedFolders.filter { folder in
            guard isReachable(folder) else { return false }
            guard let last = lastIndexed[folder] else { return true }
            return Date().timeIntervalSince(last) > maxAge
        }
        if !stale.isEmpty {
            logger.info("Automatically re-indexing \(stale.count) folders")
            indexFolders(stale)
        }
    }

    func cancelIndexing() {
        guard isIndexing else { return }
        queuedFolders.removeAll()
        cancelRequested.withLock { $0 = true }
        isCancellingIndex = true
    }

    /// Indexes the given folders (all folders when nil). If a run is already going, the
    /// folders are queued and indexed when it finishes. Call from the main thread.
    func indexFolders(_ folders: [String]? = nil, completion: ((Int) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let targets = folders ?? indexedFolders
        guard !targets.isEmpty else { return }

        if isIndexing {
            queuedFolders += targets.filter { !queuedFolders.contains($0) }
            return
        }

        isIndexing = true
        isCancellingIndex = false
        progress.filesChecked = 0
        cancelRequested.withLock { $0 = false }
        textRecognitionStalled = false
        ocrTimeouts = 0

        // Snapshot settings on the main thread so the background run never reads them mid-change
        let options = IndexOptions(
            extractText: ocrEnabled,
            excludedFolders: excludePatternsEnabled ? Set(excludedFolders) : [],
            excludedFiles: excludePatternsEnabled ? excludedFiles : []
        )

        DispatchQueue.global(qos: .utility).async {
            var total = 0
            var skipped: [String] = []

            for root in targets {
                if self.isCancelled { break }
                guard self.isReachableFolder(root) else {
                    skipped.append(root)
                    continue
                }
                DispatchQueue.main.async { self.currentlyIndexing = root }
                total += self.indexFolder(root, options: options, progressBase: total)
                self.dbQueue.async { self.refreshStatsOnQueue() }
            }

            self.logger.info("Indexing finished: \(total) files scanned, \(skipped.count) folders skipped")

            DispatchQueue.main.async {
                self.isIndexing = false
                self.isCancellingIndex = false
                self.currentlyIndexing = nil
                self.progress.currentFileName = nil
                self.progress.filesChecked = total
                self.lastSkippedFolders = skipped
                self.refreshReachability()
                completion?(total)

                let queued = self.queuedFolders.filter { self.indexedFolders.contains($0) }
                self.queuedFolders.removeAll()
                if !queued.isEmpty { self.indexFolders(queued) }
            }
        }
    }

    /// Scans one root and brings its rows up to date. Unchanged files are left alone, so their
    /// extracted text survives, and an interrupted run never loses entries that already existed.
    private func indexFolder(_ root: String, options: IndexOptions, progressBase: Int) -> Int {
        let scopedURL = BookmarkStore.resolve(path: root)
        let didStartScope = scopedURL?.startAccessingSecurityScopedResource() ?? false
        defer { if didStartScope { scopedURL?.stopAccessingSecurityScopedResource() } }

        let existing = existingRows(in: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var unreadable: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                unreadable.append(url.path)
                return true
            }
        ) else {
            logger.error("Could not enumerate \(root, privacy: .public)")
            return 0
        }

        var seen = Set<String>()
        var batch: [FileRecord] = []
        var scanned = 0
        var lastReport = Date.distantPast
        var lastWrite = Date()

        // Throttled by time rather than file count: reading PDFs over a VPN can take seconds each
        func report(reading fileName: String? = nil) {
            guard Date().timeIntervalSince(lastReport) >= 0.5 else { return }
            lastReport = Date()
            let progress = progressBase + scanned
            DispatchQueue.main.async {
                self.progress.filesChecked = progress
                self.progress.currentFileName = fileName
            }
        }

        for case let url as URL in enumerator {
            if isCancelled { break }

            let record: FileRecord? = autoreleasepool {
                guard let values = try? url.resourceValues(forKeys: keySet) else { return nil }
                if values.isDirectory == true {
                    if options.excludedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                    return nil
                }
                guard values.isRegularFile == true, !isExcluded(url.lastPathComponent, options) else { return nil }

                let path = url.path
                seen.insert(path)
                scanned += 1

                let size = Int64(values.fileSize ?? 0)
                let modified = Self.isoFormatter.string(from: values.contentModificationDate ?? Date())
                let ext = url.pathExtension.lowercased()
                let wantsText = options.extractText && Self.supportsTextExtraction(ext)

                if let old = existing[path], old.size == size, old.modified == modified {
                    let textIsCurrent = old.hasText && (ext != "pdf" || old.textVersion >= Self.textExtractionVersion)
                    if !wantsText || textIsCurrent { return nil }  // unchanged
                }

                // An empty string marks "extracted, no text found" so the file isn't retried every run
                var text: String?
                var textVersion = 0
                if wantsText {
                    report(reading: url.lastPathComponent)
                    extractionIncomplete = false
                    let extracted = extractText(from: url, ext: ext, size: size) ?? ""
                    // Leave incomplete extractions (OCR stalled, or Stop pressed) unmarked so they're retried
                    if !extractionIncomplete && !isCancelled {
                        text = extracted
                        textVersion = Self.textExtractionVersion
                    }
                }
                return FileRecord(path: path, name: url.lastPathComponent, ext: ext, size: size,
                                  modified: modified, text: text, textVersion: textVersion)
            }

            if let record {
                batch.append(record)
                // Also flush every few seconds so slow runs become searchable as they go
                if batch.count >= Self.batchSize || Date().timeIntervalSince(lastWrite) > 5 {
                    write(batch, root: root)
                    batch.removeAll(keepingCapacity: true)
                    lastWrite = Date()
                }
            }
            report()
        }
        if !batch.isEmpty { write(batch, root: root) }

        // Remove rows for deleted files, but only after a complete scan of a root that is still
        // reachable. A dropped share or unreadable subfolder must not look like mass deletion.
        if !isCancelled, isReachableFolder(root) {
            let stale = existing.keys.filter { path in
                !seen.contains(path) && !unreadable.contains { path.hasPrefix($0 + "/") }
            }
            deleteRows(stale)
            recordCompletedScan(of: root)
        }
        return scanned
    }

    private func recordCompletedScan(of root: String) {
        let now = Date()
        dbQueue.sync {
            _ = query("INSERT OR REPLACE INTO folder_state (root, last_indexed) VALUES (?, ?)",
                      [.text(root), .text(Self.isoFormatter.string(from: now))])
        }
        DispatchQueue.main.async { self.lastIndexed[root] = now }
    }

    private func isExcluded(_ name: String, _ options: IndexOptions) -> Bool {
        options.excludedFiles.contains { pattern in
            pattern.hasSuffix("*") ? name.hasPrefix(String(pattern.dropLast())) : name == pattern
        }
    }

    private func existingRows(in root: String) -> [String: ExistingRow] {
        var rows: [String: ExistingRow] = [:]
        dbQueue.sync {
            _ = query("SELECT path, size, modified_time, ocr_text IS NOT NULL, text_version FROM files WHERE folder_root = ?",
                  [.text(root)]) {
                rows[Self.columnText($0, 0)] = ExistingRow(
                    size: sqlite3_column_int64($0, 1),
                    modified: Self.columnText($0, 2),
                    hasText: sqlite3_column_int($0, 3) == 1,
                    textVersion: Int(sqlite3_column_int($0, 4))
                )
            }
        }
        return rows
    }

    private static let upsertSQL = """
    INSERT INTO files (path, name, extension, size, modified_time, indexed_time, folder_root, ocr_text, text_version)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(path) DO UPDATE SET
        name = excluded.name,
        extension = excluded.extension,
        size = excluded.size,
        modified_time = excluded.modified_time,
        indexed_time = excluded.indexed_time,
        folder_root = excluded.folder_root,
        ocr_text = excluded.ocr_text,
        text_version = excluded.text_version
    """

    /// Writes a batch in one transaction, which is far faster than committing per file.
    private func write(_ records: [FileRecord], root: String) {
        let indexedAt = Self.isoFormatter.string(from: Date())
        dbQueue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &statement, nil) == SQLITE_OK, let statement else {
                logger.error("Prepare failed: \(self.lastError, privacy: .public)")
                return
            }
            defer { sqlite3_finalize(statement) }

            exec("BEGIN")
            for record in records {
                bind([
                    .text(record.path), .text(record.name), .text(record.ext), .int(record.size),
                    .text(record.modified), .text(indexedAt), .text(root),
                    record.text.map { .text($0) } ?? .null, .int(Int64(record.textVersion))
                ], to: statement)
                if sqlite3_step(statement) != SQLITE_DONE {
                    logger.error("Insert failed for \(record.path, privacy: .public): \(self.lastError, privacy: .public)")
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            exec("COMMIT")
        }
    }

    private func deleteRows(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        dbQueue.sync {
            exec("BEGIN")
            for path in paths {
                query("DELETE FROM files WHERE path = ?", [.text(path)])
            }
            exec("COMMIT")
        }
    }

    // MARK: - Text extraction

    private static let documentTypes: [String: NSAttributedString.DocumentType] = [
        "doc": .docFormat, "docx": .officeOpenXML, "rtf": .rtf
    ]
    private static let plainTextExtensions: Set<String> = ["txt", "csv", "md", "eml", "htm", "html"]

    private static func supportsTextExtraction(_ ext: String) -> Bool {
        ext == "pdf" || ext == "msg" || documentTypes[ext] != nil
            || plainTextExtensions.contains(ext) || imageExtensions.contains(ext)
    }

    private func extractText(from url: URL, ext: String, size: Int64) -> String? {
        switch ext {
        case "pdf":
            return size < 200_000_000 ? extractPDFText(url) : nil
        case "msg":
            guard size < 200_000_000, let message = try? OutlookMessage(contentsOf: url) else { return nil }
            return String(message.searchableText.prefix(Self.maxTextLength))
        case _ where Self.documentTypes[ext] != nil:
            // The Word/RTF importers are safe off the main thread (unlike the HTML one)
            guard size < 100_000_000,
                  let document = try? NSAttributedString(url: url,
                                                         options: [.documentType: Self.documentTypes[ext]!],
                                                         documentAttributes: nil) else { return nil }
            return String(document.string.prefix(Self.maxTextLength))
        case _ where Self.plainTextExtensions.contains(ext):
            return size < 20_000_000 ? readPlainText(url, ext: ext) : nil
        default:
            return size < 20_000_000 ? recognizeImage(at: url) : nil
        }
    }

    private func readPlainText(_ url: URL, ext: String) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        switch ext {
        case "htm", "html":
            text = OutlookMessage.plainText(fromHTML: Data(text.utf8))
        case "eml":
            // Drop base64-encoded parts (attachments, images), which would only add noise
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.count < 60 || $0.contains(" ") }
                .joined(separator: "\n")
        default:
            break
        }
        return String(text.prefix(Self.maxTextLength))
    }

    /// Reads every page's text layer, and OCRs pages that have none (scans), up to a limit.
    private func extractPDFText(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }

        var pages: [String] = []
        var length = 0
        var ocrPages = 0

        for index in 0..<document.pageCount {
            if isCancelled || length > Self.maxTextLength { break }
            guard let page = document.page(at: index) else { continue }

            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, ocrPages < Self.maxOCRPagesPerPDF {
                ocrPages += 1
                text = recognizePDFPage(page) ?? text
            }
            pages.append(text)
            length += text.count
        }
        return pages.joined(separator: "\n")
    }

    private func recognizePDFPage(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2000 / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return recognizeText(in: cgImage)
    }

    private func recognizeImage(at url: URL) -> String? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return recognizeText(in: cgImage)
    }

    private final class OCRResult: @unchecked Sendable {
        var lines: [String]?
    }

    /// Runs Vision OCR with a time limit, checking for Stop while it works.
    private func recognizeText(in image: CGImage) -> String? {
        guard ocrTimeouts < Self.maxOCRTimeouts else {
            extractionIncomplete = true
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let result = OCRResult()
        let done = DispatchSemaphore(value: 0)
        let logger = logger
        DispatchQueue.global(qos: .utility).async {
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                result.lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            } catch {
                logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            }
            done.signal()
        }

        let deadline = Date().addingTimeInterval(Self.ocrTimeout)
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled || Date() > deadline {
                // A stalled call may never return; abandon it and move on
                request.cancel()
                extractionIncomplete = true
                if !isCancelled {
                    ocrTimeouts += 1
                    logger.error("Text recognition stopped responding (\(self.ocrTimeouts) of \(Self.maxOCRTimeouts))")
                    if ocrTimeouts >= Self.maxOCRTimeouts {
                        DispatchQueue.main.async { self.textRecognitionStalled = true }
                    }
                }
                return nil
            }
        }
        return result.lines?.joined(separator: " ")
    }

    // MARK: - Search

    /// Searches names, folder paths, and extracted text. `text` accepts the syntax in
    /// SearchQueryParser. Files whose name contains everything typed come first, then other
    /// matches by relevance; with only filters, newest first. Safe to call from any thread except `dbQueue`.
    func search(_ text: String, fileType: String? = nil, folders: [String] = [], limit: Int = 1000) -> [FileItem] {
        let parsed = SearchQueryParser.parse(text)
        var filters: [String] = []
        var filterParams: [SQLValue] = []

        if !parsed.fileTypes.isEmpty {
            filters.append("f.extension IN (\(parsed.fileTypes.map { _ in "?" }.joined(separator: ", ")))")
            filterParams += parsed.fileTypes.map { .text($0) }
        }
        if let fileType {
            filters.append("f.extension = ?")
            filterParams.append(.text(fileType.lowercased().replacingOccurrences(of: ".", with: "")))
        }
        if !folders.isEmpty {
            filters.append("(" + folders.map { _ in "f.path LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            filterParams += folders.map { .text(Self.likeEscaped($0) + "/%") }
        }
        for fragment in parsed.pathContains {
            filters.append("f.path LIKE ? ESCAPE '\\'")
            filterParams.append(.text("%\(Self.likeEscaped(fragment))%"))
        }
        if let after = parsed.modifiedAfter {
            filters.append("f.modified_time >= ?")
            filterParams.append(.text(Self.isoFormatter.string(from: after)))
        }
        if let before = parsed.modifiedBefore {
            filters.append("f.modified_time < ?")
            filterParams.append(.text(Self.isoFormatter.string(from: before)))
        }
        if let minSize = parsed.minSize {
            filters.append("f.size >= ?")
            filterParams.append(.int(minSize))
        }
        if let maxSize = parsed.maxSize {
            filters.append("f.size <= ?")
            filterParams.append(.int(maxSize))
        }

        let match = SearchQueryParser.ftsMatchExpression(for: parsed)
        let nameTerms = parsed.textTokens + parsed.exactPhrases
        guard !nameTerms.isEmpty || !filters.isEmpty else { return [] }

        var results: [FileItem] = []
        searchQueue.sync {
            guard !nameTerms.isEmpty else {
                results = fetchFiles(from: "files f", where: filters, filterParams, orderBy: "f.modified_time DESC", limit: limit).map(\.item)
                return
            }

            // Word matches across names, paths, and text, ranked (fast via the full-text index)
            var ranked: [(id: Int64, item: FileItem)] = []
            if let match {
                ranked = fetchFiles(from: "files_fts JOIN files f ON f.id = files_fts.rowid",
                                    where: ["files_fts MATCH ?"] + filters, [.text(match)] + filterParams,
                                    orderBy: "bm25(files_fts, 10.0, 2.0, 1.0)", limit: limit)
            }
            // Names containing what was typed anywhere, e.g. "2023" in "Budget2023.pdf",
            // which word matching can't find. A plain scan of names is fast enough.
            let named = fetchFiles(from: "files f",
                                   where: nameTerms.map { _ in "f.name LIKE ? ESCAPE '\\'" } + filters,
                                   nameTerms.map { .text("%\(Self.likeEscaped($0))%") } + filterParams,
                                   orderBy: "f.modified_time DESC", limit: limit)

            let namedPaths = Set(named.map(\.item.path))
            let rankedPaths = Set(ranked.map(\.item.path))
            let merged = ranked.filter { namedPaths.contains($0.item.path) }
                + named.filter { !rankedPaths.contains($0.item.path) }
                + ranked.filter { !namedPaths.contains($0.item.path) }
            results = Array(merged.prefix(limit)).map(\.item)

            if let match {
                addSnippets(to: &results, ids: Dictionary(merged.map { ($0.item.path, $0.id) }, uniquingKeysWith: { a, _ in a }), match: match)
            }
        }
        return results
    }

    private func fetchFiles(from source: String, where clauses: [String], _ params: [SQLValue],
                            orderBy: String, limit: Int) -> [(id: Int64, item: FileItem)] {
        var rows: [(id: Int64, item: FileItem)] = []
        let sql = """
        SELECT f.id, f.path, f.name, f.extension, f.size, f.modified_time, f.folder_root
        FROM \(source)
        \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "))
        ORDER BY \(orderBy)
        LIMIT \(limit)
        """
        _ = query(sql, params, on: searchDB) {
            rows.append((sqlite3_column_int64($0, 0), FileItem(
                path: Self.columnText($0, 1),
                name: Self.columnText($0, 2),
                fileExtension: Self.columnText($0, 3),
                size: sqlite3_column_int64($0, 4),
                modifiedTime: Self.isoFormatter.date(from: Self.columnText($0, 5)) ?? .distantPast,
                folderRoot: Self.columnText($0, 6)
            )))
        }
        return rows
    }

    /// Marks highlighted words in snippets; the UI turns these into bold text
    static let highlightStart = "\u{2}"
    static let highlightEnd = "\u{3}"

    /// Adds a short excerpt around the match for results that matched inside the file's text.
    /// Only the top results get one, since building excerpts means reading each file's text.
    private func addSnippets(to results: inout [FileItem], ids: [String: Int64], match: String) {
        let top = results.prefix(100).compactMap { ids[$0.path] }
        guard !top.isEmpty else { return }

        var snippets: [Int64: String] = [:]
        _ = query("""
        SELECT rowid, snippet(files_fts, 2, char(2), char(3), '…', 14)
        FROM files_fts
        WHERE files_fts MATCH ? AND rowid IN (\(top.map(String.init).joined(separator: ",")))
        """, [.text("ocr_text : (\(match))")], on: searchDB) {
            snippets[sqlite3_column_int64($0, 0)] = Self.columnText($0, 1)
        }

        for index in results.indices.prefix(100) {
            guard let id = ids[results[index].path], let snippet = snippets[id], snippet.contains(Self.highlightStart) else { continue }
            results[index].snippet = snippet
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
    }

    func clearDatabase() {
        dbQueue.async {
            self.query("DELETE FROM files")
            self.query("DELETE FROM folder_state")
            DispatchQueue.main.async { self.lastIndexed = [:] }
            self.refreshStatsOnQueue()
        }
    }

    #if DEBUG
    /// Holds the write connection in an open transaction, as a long indexing batch does (tests only)
    func holdWriteTransactionForTesting(seconds: TimeInterval) {
        dbQueue.sync {
            exec("BEGIN IMMEDIATE")
            Thread.sleep(forTimeInterval: seconds)
            exec("COMMIT")
        }
    }
    #endif

    // MARK: - Folder Discovery

    /// Immediate subfolders of `parentPath` that contain indexed files (for the folder picker tree)
    func immediateSubfolders(of parentPath: String) -> [String] {
        // SQLite's substr/instr count Unicode code points, so measure the prefix the same way
        let start = Int64(parentPath.unicodeScalars.count + 2)
        var names: [String] = []
        searchQueue.sync {
            _ = query("""
            SELECT DISTINCT substr(path, ?1, instr(substr(path, ?1), '/') - 1)
            FROM files
            WHERE path LIKE ?2 ESCAPE '\\' AND instr(substr(path, ?1), '/') > 0
            """, [.int(start), .text(Self.likeEscaped(parentPath) + "/%")], on: searchDB) {
                names.append(Self.columnText($0, 0))
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { parentPath + "/" + $0 }
    }

    /// Every folder that contains an indexed file (for folder search in the picker)
    func allFolders() -> [String] {
        var folders: [String] = []
        searchQueue.sync {
            _ = query("SELECT DISTINCT substr(path, 1, length(path) - length(name) - 1) FROM files", on: searchDB) {
                folders.append(Self.columnText($0, 0))
            }
        }
        return folders.sorted()
    }
}
