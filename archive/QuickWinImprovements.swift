//
//  QuickWinImprovements.swift
//  Dexxer - Quick improvements you can apply TODAY
//
//  These are small, focused improvements that take < 30 min each
//  but provide significant benefits
//
//  NOTE: This is a REFERENCE FILE - do not compile!

#if false  // Disabled - this is example code only

import Foundation

// MARK: - 1. Add Constants (5 minutes)

enum DexxerConstants {
    // Indexing
    static let batchSize = 500
    static let progressUpdateInterval = 100
    static let transactionCommitThreshold = 500
    
    // Search
    static let defaultSearchLimit = 1000
    static let maxSearchResults = 10_000
    
    // Database
    static let databaseName = ".dexxer.db"
    static let configName = ".dexxer_config.json"
    
    // UI
    static let folderHierarchyBuildThreshold = 2000  // Don't build hierarchy if more than 2000 folders
}

// MARK: - 2. Add Error Types (10 minutes)

enum DexxerError: LocalizedError {
    case databaseError(String)
    case folderAccessDenied(String)
    case folderNotFound(String)
    case indexingCancelled
    case configLoadFailed
    
    var errorDescription: String? {
        switch self {
        case .databaseError(let details):
            return "Database error: \(details)"
        case .folderAccessDenied(let path):
            return "Cannot access folder: \(path). Please grant permission in System Settings > Privacy & Security > Files and Folders"
        case .folderNotFound(let path):
            return "Folder not found: \(path)"
        case .indexingCancelled:
            return "Indexing was cancelled"
        case .configLoadFailed:
            return "Failed to load configuration"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .folderAccessDenied:
            return "Grant Dexxer access to this folder in System Settings, or choose a different folder."
        case .folderNotFound:
            return "This folder may have been moved or deleted. Remove it from your indexed folders and try again."
        case .databaseError:
            return "Try restarting Dexxer. If the problem persists, you may need to reset the database."
        default:
            return nil
        }
    }
}

// MARK: - 3. Extract Date Formatter (5 minutes)

extension FileIndexer {
    /// Shared ISO8601 date formatter (creating these is expensive!)
    static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
}

// MARK: - 4. Add Batching Extension to Sequence (10 minutes)

extension Sequence {
    /// Split sequence into batches of specified size
    func batched(size: Int) -> [[Element]] {
        var batch: [Element] = []
        var batches: [[Element]] = []
        
        for element in self {
            batch.append(element)
            if batch.count >= size {
                batches.append(batch)
                batch = []
            }
        }
        
        if !batch.isEmpty {
            batches.append(batch)
        }
        
        return batches
    }
}

// Usage in FileIndexer:
// let fileBatches = files.batched(size: DexxerConstants.batchSize)
// for batch in fileBatches {
//     insertFilesBatch(batch)
// }

// MARK: - 5. Add autoreleasepool to Indexing Loop (2 minutes)

/*
 In your indexFolders() method, wrap the file processing in autoreleasepool:
 
 for case let fileURL as URL in enumerator {
     autoreleasepool {
         // Your file processing code here
         // This releases memory immediately instead of waiting for the end of the loop
     }
 }
*/

// MARK: - 6. Add SQLite WAL Mode (1 minute)

/*
 Add this after opening the database in openDatabase():
 
 // Enable WAL (Write-Ahead Logging) mode for better concurrent access
 sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
 
 This allows reads while writes are happening!
*/

// MARK: - 7. Add Batch Transaction Support (15 minutes)

extension FileIndexer {
    /// Process files in batches with transactions for 50-100x speedup
    func insertFilesBatch(_ files: [FileEntry]) {
        guard !files.isEmpty else { return }
        
        dbQueue.sync {
            // Begin transaction
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            
            let insertSQL = """
            INSERT OR REPLACE INTO files (path, name, extension, size, modified_time, indexed_time, folder_root)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }
            
            defer { sqlite3_finalize(statement) }
            
            for file in files {
                sqlite3_bind_text(statement, 1, (file.path as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (file.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (file.extension as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(statement, 4, file.size)
                sqlite3_bind_text(statement, 5, (file.modifiedTime as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 6, (file.indexedTime as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 7, (file.folderRoot as NSString).utf8String, -1, nil)
                
                if sqlite3_step(statement) != SQLITE_DONE {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    return
                }
                
                sqlite3_reset(statement)
            }
            
            // Commit transaction
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }
    
    struct FileEntry {
        let path: String
        let name: String
        let `extension`: String
        let size: Int64
        let modifiedTime: String
        let indexedTime: String
        let folderRoot: String
    }
}

// MARK: - 8. Add Better Logging (10 minutes)

import OSLog

extension Logger {
    static let dexxerIndexing = Logger(subsystem: "com.mattgrilli.dexxer", category: "indexing")
    static let dexxerDatabase = Logger(subsystem: "com.mattgrilli.dexxer", category: "database")
    static let dexxerSearch = Logger(subsystem: "com.mattgrilli.dexxer", category: "search")
}

// Replace print() with Logger:
// Logger.dexxerIndexing.info("🔍 Starting indexing...")
// Logger.dexxerIndexing.error("❌ Failed to open folder: \(path)")

// MARK: - 9. Add Progress Details (5 minutes)

extension FileIndexer {
    @Published var currentIndexingFolder: String = ""
    @Published var currentFolderFileCount: Int = 0
    
    // Update in your indexing loop:
    // currentIndexingFolder = folderRoot
    // currentFolderFileCount = fileCount
}

// MARK: - 10. Add Stats by Folder (10 minutes)

extension FileIndexer {
    func getStatsByFolder() -> [String: (count: Int, size: Int64)] {
        var stats: [String: (Int, Int64)] = [:]
        
        dbQueue.sync {
            var statement: OpaquePointer?
            let sql = """
            SELECT folder_root, COUNT(*), COALESCE(SUM(size), 0)
            FROM files
            GROUP BY folder_root
            """
            
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    let folder = String(cString: sqlite3_column_text(statement, 0))
                    let count = Int(sqlite3_column_int(statement, 1))
                    let size = sqlite3_column_int64(statement, 2)
                    stats[folder] = (count, size)
                }
            }
            
            sqlite3_finalize(statement)
        }
        
        return stats
    }
}

// MARK: - 11. Refactor Search to Use URL Instead of String (10 minutes)

struct ImprovedFileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL  // Much better than String!
    let fileExtension: String
    let size: Int64
    let modifiedTime: Date
    let folderRoot: URL
    
    // Convenience accessors
    var path: String { url.path }
    var name: String { url.lastPathComponent }
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var modifiedDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modifiedTime)
    }
}

// MARK: - 12. Add File Type Categories (10 minutes)

enum FileCategory: String, CaseIterable {
    case document = "Documents"
    case image = "Images"
    case video = "Videos"
    case audio = "Audio"
    case code = "Code"
    case archive = "Archives"
    case other = "Other"
    
    var extensions: Set<String> {
        switch self {
        case .document:
            return ["pdf", "doc", "docx", "txt", "rtf", "pages", "md", "csv", "xlsx", "xls"]
        case .image:
            return ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "bmp", "svg", "webp"]
        case .video:
            return ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v"]
        case .audio:
            return ["mp3", "wav", "aac", "flac", "m4a", "ogg", "wma"]
        case .code:
            return ["swift", "py", "js", "ts", "java", "cpp", "c", "h", "html", "css", "json", "xml"]
        case .archive:
            return ["zip", "rar", "7z", "tar", "gz", "bz2", "dmg", "iso"]
        case .other:
            return []
        }
    }
    
    static func category(for extension: String) -> FileCategory {
        let ext = `extension`.lowercased()
        return allCases.first { $0.extensions.contains(ext) } ?? .other
    }
    
    var icon: String {
        switch self {
        case .document: return "doc.fill"
        case .image: return "photo.fill"
        case .video: return "video.fill"
        case .audio: return "music.note"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archive: return "archivebox.fill"
        case .other: return "doc"
        }
    }
}

// MARK: - Summary of Quick Wins

/*
 Apply these in order for maximum impact with minimum effort:
 
 ✅ 1. Add autoreleasepool (2 min) - Reduces memory by 50-80%
 ✅ 2. Enable WAL mode (1 min) - Better concurrency
 ✅ 3. Add batch transactions (15 min) - 50-100x faster indexing
 ✅ 4. Extract date formatter (5 min) - Small perf boost
 ✅ 5. Add constants (5 min) - Better maintainability
 ✅ 6. Add error types (10 min) - Better UX
 ✅ 7. Use Logger instead of print (10 min) - Better debugging
 ✅ 8. Add progress details (5 min) - Better UX
 ✅ 9. Add stats by folder (10 min) - Useful feature
 ✅ 10. Add file categories (10 min) - Better organization
 
 Total time: ~1.5 hours
 Impact: HUGE! Faster, more reliable, better UX
*/
#endif  // End of example code
