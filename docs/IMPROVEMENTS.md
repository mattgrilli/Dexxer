# FileIndexer.swift - Comprehensive Improvement Guide

## 📋 Executive Summary

Your Dexxer app is well-structured and functional! Here are prioritized improvements ranging from critical fixes to nice-to-have enhancements.

---

## 🚨 Critical Issues (Fix First)

### 1. **Thread Safety with SQLite**

**Problem**: Using `DispatchQueue.sync` inside background threads with SQLite can cause crashes and data corruption. SQLite connections are not thread-safe by default.

**Solution**: Migrate to Swift Concurrency with an `actor` to ensure serial access:

```swift
actor DatabaseActor {
    private var db: OpaquePointer?
    
    func execute<T>(_ operation: (OpaquePointer?) throws -> T) rethrows -> T {
        return try operation(db)
    }
}
```

**Impact**: Prevents crashes, improves reliability
**Effort**: Medium (2-3 hours)

---

### 2. **Memory Leaks in File Enumeration**

**Problem**: The `enumerator` can accumulate a lot of `URL` objects during indexing, consuming significant memory for large folders.

**Solution**: Use `autoreleasepool` in the enumeration loop:

```swift
for case let fileURL as URL in enumerator {
    autoreleasepool {
        // Your processing code here
    }
}
```

**Impact**: Reduces memory footprint by 50-80% during indexing
**Effort**: Low (15 minutes)

---

### 3. **Missing Error Handling**

**Problem**: Silent failures in database operations (e.g., `try?` swallowing errors)

**Solution**: Add proper error types and surface them to users:

```swift
enum IndexerError: LocalizedError {
    case databaseOpenFailed(String)
    case permissionDenied(String)
    case indexingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let path):
            return "Failed to open database at \(path)"
        case .permissionDenied(let folder):
            return "Permission denied for folder: \(folder)"
        case .indexingFailed(let reason):
            return "Indexing failed: \(reason)"
        }
    }
}
```

**Impact**: Better debugging and user experience
**Effort**: Medium (1-2 hours)

---

## ⚡ Performance Improvements

### 4. **Batch Database Inserts**

**Problem**: Inserting one file at a time is slow (100x slower than batching)

**Solution**: Use transactions with batched inserts:

```swift
// Start transaction
sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

// Insert 100-500 files
for file in fileBatch {
    // insert file
}

// Commit transaction
sqlite3_exec(db, "COMMIT", nil, nil, nil)
```

**Impact**: 50-100x faster indexing (especially for network drives)
**Effort**: Low (30 minutes)

---

### 5. **Optimize Search Query**

**Problem**: Full table scans on large databases

**Solution**: Add Full-Text Search (FTS5) for blazing-fast searches:

```swift
let createFTSTable = """
CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
    name, 
    path, 
    content=files, 
    content_rowid=id
);
"""

// Populate FTS index
let populateFTS = """
INSERT INTO files_fts(rowid, name, path)
SELECT id, name, path FROM files;
"""
```

Then search with:
```swift
SELECT files.* FROM files_fts 
JOIN files ON files.id = files_fts.rowid 
WHERE files_fts MATCH ?
```

**Impact**: 10-100x faster search on large databases
**Effort**: Medium (2 hours)

---

### 6. **Add Incremental Indexing**

**Problem**: Re-indexing scans every file, even unchanged ones

**Solution**: Track file modification times and only index changed files:

```swift
func incrementalIndex(folderPath: String) {
    let lastIndexTime = getLastIndexTime(for: folderPath)
    
    for case let fileURL as URL in enumerator {
        guard let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modDate > lastIndexTime else {
            continue // Skip unchanged files
        }
        
        // Index only changed files
    }
    
    updateLastIndexTime(for: folderPath)
}
```

**Impact**: 90%+ faster re-indexing
**Effort**: Medium (2-3 hours)

---

## 🎨 Code Quality Improvements

### 7. **Extract Search Logic into Separate Type**

**Problem**: `FileIndexer` is doing too many things (indexing + searching + folder management + config)

**Solution**: Apply Single Responsibility Principle:

```swift
struct FileSearcher {
    let dbActor: DatabaseActor
    
    func search(_ filters: SearchFilters) async -> [FileItem] {
        // All search logic here
    }
}

struct FolderManager {
    func addFolder(_ path: String) { }
    func removeFolder(_ path: String) { }
    func getFolderHierarchy() -> [FolderNode] { }
}
```

**Impact**: Better testability, maintainability
**Effort**: Medium (2-3 hours)

---

### 8. **Replace Print Statements with Structured Logging**

**Problem**: `print()` statements are hard to filter and debug in production

**Solution**: Use Apple's `os.log` framework:

```swift
import OSLog

extension Logger {
    static let indexer = Logger(subsystem: "com.mattgrilli.dexxer", category: "indexing")
    static let search = Logger(subsystem: "com.mattgrilli.dexxer", category: "search")
}

// Usage
Logger.indexer.info("🔍 Starting indexing for \(foldersToIndex.count) folders")
Logger.indexer.error("❌ Failed to open database: \(error.localizedDescription)")
```

**Impact**: Better debugging, production monitoring
**Effort**: Low (1 hour)

---

### 9. **Use Swift Testing Framework**

**Problem**: No tests for critical database and search logic

**Solution**: Add unit tests:

```swift
import Testing

@Suite("FileIndexer Tests")
struct FileIndexerTests {
    
    @Test("Search returns correct results")
    func testBasicSearch() async throws {
        let indexer = FileIndexer()
        let results = indexer.search(query: "test", limit: 10)
        
        #expect(results.count <= 10)
        #expect(results.allSatisfy { $0.name.contains("test") })
    }
    
    @Test("Indexing handles cancellation")
    func testIndexCancellation() async throws {
        let indexer = FileIndexer()
        
        Task {
            try await Task.sleep(for: .milliseconds(100))
            indexer.cancelIndexing()
        }
        
        indexer.indexFolders(["/Users/test"])
        
        #expect(indexer.isIndexing == false)
        #expect(indexer.shouldCancelIndexing == true)
    }
}
```

**Impact**: Catch bugs early, enable refactoring
**Effort**: High (4-6 hours)

---

## 🎁 Nice-to-Have Features

### 10. **Add File Content Search**

Enable searching *inside* files (PDF, text, etc.):

```swift
import CoreSpotlight

func indexFileContent(_ fileURL: URL) {
    let attributes = CSSearchableItemAttributeSet(contentType: .content)
    attributes.title = fileURL.lastPathComponent
    
    if let content = try? String(contentsOf: fileURL) {
        attributes.textContent = content
    }
    
    let item = CSSearchableItem(uniqueIdentifier: fileURL.path,
                                domainIdentifier: "com.mattgrilli.dexxer",
                                attributeSet: attributes)
    
    CSSearchableIndex.default().indexSearchableItems([item])
}
```

---

### 11. **Add Smart Filters**

Implement saved searches and smart folders:

```swift
struct SmartFolder: Codable {
    let name: String
    let filters: SearchFilters
    let icon: String
    
    static let presets = [
        SmartFolder(name: "Large Files", 
                   filters: SearchFilters(minSize: 100_000_000),
                   icon: "doc.fill"),
        SmartFolder(name: "Recent PDFs",
                   filters: SearchFilters(fileType: "pdf", modifiedAfter: Date().addingTimeInterval(-7*86400)),
                   icon: "doc.richtext.fill")
    ]
}
```

---

### 12. **Add Search Syntax**

Support power-user queries:

```
type:pdf size:>10MB modified:today "contract" path:/Legal
```

Parse with:

```swift
struct QueryParser {
    func parse(_ query: String) -> SearchFilters {
        var filters = SearchFilters()
        
        // Extract special syntax
        let typeRegex = /type:(\w+)/
        let sizeRegex = /size:(>|<)(\d+)(MB|GB|KB)/
        
        // ... parsing logic
        
        return filters
    }
}
```

---

### 13. **Add Export/Import**

Allow users to backup and share indexed folders:

```swift
func exportIndex() throws -> Data {
    let export = IndexExport(
        folders: indexedFolders,
        fileCount: getStats().count,
        exportDate: Date()
    )
    return try JSONEncoder().encode(export)
}

func importIndex(from data: Data) throws {
    let imported = try JSONDecoder().decode(IndexExport.self, from: data)
    indexedFolders.append(contentsOf: imported.folders)
    saveConfig()
}
```

---

### 14. **Improve UI Progress Feedback**

Show which folder is currently being indexed:

```swift
@Published var currentIndexingFolder: String = ""
@Published var currentFolderProgress: (current: Int, total: Int) = (0, 0)

// During indexing:
DispatchQueue.main.async {
    self.currentIndexingFolder = folderRoot
    self.currentFolderProgress = (fileCount, estimatedTotal)
}
```

---

## 📊 Recommended Priority

### Phase 1 - Critical (Week 1)
1. ✅ Thread Safety with Actor
2. ✅ Memory Management with autoreleasepool
3. ✅ Error Handling

### Phase 2 - Performance (Week 2)
4. ✅ Batch Database Inserts
5. ✅ FTS5 Full-Text Search
6. ✅ Incremental Indexing

### Phase 3 - Quality (Week 3)
7. ✅ Refactor into Smaller Types
8. ✅ Structured Logging
9. ✅ Unit Tests

### Phase 4 - Features (Ongoing)
10. Content Search
11. Smart Filters
12. Query Syntax
13. Export/Import
14. Better Progress UI

---

## 🔍 Code Smells Found

1. **God Object**: `FileIndexer` has too many responsibilities
2. **Long Methods**: `indexFolders()` is 150+ lines
3. **Magic Numbers**: `100`, `500`, `1000` should be constants
4. **Primitive Obsession**: Using `String` for paths instead of `URL`
5. **Feature Envy**: `FolderNode` should be in its own file

---

## 🛠 Quick Wins (Do Today)

### Add Constants
```swift
private enum IndexingConstants {
    static let batchSize = 100
    static let progressUpdateInterval = 100
    static let defaultSearchLimit = 1000
}
```

### Extract ISO8601DateFormatter
```swift
private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    return formatter
}()
```

### Use URL Instead of String
```swift
struct FileItem {
    let url: URL  // Instead of path: String
    var path: String { url.path }
}
```

---

## 📚 Additional Resources

- [SQLite Best Practices](https://www.sqlite.org/bestpractice.html)
- [Swift Concurrency (WWDC 2021)](https://developer.apple.com/videos/play/wwdc2021/10132/)
- [Full-Text Search with FTS5](https://www.sqlite.org/fts5.html)
- [Core Spotlight for Content Indexing](https://developer.apple.com/documentation/corespotlight)

---

## 🎯 Summary

Your code is **solid** and functional! The main improvements are:

1. **Thread safety** → Prevent crashes
2. **Performance** → Make it 10-100x faster
3. **Code organization** → Make it maintainable
4. **Features** → Make it more powerful

Start with thread safety and batching (biggest impact for least effort), then tackle the others based on user feedback.

Great work on building a practical alternative to Spotlight! 🚀
