//
//  FileIndexer.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation
import SQLite3

class FileIndexer: ObservableObject {
    var db: OpaquePointer?
    let dbPath: String
    private let configPath: String
    let dbQueue = DispatchQueue(label: "com.mattgrilli.dexxer.db", qos: .userInitiated)
    
    @Published var indexedFolders: [String] = []
    @Published var isIndexing = false
    @Published var indexProgress: Int = 0
    @Published var isCancellingIndex = false
    private var shouldCancelIndexing = false
    
    init() {
        // Use Dexxer-specific database and config
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        self.dbPath = "\(homeDir)/.dexxer.db"
        self.configPath = "\(homeDir)/.dexxer_config.json"
        
        openDatabase()
        loadConfig()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database")
            return
        }
        
        // Database already exists from Python version, so we don't need to create tables
        // But we'll check if it exists and create if needed for fresh installs
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE,
            name TEXT,
            extension TEXT,
            size INTEGER,
            modified_time TEXT,
            indexed_time TEXT,
            folder_root TEXT
        );
        """
        
        if sqlite3_exec(db, createTableSQL, nil, nil, nil) != SQLITE_OK {
            print("Error creating table")
        }
        
        // Create indexes if they don't exist
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_name ON files(name)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_extension ON files(extension)", nil, nil, nil)
    }
    
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
        
        // Remove files from this folder from database - use serial queue
        dbQueue.sync {
            let deleteSQL = "DELETE FROM files WHERE folder_root = ?"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (folderPath as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    func cancelIndexing() {
        print("⚠️ User requested cancellation")
        shouldCancelIndexing = true
        DispatchQueue.main.async {
            self.isCancellingIndex = true
        }
    }

    func indexFolders(_ folders: [String]? = nil, progressCallback: ((Int) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            print("🔍 Starting indexing...")

            // Reset cancellation flag at start
            self.shouldCancelIndexing = false

            DispatchQueue.main.async {
                self.isIndexing = true
                self.indexProgress = 0
                self.isCancellingIndex = false
            }
            
            let foldersToIndex = folders ?? self.indexedFolders
            print("📁 Folders to index: \(foldersToIndex)")
            
            // Clear old entries for these folders - use serial queue for thread safety
            self.dbQueue.sync {
                for folder in foldersToIndex {
                    let deleteSQL = "DELETE FROM files WHERE folder_root = ?"
                    var statement: OpaquePointer?
                    if sqlite3_prepare_v2(self.db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
                        sqlite3_bind_text(statement, 1, (folder as NSString).utf8String, -1, nil)
                        sqlite3_step(statement)
                    }
                    sqlite3_finalize(statement)
                }
            }
            
            var totalFiles = 0
            let fileManager = FileManager.default
            
            let insertSQL = """
            INSERT OR REPLACE INTO files (path, name, extension, size, modified_time, indexed_time, folder_root)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            
            for folderRoot in foldersToIndex {
                // Check for cancellation between folders
                if self.shouldCancelIndexing {
                    print("🛑 Indexing cancelled by user")
                    break
                }

                print("📂 Indexing: \(folderRoot)")
                
                
                // Re-resolve a security-scoped URL if we have one
                let urlForRoot: URL = BookmarkStore.resolve(path: folderRoot)
                    ?? URL(fileURLWithPath: folderRoot)

                var didStartScope = false
                if urlForRoot.startAccessingSecurityScopedResource() {
                    didStartScope = true
                }

                defer {
                    if didStartScope { urlForRoot.stopAccessingSecurityScopedResource() }
                }

                // Check if folder exists and is accessible
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: folderRoot, isDirectory: &isDirectory)
                print("   Exists: \(exists), IsDirectory: \(isDirectory.boolValue)")
                
                if !exists {
                    print("   ❌ Folder does not exist!")
                    continue
                }
                
                if !isDirectory.boolValue {
                    print("   ❌ Path is not a directory!")
                    continue
                }
                
                // Check if we can read the directory
                if !fileManager.isReadableFile(atPath: folderRoot) {
                    print("   ❌ Folder is not readable! Permission denied.")
                    continue
                }
                
                guard let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: folderRoot),
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    print("❌ Failed to create enumerator for \(folderRoot)")
                    continue
                }
                
                print("   ✅ Enumerator created, scanning files...")
                var fileCount = 0
                
                for case let fileURL as URL in enumerator {
                    // Check for cancellation during file scanning
                    if self.shouldCancelIndexing {
                        print("   🛑 Cancelled while scanning files")
                        break
                    }

                    fileCount += 1
                    if fileCount % 100 == 0 {
                        print("   ... scanned \(fileCount) items")
                    }
                    
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                          let isRegularFile = resourceValues.isRegularFile,
                          isRegularFile else {
                        continue
                    }
                    
                    let path = fileURL.path
                    let name = fileURL.lastPathComponent
                    let ext = fileURL.pathExtension.lowercased()
                    let size = Int64(resourceValues.fileSize ?? 0)
                    let modifiedTime = resourceValues.contentModificationDate ?? Date()
                    
                    // Use serial queue for thread-safe database access
                    self.dbQueue.sync {
                        var statement: OpaquePointer?
                        if sqlite3_prepare_v2(self.db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                            sqlite3_bind_text(statement, 1, (path as NSString).utf8String, -1, nil)
                            sqlite3_bind_text(statement, 2, (name as NSString).utf8String, -1, nil)
                            sqlite3_bind_text(statement, 3, (ext as NSString).utf8String, -1, nil)
                            sqlite3_bind_int64(statement, 4, size)
                            
                            let isoFormatter = ISO8601DateFormatter()
                            let modifiedTimeString = isoFormatter.string(from: modifiedTime)
                            let indexedTimeString = isoFormatter.string(from: Date())
                            
                            sqlite3_bind_text(statement, 5, (modifiedTimeString as NSString).utf8String, -1, nil)
                            sqlite3_bind_text(statement, 6, (indexedTimeString as NSString).utf8String, -1, nil)
                            sqlite3_bind_text(statement, 7, (folderRoot as NSString).utf8String, -1, nil)
                            
                            if sqlite3_step(statement) == SQLITE_DONE {
                                totalFiles += 1
                                
                                if totalFiles % 100 == 0 {
                                    DispatchQueue.main.async {
                                        self.indexProgress = totalFiles
                                    }
                                    print("📊 Indexed \(totalFiles) files...")
                                }
                            }
                        }
                        sqlite3_finalize(statement)
                    }
                }
            }
            
            if self.shouldCancelIndexing {
                print("🛑 Indexing cancelled! Indexed \(totalFiles) files before cancellation")
            } else {
                print("✅ Indexing complete! Total files: \(totalFiles)")
            }

            DispatchQueue.main.async {
                self.isIndexing = false
                self.isCancellingIndex = false
                self.indexProgress = totalFiles
                progressCallback?(totalFiles)
            }
            self.shouldCancelIndexing = false
        }
    }
    
    // MARK: - Advanced Search

    struct SearchFilters {
        var query: String = ""
        var fileType: String? = nil               // ".pdf" or "pdf" or nil
        var folders: [String]? = nil              // path prefixes (scopes)
        var pathContains: String? = nil           // e.g., "Legal"
        var modifiedAfter: Date? = nil
        var modifiedBefore: Date? = nil
        var minSize: Int64? = nil                 // bytes
        var maxSize: Int64? = nil                 // bytes
        var limit: Int = 1000
    }

    func searchAdvanced(_ f: SearchFilters) -> [FileItem] {
        var results: [FileItem] = []

        dbQueue.sync {
            var clauses: [String] = []
            var params: [String] = []

            // name LIKE
            clauses.append("name LIKE ?")
            params.append("%\(f.query)%")

            // extension
            if let ft = f.fileType, !ft.isEmpty, ft.lowercased() != "all" {
                clauses.append("extension = ?")
                let cleaned = ft.lowercased().replacingOccurrences(of: ".", with: "")
                params.append(cleaned)
            }

            // scope by folders (path prefix)
            if let folders = f.folders, !folders.isEmpty {
                let orPieces = folders.map { _ in "path LIKE ?" }.joined(separator: " OR ")
                clauses.append("(\(orPieces))")
                params.append(contentsOf: folders.map { "\($0)%" })
            }

            // path contains subfolder/keyword
            if let sub = f.pathContains, !sub.isEmpty {
                clauses.append("path LIKE ?")
                params.append("%\(sub)%")
            }

            // modified date range
            let iso = ISO8601DateFormatter()
            if let after = f.modifiedAfter {
                clauses.append("modified_time >= ?")
                params.append(iso.string(from: after))
            }
            if let before = f.modifiedBefore {
                clauses.append("modified_time <= ?")
                params.append(iso.string(from: before))
            }

            // size
            if let min = f.minSize { clauses.append("size >= ?"); params.append(String(min)) }
            if let max = f.maxSize { clauses.append("size <= ?"); params.append(String(max)) }

            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
            SELECT path, name, extension, size, modified_time, folder_root
            FROM files
            \(whereSQL)
            ORDER BY modified_time DESC
            LIMIT \(f.limit)
            """

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for (i, p) in params.enumerated() {
                    sqlite3_bind_text(statement, Int32(i + 1), (p as NSString).utf8String, -1, nil)
                }
                let iso = ISO8601DateFormatter()
                while sqlite3_step(statement) == SQLITE_ROW {
                    let path = String(cString: sqlite3_column_text(statement, 0))
                    let name = String(cString: sqlite3_column_text(statement, 1))
                    let ext  = String(cString: sqlite3_column_text(statement, 2))
                    let size = sqlite3_column_int64(statement, 3)
                    let modifiedTimeString = String(cString: sqlite3_column_text(statement, 4))
                    let folderRoot = String(cString: sqlite3_column_text(statement, 5))
                    let modifiedTime = iso.date(from: modifiedTimeString) ?? Date()

                    results.append(FileItem(
                        path: path,
                        name: name,
                        fileExtension: ext,
                        size: size,
                        modifiedTime: modifiedTime,
                        folderRoot: folderRoot
                    ))
                }
            } else {
                let err = String(cString: sqlite3_errmsg(db))
                print("❌ SQL error: \(err)")
            }
            sqlite3_finalize(statement)
        }

        return results
    }

    
    func search(query: String, fileType: String? = nil, folders: [String]? = nil, limit: Int = 100) -> [FileItem] {
        var results: [FileItem] = []
        
        // Use serial queue to ensure thread-safe database access
        dbQueue.sync {
            print("🔍 Search called with query: '\(query)', fileType: \(fileType ?? "nil")")
            
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
            
            print("   SQL: \(sql)")
            print("   Params: \(params)")
            
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for (index, param) in params.enumerated() {
                    sqlite3_bind_text(statement, Int32(index + 1), (param as NSString).utf8String, -1, nil)
                }
                
                let isoFormatter = ISO8601DateFormatter()
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    let path = String(cString: sqlite3_column_text(statement, 0))
                    let name = String(cString: sqlite3_column_text(statement, 1))
                    let ext = String(cString: sqlite3_column_text(statement, 2))
                    let size = sqlite3_column_int64(statement, 3)
                    let modifiedTimeString = String(cString: sqlite3_column_text(statement, 4))
                    let folderRoot = String(cString: sqlite3_column_text(statement, 5))
                    
                    let modifiedTime = isoFormatter.date(from: modifiedTimeString) ?? Date()
                    
                    let item = FileItem(
                        path: path,
                        name: name,
                        fileExtension: ext,
                        size: size,
                        modifiedTime: modifiedTime,
                        folderRoot: folderRoot
                    )
                    
                    results.append(item)
                }
            } else {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                print("   ❌ SQL Error: \(errorMessage)")
            }
            
            sqlite3_finalize(statement)
            print("   ✅ Found \(results.count) results")
        }
        
        return results
    }
    
    func getStats() -> (count: Int, totalSize: Int64) {
        var count = 0
        var totalSize: Int64 = 0
        
        dbQueue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*), SUM(size) FROM files"
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(statement, 0))
                    totalSize = sqlite3_column_int64(statement, 1)
                }
            }
            
            sqlite3_finalize(statement)
        }
        
        return (count, totalSize)
    }
    
    func clearDatabase() {
        dbQueue.sync {
            var statement: OpaquePointer?
            let sql = "DELETE FROM files"
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }

        // Update progress to trigger UI refresh
        DispatchQueue.main.async {
            self.indexProgress = 0
        }
    }

    // MARK: - Folder Discovery

    /// Returns a hierarchical structure of all indexed folders and their immediate subfolders
    func discoverFolderHierarchy() -> [FolderNode] {
        var folderSet = Set<String>()
        var fileCount = 0

        print("🔍 Discovering folder hierarchy...")

        dbQueue.sync {
            var statement: OpaquePointer?
            // Use folder_root column which is already indexed, much faster than path
            let sql = "SELECT DISTINCT folder_root FROM files"

            print("  Preparing SQL query...")
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                print("  Query prepared, fetching folder roots...")

                while sqlite3_step(statement) == SQLITE_ROW {
                    fileCount += 1
                    let folderRoot = String(cString: sqlite3_column_text(statement, 0))
                    folderSet.insert(folderRoot)

                    // Also add parent folders for hierarchy
                    let url = URL(fileURLWithPath: folderRoot)
                    var currentURL = url
                    while currentURL.path != "/" && currentURL.path.count > 1 {
                        folderSet.insert(currentURL.path)
                        currentURL = currentURL.deletingLastPathComponent()
                    }

                    // Progress update every 10 folders
                    if fileCount % 10 == 0 {
                        print("  ... processed \(fileCount) folder roots, found \(folderSet.count) unique folders")
                    }
                }
                print("  Query complete, processed \(fileCount) folder roots")
            } else {
                print("  ❌ SQL query failed")
            }
            sqlite3_finalize(statement)
        }

        print("📂 Found \(folderSet.count) unique folders from \(fileCount) folder roots")
        print("📁 Indexed root folders: \(indexedFolders)")

        // Build hierarchy from flat list
        print("  Building hierarchy tree...")
        let result = buildHierarchy(from: Array(folderSet))
        print("  Hierarchy build complete!")
        return result
    }

    /// Builds a hierarchical tree from a flat list of paths
    private func buildHierarchy(from paths: [String]) -> [FolderNode] {
        print("  Sorting \(paths.count) paths by depth...")

        var nodeMap: [String: FolderNode] = [:]
        var rootNodes: [FolderNode] = []

        // Sort paths by depth (shallowest first) to ensure parents are created before children
        let sortedPaths = paths.sorted { path1, path2 in
            let depth1 = path1.components(separatedBy: "/").count
            let depth2 = path2.components(separatedBy: "/").count
            if depth1 == depth2 {
                return path1 < path2
            }
            return depth1 < depth2
        }

        print("  Processing \(sortedPaths.count) sorted paths...")

        for (index, path) in sortedPaths.enumerated() {
            let url = URL(fileURLWithPath: path)
            let parentPath = url.deletingLastPathComponent().path

            // Create or get the current node
            if nodeMap[path] == nil {
                nodeMap[path] = FolderNode(path: path, name: url.lastPathComponent)
            }
            let node = nodeMap[path]!

            // Check if this is a root folder (in indexedFolders)
            if indexedFolders.contains(path) {
                if !rootNodes.contains(where: { $0.path == path }) {
                    rootNodes.append(node)
                    print("    ✓ Added root: \(path)")
                }
            } else if parentPath != "/" && parentPath.count > 1 {
                // Create parent if it doesn't exist
                if nodeMap[parentPath] == nil {
                    nodeMap[parentPath] = FolderNode(path: parentPath, name: URL(fileURLWithPath: parentPath).lastPathComponent)
                }
                let parentNode = nodeMap[parentPath]!

                // Add as child to parent
                if !parentNode.children.contains(where: { $0.path == path }) {
                    parentNode.children.append(node)
                }
            }

            // Progress update every 500 nodes
            if (index + 1) % 500 == 0 {
                print("    ... processed \(index + 1)/\(sortedPaths.count) nodes")
            }
        }

        print("  🌲 Built hierarchy with \(rootNodes.count) root nodes")
        let sorted = rootNodes.sorted { $0.path < $1.path }
        print("  ✅ Hierarchy ready to display")
        return sorted
    }
}

/// Represents a folder in the hierarchy
class FolderNode: Identifiable, ObservableObject {
    let id = UUID()
    let path: String
    let name: String
    @Published var children: [FolderNode] = []
    @Published var isExpanded: Bool = false

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}
