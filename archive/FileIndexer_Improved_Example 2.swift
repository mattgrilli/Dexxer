//
//  FileIndexer_Improved_Example.swift
//  Dexxer - Improved Version with Best Practices
//
//  This is an EXAMPLE showing the recommended improvements
//  Compare with FileIndexer.swift to see the differences
//
//  NOTE: This file is for reference only - do not compile it in your build!
//  Remove from build targets or delete it to avoid compilation errors.

#if false  // Disable compilation

import Foundation
import SQLite3
import OSLog

// MARK: - Constants

private enum IndexingConstants {
    static let batchSize = 500
    static let progressUpdateInterval = 100
    static let defaultSearchLimit = 1000
    static let transactionCommitThreshold = 500
}

// MARK: - Errors

enum IndexerError: LocalizedError {
    case databaseOpenFailed(path: String)
    case databaseOperationFailed(operation: String, details: String)
    case permissionDenied(folder: String)
    case folderNotFound(path: String)
    case indexingCancelled
    
    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let path):
            return "Failed to open database at \(path)"
        case .databaseOperationFailed(let op, let details):
            return "\(op) failed: \(details)"
        case .permissionDenied(let folder):
            return "Permission denied for folder: \(folder)"
        case .folderNotFound(let path):
            return "Folder not found: \(path)"
        case .indexingCancelled:
            return "Indexing was cancelled by user"
        }
    }
}

// MARK: - Logging

extension Logger {
    static let indexer = Logger(subsystem: "com.mattgrilli.dexxer", category: "indexing")
    static let database = Logger(subsystem: "com.mattgrilli.dexxer", category: "database")
    static let search = Logger(subsystem: "com.mattgrilli.dexxer", category: "search")
}

// MARK: - Database Actor (Thread-Safe SQLite Access)

/// Actor that ensures all database operations happen serially and safely
actor DatabaseActor {
    private var db: OpaquePointer?
    private let dbPath: String
    private static let isoFormatter = ISO8601DateFormatter()
    
    init(dbPath: String) {
        self.dbPath = dbPath
    }
    
    // MARK: - Database Lifecycle
    
    func openDatabase() throws {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            Logger.database.error("Failed to open database: \(error)")
            throw IndexerError.databaseOpenFailed(path: dbPath)
        }
        
        try createTablesIfNeeded()
        try createIndexes()
        
        // Enable WAL mode for better concurrent access
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        
        Logger.database.info("Database opened successfully at \(self.dbPath)")
    }
    
    func closeDatabase() {
        guard let db = db else { return }
        sqlite3_close(db)
        self.db = nil
        Logger.database.info("Database closed")
    }
    
    private func createTablesIfNeeded() throws {
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            extension TEXT,
            size INTEGER DEFAULT 0,
            modified_time TEXT NOT NULL,
            indexed_time TEXT NOT NULL,
            folder_root TEXT NOT NULL
        );
        """
        
        guard sqlite3_exec(db, createTableSQL, nil, nil, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw IndexerError.databaseOperationFailed(operation: "CREATE TABLE", details: error)
        }
        
        // Create FTS5 virtual table for full-text search
        let createFTSSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
            name,
            path,
            content=files,
            content_rowid=id
        );
        """
        
        sqlite3_exec(db, createFTSSQL, nil, nil, nil)
    }
    
    private func createIndexes() throws {
        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_name ON files(name)",
            "CREATE INDEX IF NOT EXISTS idx_extension ON files(extension)",
            "CREATE INDEX IF NOT EXISTS idx_folder_root ON files(folder_root)",
            "CREATE INDEX IF NOT EXISTS idx_modified_time ON files(modified_time)",
            "CREATE INDEX IF NOT EXISTS idx_size ON files(size)"
        ]
        
        for indexSQL in indexes {
            guard sqlite3_exec(db, indexSQL, nil, nil, nil) == SQLITE_OK else {
                let error = String(cString: sqlite3_errmsg(db))
                Logger.database.warning("Failed to create index: \(error)")
            }
        }
    }
    
    // MARK: - Batch Operations (Much Faster!)
    
    func beginTransaction() {
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
    }
    
    func commitTransaction() {
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }
    
    func rollbackTransaction() {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    }
    
    /// Insert files in batches with transactions (50-100x faster)
    func insertFilesBatch(_ files: [FileEntry]) throws {
        guard !files.isEmpty else { return }
        
        let insertSQL = """
        INSERT OR REPLACE INTO files (path, name, extension, size, modified_time, indexed_time, folder_root)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw IndexerError.databaseOperationFailed(operation: "INSERT prepare", details: error)
        }
        
        defer { sqlite3_finalize(statement) }
        
        beginTransaction()
        
        for file in files {
            sqlite3_bind_text(statement, 1, (file.path as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (file.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (file.extension as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 4, file.size)
            sqlite3_bind_text(statement, 5, (file.modifiedTime as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 6, (file.indexedTime as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 7, (file.folderRoot as NSString).utf8String, -1, nil)
            
            if sqlite3_step(statement) != SQLITE_DONE {
                rollbackTransaction()
                let error = String(cString: sqlite3_errmsg(db))
                throw IndexerError.databaseOperationFailed(operation: "INSERT", details: error)
            }
            
            sqlite3_reset(statement)
        }
        
        commitTransaction()
        
        // Update FTS index
        updateFTSIndex(for: files.map { $0.path })
    }
    
    private func updateFTSIndex(for paths: [String]) {
        let updateFTSSQL = """
        INSERT INTO files_fts(rowid, name, path)
        SELECT id, name, path FROM files WHERE path IN (\(paths.map { "?" }.joined(separator: ",")))
        ON CONFLICT(rowid) DO UPDATE SET name=excluded.name, path=excluded.path
        """
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, updateFTSSQL, -1, &statement, nil) == SQLITE_OK {
            for (i, path) in paths.enumerated() {
                sqlite3_bind_text(statement, Int32(i + 1), (path as NSString).utf8String, -1, nil)
            }
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
    
    // MARK: - Delete Operations
    
    func deleteFilesInFolder(_ folderPath: String) throws {
        let deleteSQL = "DELETE FROM files WHERE folder_root = ?"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK else {
            throw IndexerError.databaseOperationFailed(operation: "DELETE", details: "prepare failed")
        }
        
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, (folderPath as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexerError.databaseOperationFailed(operation: "DELETE", details: "execution failed")
        }
        
        Logger.database.info("Deleted files for folder: \(folderPath)")
    }
    
    func clearAllFiles() {
        sqlite3_exec(db, "DELETE FROM files", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM files_fts", nil, nil, nil)
        Logger.database.info("Cleared all files from database")
    }
    
    // MARK: - Search Operations
    
    func search(sql: String, params: [String]) -> [FileItem] {
        var results: [FileItem] = []
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Logger.search.error("SQL Error: \(String(cString: sqlite3_errmsg(self.db)))")
            return []
        }
        
        defer { sqlite3_finalize(statement) }
        
        for (index, param) in params.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), (param as NSString).utf8String, -1, nil)
        }
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(statement, 0))
            let name = String(cString: sqlite3_column_text(statement, 1))
            let ext = String(cString: sqlite3_column_text(statement, 2))
            let size = sqlite3_column_int64(statement, 3)
            let modifiedTimeString = String(cString: sqlite3_column_text(statement, 4))
            let folderRoot = String(cString: sqlite3_column_text(statement, 5))
            let modifiedTime = Self.isoFormatter.date(from: modifiedTimeString) ?? Date()
            
            results.append(FileItem(
                path: path,
                name: name,
                fileExtension: ext,
                size: size,
                modifiedTime: modifiedTime,
                folderRoot: folderRoot
            ))
        }
        
        return results
    }
    
    /// Full-text search using FTS5 (much faster for text searches)
    func fullTextSearch(query: String, limit: Int = 100) -> [FileItem] {
        let sql = """
        SELECT files.path, files.name, files.extension, files.size, files.modified_time, files.folder_root
        FROM files_fts
        JOIN files ON files.id = files_fts.rowid
        WHERE files_fts MATCH ?
        ORDER BY rank
        LIMIT \(limit)
        """
        
        return search(sql: sql, params: [query])
    }
    
    // MARK: - Stats
    
    func getStats() -> (count: Int, totalSize: Int64) {
        var count = 0
        var totalSize: Int64 = 0
        var statement: OpaquePointer?
        
        let sql = "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files"
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
                totalSize = sqlite3_column_int64(statement, 1)
            }
        }
        
        sqlite3_finalize(statement)
        return (count, totalSize)
    }
    
    func getStatsByFolder() -> [String: (count: Int, size: Int64)] {
        var stats: [String: (Int, Int64)] = [:]
        var statement: OpaquePointer?
        
        let sql = "SELECT folder_root, COUNT(*), COALESCE(SUM(size), 0) FROM files GROUP BY folder_root"
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let folder = String(cString: sqlite3_column_text(statement, 0))
                let count = Int(sqlite3_column_int(statement, 1))
                let size = sqlite3_column_int64(statement, 2)
                stats[folder] = (count, size)
            }
        }
        
        sqlite3_finalize(statement)
        return stats
    }
    
    // MARK: - Folder Discovery
    
    func getImmediateSubfolders(of parentPath: String) -> [String] {
        var subfolders = Set<String>()
        var statement: OpaquePointer?
        
        let sql = "SELECT DISTINCT path FROM files WHERE path LIKE ? || '/%'"
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, (parentPath as NSString).utf8String, -1, nil)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let filePath = String(cString: sqlite3_column_text(statement, 0))
            
            if filePath.hasPrefix(parentPath + "/") {
                let remainder = String(filePath.dropFirst(parentPath.count + 1))
                
                if let firstSlash = remainder.firstIndex(of: "/") {
                    let immediateChild = String(remainder[..<firstSlash])
                    let childPath = parentPath + "/" + immediateChild
                    subfolders.insert(childPath)
                }
            }
        }
        
        return Array(subfolders).sorted()
    }
    
    func getAllFolders() -> [String] {
        var folders = Set<String>()
        var statement: OpaquePointer?
        
        let sql = """
        SELECT DISTINCT
            substr(path, 1, length(path) - length(name) - 1) as folder_path
        FROM files
        WHERE folder_path != ''
        """
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let folderPath = String(cString: sqlite3_column_text(statement, 0))
                folders.insert(folderPath)
            }
        }
        sqlite3_finalize(statement)
        
        return Array(folders)
    }
}

// MARK: - File Entry Model

struct FileEntry {
    let path: String
    let name: String
    let extension: String
    let size: Int64
    let modifiedTime: String
    let indexedTime: String
    let folderRoot: String
}

// MARK: - Main Indexer Class

@MainActor
class ImprovedFileIndexer: ObservableObject {
    // MARK: - Properties
    
    private let dbActor: DatabaseActor
    private let dbPath: String
    private let configPath: String
    
    @Published var indexedFolders: [String] = []
    @Published var isIndexing = false
    @Published var indexProgress: Int = 0
    @Published var currentIndexingFolder: String = ""
    @Published var isCancellingIndex = false
    
    private var shouldCancelIndexing = false
    private var indexingTask: Task<Void, Never>?
    
    private static let isoFormatter = ISO8601DateFormatter()
    
    // MARK: - Initialization
    
    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        self.dbPath = "\(homeDir)/.dexxer.db"
        self.configPath = "\(homeDir)/.dexxer_config.json"
        self.dbActor = DatabaseActor(dbPath: dbPath)
        
        Task {
            try? await dbActor.openDatabase()
        }
        
        loadConfig()
    }
    
    deinit {
        Task { [dbActor] in
            await dbActor.closeDatabase()
        }
    }
    
    // MARK: - Configuration
    
    private func loadConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let folders = try? JSONDecoder().decode([String].self, from: data) else {
            indexedFolders = []
            return
        }
        indexedFolders = folders
    }
    
    func saveConfig() {
        guard let data = try? JSONEncoder().encode(indexedFolders) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath))
    }
    
    func addFolder(_ folderPath: String) {
        let resolvedPath = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        if !indexedFolders.contains(resolvedPath) {
            indexedFolders.append(resolvedPath)
            saveConfig()
        }
    }
    
    func removeFolder(_ folderPath: String) {
        indexedFolders.removeAll { $0 == folderPath }
        saveConfig()
        
        Task {
            try? await dbActor.deleteFilesInFolder(folderPath)
        }
    }
    
    // MARK: - Indexing (Improved with Batching and Memory Management)
    
    func cancelIndexing() {
        Logger.indexer.warning("User requested cancellation")
        shouldCancelIndexing = true
        isCancellingIndex = true
        indexingTask?.cancel()
    }
    
    func indexFolders(_ folders: [String]? = nil, progressCallback: ((Int) -> Void)? = nil) {
        // Cancel any existing indexing task
        indexingTask?.cancel()
        
        indexingTask = Task {
            await performIndexing(folders: folders, progressCallback: progressCallback)
        }
    }
    
    private func performIndexing(folders: [String]?, progressCallback: ((Int) -> Void)?) async {
        Logger.indexer.info("🔍 Starting indexing...")
        
        shouldCancelIndexing = false
        isIndexing = true
        indexProgress = 0
        isCancellingIndex = false
        
        let foldersToIndex = folders ?? indexedFolders
        Logger.indexer.info("📁 Folders to index: \(foldersToIndex)")
        
        // Clear old entries
        for folder in foldersToIndex {
            try? await dbActor.deleteFilesInFolder(folder)
        }
        
        var totalFiles = 0
        var fileBatch: [FileEntry] = []
        fileBatch.reserveCapacity(IndexingConstants.batchSize)
        
        for folderRoot in foldersToIndex {
            if shouldCancelIndexing {
                Logger.indexer.warning("🛑 Indexing cancelled")
                break
            }
            
            currentIndexingFolder = folderRoot
            Logger.indexer.info("📂 Indexing: \(folderRoot)")
            
            // Security-scoped resource access
            let urlForRoot: URL = BookmarkStore.resolve(path: folderRoot) ?? URL(fileURLWithPath: folderRoot)
            var didStartScope = false
            if urlForRoot.startAccessingSecurityScopedResource() {
                didStartScope = true
            }
            
            defer {
                if didStartScope { urlForRoot.stopAccessingSecurityScopedResource() }
            }
            
            // Validate folder
            guard validateFolder(folderRoot) else { continue }
            
            // Enumerate files
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: folderRoot),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                Logger.indexer.error("❌ Failed to create enumerator for \(folderRoot)")
                continue
            }
            
            // Process files with autoreleasepool for memory efficiency
            for case let fileURL as URL in enumerator {
                autoreleasepool {
                    if shouldCancelIndexing { return }
                    
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                          let isRegularFile = resourceValues.isRegularFile,
                          isRegularFile else {
                        return
                    }
                    
                    let path = fileURL.path
                    let name = fileURL.lastPathComponent
                    let ext = fileURL.pathExtension.lowercased()
                    let size = Int64(resourceValues.fileSize ?? 0)
                    let modifiedTime = resourceValues.contentModificationDate ?? Date()
                    
                    let isoFormatter = Self.isoFormatter
                    let modifiedTimeString = isoFormatter.string(from: modifiedTime)
                    let indexedTimeString = isoFormatter.string(from: Date())
                    
                    let fileEntry = FileEntry(
                        path: path,
                        name: name,
                        extension: ext,
                        size: size,
                        modifiedTime: modifiedTimeString,
                        indexedTime: indexedTimeString,
                        folderRoot: folderRoot
                    )
                    
                    fileBatch.append(fileEntry)
                    
                    // Batch insert when threshold reached
                    if fileBatch.count >= IndexingConstants.batchSize {
                        Task {
                            try? await self.dbActor.insertFilesBatch(fileBatch)
                        }
                        
                        totalFiles += fileBatch.count
                        fileBatch.removeAll(keepingCapacity: true)
                        
                        // Update progress
                        indexProgress = totalFiles
                        
                        if totalFiles % IndexingConstants.progressUpdateInterval == 0 {
                            Logger.indexer.info("📊 Indexed \(totalFiles) files...")
                        }
                    }
                }
            }
            
            // Insert remaining files in batch
            if !fileBatch.isEmpty {
                Task {
                    try? await dbActor.insertFilesBatch(fileBatch)
                }
                totalFiles += fileBatch.count
                fileBatch.removeAll()
            }
        }
        
        if shouldCancelIndexing {
            Logger.indexer.warning("🛑 Indexing cancelled! Indexed \(totalFiles) files before cancellation")
        } else {
            Logger.indexer.info("✅ Indexing complete! Total files: \(totalFiles)")
        }
        
        isIndexing = false
        isCancellingIndex = false
        indexProgress = totalFiles
        currentIndexingFolder = ""
        progressCallback?(totalFiles)
        shouldCancelIndexing = false
    }
    
    private func validateFolder(_ path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            Logger.indexer.error("❌ Folder does not exist or is not a directory: \(path)")
            return false
        }
        
        guard fileManager.isReadableFile(atPath: path) else {
            Logger.indexer.error("❌ Folder is not readable: \(path)")
            return false
        }
        
        return true
    }
    
    // MARK: - Search
    
    func search(query: String, fileType: String? = nil, folders: [String]? = nil, limit: Int = 100) async -> [FileItem] {
        var sql = "SELECT path, name, extension, size, modified_time, folder_root FROM files WHERE name LIKE ?"
        var params: [String] = ["%\(query)%"]
        
        if let fileType = fileType, fileType != "All" {
            sql += " AND extension = ?"
            params.append(fileType.lowercased().replacingOccurrences(of: ".", with: ""))
        }
        
        if let folders = folders, !folders.isEmpty {
            let placeholders = folders.map { _ in "path LIKE ?" }.joined(separator: " OR ")
            sql += " AND (\(placeholders))"
            params.append(contentsOf: folders.map { "\($0)%" })
        }
        
        sql += " ORDER BY modified_time DESC LIMIT \(limit)"
        
        return await dbActor.search(sql: sql, params: params)
    }
    
    func searchAdvanced(_ filters: FileIndexer.SearchFilters) async -> [FileItem] {
        var clauses: [String] = []
        var params: [String] = []
        
        clauses.append("name LIKE ?")
        params.append("%\(filters.query)%")
        
        if let ft = filters.fileType, !ft.isEmpty, ft.lowercased() != "all" {
            clauses.append("extension = ?")
            params.append(ft.lowercased().replacingOccurrences(of: ".", with: ""))
        }
        
        if let folders = filters.folders, !folders.isEmpty {
            let orPieces = folders.map { _ in "path LIKE ?" }.joined(separator: " OR ")
            clauses.append("(\(orPieces))")
            params.append(contentsOf: folders.map { "\($0)%" })
        }
        
        if let sub = filters.pathContains, !sub.isEmpty {
            clauses.append("path LIKE ?")
            params.append("%\(sub)%")
        }
        
        let iso = ISO8601DateFormatter()
        if let after = filters.modifiedAfter {
            clauses.append("modified_time >= ?")
            params.append(iso.string(from: after))
        }
        if let before = filters.modifiedBefore {
            clauses.append("modified_time <= ?")
            params.append(iso.string(from: before))
        }
        
        if let min = filters.minSize {
            clauses.append("size >= ?")
            params.append(String(min))
        }
        if let max = filters.maxSize {
            clauses.append("size <= ?")
            params.append(String(max))
        }
        
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
        SELECT path, name, extension, size, modified_time, folder_root
        FROM files
        \(whereSQL)
        ORDER BY modified_time DESC
        LIMIT \(filters.limit)
        """
        
        return await dbActor.search(sql: sql, params: params)
    }
    
    // MARK: - Stats
    
    func getStats() async -> (count: Int, totalSize: Int64) {
        return await dbActor.getStats()
    }
    
    func clearDatabase() async {
        await dbActor.clearAllFiles()
        indexProgress = 0
    }
    
    // MARK: - Folder Discovery
    
    func getImmediateSubfolders(of parentPath: String) async -> [String] {
        return await dbActor.getImmediateSubfolders(of: parentPath)
    }
    
    func getAllFolders() async -> [String] {
        return await dbActor.getAllFolders()
    }
}

#endif  // End of disabled example code