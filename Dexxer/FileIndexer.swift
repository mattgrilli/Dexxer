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
    /// All database access goes through this serial queue. Never call `dbQueue.sync` from code already on it.
    private let dbQueue = DispatchQueue(label: "com.mattgrilli.dexxer.db", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.mattgrilli.dexxer", category: "indexing")

    static let isoFormatter = ISO8601DateFormatter()

    @Published private(set) var indexedFolders: [String] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var isCancellingIndex = false
    /// Files scanned so far in the current run
    @Published private(set) var indexProgress = 0
    @Published private(set) var currentlyIndexing: String?
    @Published private(set) var stats = IndexStats()
    @Published private(set) var folderFileCounts: [String: Int] = [:]
    /// Last known reachability per indexed folder. Checked off the main thread because a hung
    /// network mount can block file system calls for a long time.
    @Published private(set) var reachability: [String: Bool] = [:]
    /// Folders the last run skipped because they were offline
    @Published private(set) var lastSkippedFolders: [String] = []

    @Published var excludePatternsEnabled: Bool {
        didSet { UserDefaults.standard.set(excludePatternsEnabled, forKey: Keys.excludePatterns) }
    }
    @Published var ocrEnabled: Bool {
        didSet { UserDefaults.standard.set(ocrEnabled, forKey: Keys.ocr) }
    }

    let excludedFolders = [".git", ".svn", "node_modules", ".Trash", "__pycache__", ".cache", "venv", "build", "dist", ".idea", ".vscode"]
    let excludedFiles = [".DS_Store", "Thumbs.db", "desktop.ini", "._*"]

    private let cancelRequested = OSAllocatedUnfairLock(initialState: false)
    private var isCancelled: Bool { cancelRequested.withLock { $0 } }
    /// Folders requested while a run was in progress; indexed when it finishes
    private var queuedFolders: [String] = []
    private var reachabilityCheckInFlight = false

    private enum Keys {
        static let excludePatterns = "DexxerExcludePatternsEnabled"
        static let ocr = "DexxerOCREnabled"
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
        // Leftovers from the old crash-recovery scheme, which deleted data on relaunch
        defaults.removeObject(forKey: "DexxerIndexingInProgress")
        defaults.removeObject(forKey: "DexxerLastIndexedFolder")

        openDatabase()
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
        sqlite3_close(db)
    }

    // MARK: - SQLite helpers

    private enum SQLValue {
        case text(String)
        case int(Int64)
        case null
    }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

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

    /// Runs a statement and calls `row` for each result row. Call on `dbQueue` (or during init).
    @discardableResult
    private func query(_ sql: String, _ params: [SQLValue] = [], row: (OpaquePointer) -> Void = { _ in }) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            logger.error("Prepare failed: \(self.lastError, privacy: .public)")
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(params, to: statement)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return true
            default:
                logger.error("Step failed: \(self.lastError, privacy: .public)")
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
    }

    private func columnExists(_ column: String) -> Bool {
        var exists = false
        query("SELECT COUNT(*) FROM pragma_table_info('files') WHERE name = ?", [.text(column)]) {
            exists = sqlite3_column_int($0, 0) > 0
        }
        return exists
    }

    private func createFTSTable() {
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
        let path = url.standardizedFileURL.path
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

        dbQueue.async {
            self.query("DELETE FROM files WHERE folder_root = ?", [.text(path)])
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
        indexProgress = 0
        cancelRequested.withLock { $0 = false }

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
                self.indexProgress = total
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
        var lastReported = 0

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
                let text = wantsText ? (extractText(from: url, ext: ext, size: size) ?? "") : nil
                return FileRecord(path: path, name: url.lastPathComponent, ext: ext, size: size,
                                  modified: modified, text: text,
                                  textVersion: wantsText ? Self.textExtractionVersion : 0)
            }

            if let record {
                batch.append(record)
                if batch.count >= Self.batchSize {
                    write(batch, root: root)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if scanned - lastReported >= 250 {
                lastReported = scanned
                let progress = progressBase + scanned
                DispatchQueue.main.async { self.indexProgress = progress }
            }
        }
        if !batch.isEmpty { write(batch, root: root) }

        // Remove rows for deleted files, but only after a complete scan of a root that is still
        // reachable. A dropped share or unreadable subfolder must not look like mass deletion.
        if !isCancelled, isReachableFolder(root) {
            let stale = existing.keys.filter { path in
                !seen.contains(path) && !unreadable.contains { path.hasPrefix($0 + "/") }
            }
            deleteRows(stale)
        }
        return scanned
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

    private static func supportsTextExtraction(_ ext: String) -> Bool {
        ext == "pdf" || imageExtensions.contains(ext)
    }

    private func extractText(from url: URL, ext: String, size: Int64) -> String? {
        if ext == "pdf" {
            return size < 200_000_000 ? extractPDFText(url) : nil
        }
        return size < 20_000_000 ? recognizeImage(at: url) : nil
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

    private func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    // MARK: - Search

    /// Searches names, folder paths, and extracted text. `text` accepts the syntax in
    /// SearchQueryParser. Results are best match first when there are words to rank by,
    /// otherwise newest first. Safe to call from any thread except `dbQueue`.
    func search(_ text: String, fileType: String? = nil, folders: [String] = [], limit: Int = 1000) -> [FileItem] {
        let parsed = SearchQueryParser.parse(text)
        var clauses: [String] = []
        var params: [SQLValue] = []

        if let match = SearchQueryParser.ftsMatchExpression(for: parsed) {
            clauses.append("files_fts MATCH ?")
            params.append(.text(match))
        } else if parsed.hasText {
            // Only punctuation was typed; fall back to a plain name match
            clauses.append("f.name LIKE ? ESCAPE '\\'")
            params.append(.text("%\(Self.likeEscaped((parsed.textTokens + parsed.exactPhrases).joined(separator: " ")))%"))
        }

        if !parsed.fileTypes.isEmpty {
            clauses.append("f.extension IN (\(parsed.fileTypes.map { _ in "?" }.joined(separator: ", ")))")
            params += parsed.fileTypes.map { .text($0) }
        }
        if let fileType {
            clauses.append("f.extension = ?")
            params.append(.text(fileType.lowercased().replacingOccurrences(of: ".", with: "")))
        }
        if !folders.isEmpty {
            clauses.append("(" + folders.map { _ in "f.path LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            params += folders.map { .text(Self.likeEscaped($0) + "/%") }
        }
        for fragment in parsed.pathContains {
            clauses.append("f.path LIKE ? ESCAPE '\\'")
            params.append(.text("%\(Self.likeEscaped(fragment))%"))
        }
        if let after = parsed.modifiedAfter {
            clauses.append("f.modified_time >= ?")
            params.append(.text(Self.isoFormatter.string(from: after)))
        }
        if let before = parsed.modifiedBefore {
            clauses.append("f.modified_time < ?")
            params.append(.text(Self.isoFormatter.string(from: before)))
        }
        if let minSize = parsed.minSize {
            clauses.append("f.size >= ?")
            params.append(.int(minSize))
        }
        if let maxSize = parsed.maxSize {
            clauses.append("f.size <= ?")
            params.append(.int(maxSize))
        }

        guard !clauses.isEmpty else { return [] }

        let usesFTS = clauses.first == "files_fts MATCH ?"
        let sql = """
        SELECT f.path, f.name, f.extension, f.size, f.modified_time, f.folder_root
        FROM \(usesFTS ? "files_fts JOIN files f ON f.id = files_fts.rowid" : "files f")
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY \(usesFTS ? "bm25(files_fts, 10.0, 2.0, 1.0)" : "f.modified_time DESC")
        LIMIT \(limit)
        """

        var results: [FileItem] = []
        dbQueue.sync {
            _ = query(sql, params) {
                results.append(FileItem(
                    path: Self.columnText($0, 0),
                    name: Self.columnText($0, 1),
                    fileExtension: Self.columnText($0, 2),
                    size: sqlite3_column_int64($0, 3),
                    modifiedTime: Self.isoFormatter.date(from: Self.columnText($0, 4)) ?? .distantPast,
                    folderRoot: Self.columnText($0, 5)
                ))
            }
        }
        return results
    }

    func clearDatabase() {
        dbQueue.async {
            self.query("DELETE FROM files")
            self.refreshStatsOnQueue()
        }
    }

    // MARK: - Folder Discovery

    /// Immediate subfolders of `parentPath` that contain indexed files (for the folder picker tree)
    func immediateSubfolders(of parentPath: String) -> [String] {
        // SQLite's substr/instr count Unicode code points, so measure the prefix the same way
        let start = Int64(parentPath.unicodeScalars.count + 2)
        var names: [String] = []
        dbQueue.sync {
            _ = query("""
            SELECT DISTINCT substr(path, ?1, instr(substr(path, ?1), '/') - 1)
            FROM files
            WHERE path LIKE ?2 ESCAPE '\\' AND instr(substr(path, ?1), '/') > 0
            """, [.int(start), .text(Self.likeEscaped(parentPath) + "/%")]) {
                names.append(Self.columnText($0, 0))
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { parentPath + "/" + $0 }
    }

    /// Every folder that contains an indexed file (for folder search in the picker)
    func allFolders() -> [String] {
        var folders: [String] = []
        dbQueue.sync {
            _ = query("SELECT DISTINCT substr(path, 1, length(path) - length(name) - 1) FROM files") {
                folders.append(Self.columnText($0, 0))
            }
        }
        return folders.sorted()
    }
}
