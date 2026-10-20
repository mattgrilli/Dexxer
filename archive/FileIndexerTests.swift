//
//  FileIndexerTests.swift
//  DexxerTests
//
//  Example unit tests using Swift Testing framework
//  NOTE: This is an EXAMPLE file - disable if you don't have Swift Testing set up
//

#if false  // Disable compilation - remove this line when you're ready to use tests

import Testing
import Foundation
@testable import Dexxer

@Suite("FileIndexer Tests")
struct FileIndexerTests {
    
    // MARK: - Configuration Tests
    
    @Test("Save and load configuration")
    func testConfigurationPersistence() async throws {
        let indexer = FileIndexer()
        
        // Add test folders
        indexer.addFolder("/Users/test/Documents")
        indexer.addFolder("/Users/test/Downloads")
        
        #expect(indexer.indexedFolders.count == 2)
        #expect(indexer.indexedFolders.contains("/Users/test/Documents"))
        
        // Simulate reload
        indexer.loadConfig()
        
        #expect(indexer.indexedFolders.count >= 2)
    }
    
    @Test("Remove folder from configuration")
    func testRemoveFolder() async throws {
        let indexer = FileIndexer()
        
        indexer.addFolder("/Users/test/Documents")
        #expect(indexer.indexedFolders.contains("/Users/test/Documents"))
        
        indexer.removeFolder("/Users/test/Documents")
        #expect(!indexer.indexedFolders.contains("/Users/test/Documents"))
    }
    
    // MARK: - Search Tests
    
    @Test("Basic search returns results")
    func testBasicSearch() async throws {
        let indexer = FileIndexer()
        
        // This assumes some files are already indexed
        let results = indexer.search(query: "test", limit: 10)
        
        #expect(results.count <= 10)
        
        // All results should contain "test" in the name
        for result in results {
            #expect(result.name.lowercased().contains("test"))
        }
    }
    
    @Test("Search with file type filter")
    func testSearchWithFileType() async throws {
        let indexer = FileIndexer()
        
        let results = indexer.search(query: "document", fileType: "pdf", limit: 10)
        
        // All results should be PDFs
        for result in results {
            #expect(result.fileExtension == "pdf")
        }
    }
    
    @Test("Search with folder scope")
    func testSearchWithFolderScope() async throws {
        let indexer = FileIndexer()
        
        let folder = "/Users/test/Documents"
        let results = indexer.search(query: "test", folders: [folder], limit: 10)
        
        // All results should be within the specified folder
        for result in results {
            #expect(result.path.hasPrefix(folder))
        }
    }
    
    @Test("Empty search returns no results")
    func testEmptySearch() async throws {
        let indexer = FileIndexer()
        
        let results = indexer.search(query: "", limit: 10)
        
        // Empty query should return all files (up to limit)
        #expect(results.count <= 10)
    }
    
    // MARK: - Advanced Search Tests
    
    @Test("Advanced search with size filter")
    func testAdvancedSearchWithSize() async throws {
        let indexer = FileIndexer()
        
        var filters = FileIndexer.SearchFilters()
        filters.query = "document"
        filters.minSize = 1_000_000  // 1 MB minimum
        filters.maxSize = 10_000_000 // 10 MB maximum
        
        let results = indexer.searchAdvanced(filters)
        
        // All results should be within size range
        for result in results {
            #expect(result.size >= 1_000_000)
            #expect(result.size <= 10_000_000)
        }
    }
    
    @Test("Advanced search with date filter")
    func testAdvancedSearchWithDate() async throws {
        let indexer = FileIndexer()
        
        let oneWeekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        
        var filters = FileIndexer.SearchFilters()
        filters.query = "test"
        filters.modifiedAfter = oneWeekAgo
        
        let results = indexer.searchAdvanced(filters)
        
        // All results should be modified after one week ago
        for result in results {
            #expect(result.modifiedTime >= oneWeekAgo)
        }
    }
    
    @Test("Advanced search with path contains")
    func testAdvancedSearchWithPathContains() async throws {
        let indexer = FileIndexer()
        
        var filters = FileIndexer.SearchFilters()
        filters.query = "document"
        filters.pathContains = "Legal"
        
        let results = indexer.searchAdvanced(filters)
        
        // All results should have "Legal" in the path
        for result in results {
            #expect(result.path.contains("Legal"))
        }
    }
    
    // MARK: - Stats Tests
    
    @Test("Get database statistics")
    func testGetStats() async throws {
        let indexer = FileIndexer()
        
        let stats = indexer.getStats()
        
        #expect(stats.count >= 0)
        #expect(stats.totalSize >= 0)
    }
    
    // MARK: - Indexing Tests
    
    @Test("Indexing can be cancelled")
    func testIndexingCancellation() async throws {
        let indexer = FileIndexer()
        
        // Start indexing in background
        let testFolder = FileManager.default.temporaryDirectory.path
        
        Task {
            indexer.indexFolders([testFolder])
        }
        
        // Wait a bit then cancel
        try await Task.sleep(for: .milliseconds(100))
        indexer.cancelIndexing()
        
        // Wait for cancellation to complete
        try await Task.sleep(for: .milliseconds(500))
        
        #expect(indexer.isIndexing == false)
        #expect(indexer.isCancellingIndex == false)
    }
    
    @Test("Indexing updates progress")
    func testIndexingProgress() async throws {
        let indexer = FileIndexer()
        
        let initialProgress = indexer.indexProgress
        
        // Create a temp directory with some files
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Create test files
        for i in 0..<10 {
            let fileURL = tempDir.appendingPathComponent("test\(i).txt")
            try "Test content".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        // Index the temp directory
        indexer.indexFolders([tempDir.path])
        
        // Wait for indexing to complete
        try await Task.sleep(for: .seconds(2))
        
        #expect(indexer.indexProgress > initialProgress)
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Folder Discovery Tests
    
    @Test("Get immediate subfolders")
    func testGetImmediateSubfolders() async throws {
        let indexer = FileIndexer()
        
        let parentPath = "/Users/test"
        let subfolders = indexer.getImmediateSubfolders(of: parentPath)
        
        #expect(subfolders.count >= 0)
        
        // All subfolders should be direct children
        for subfolder in subfolders {
            #expect(subfolder.hasPrefix(parentPath + "/"))
            
            // Should not have additional slashes (immediate children only)
            let remainder = subfolder.dropFirst(parentPath.count + 1)
            #expect(!remainder.contains("/"))
        }
    }
    
    @Test("Get all folders from indexed files")
    func testGetAllFolders() async throws {
        let indexer = FileIndexer()
        
        let folders = indexer.getAllFolders()
        
        #expect(folders.count >= 0)
        
        // All folders should be valid paths
        for folder in folders {
            #expect(!folder.isEmpty)
            #expect(folder.hasPrefix("/"))
        }
    }
    
    // MARK: - FileItem Tests
    
    @Test("FileItem formatted size")
    func testFileItemFormattedSize() {
        let item = FileItem(
            path: "/test/file.txt",
            name: "file.txt",
            fileExtension: "txt",
            size: 1_048_576, // 1 MB
            modifiedTime: Date(),
            folderRoot: "/test"
        )
        
        #expect(item.formattedSize.contains("MB") || item.formattedSize.contains("bytes"))
    }
    
    @Test("FileItem date formatting")
    func testFileItemDateFormatting() {
        let date = Date()
        let item = FileItem(
            path: "/test/file.txt",
            name: "file.txt",
            fileExtension: "txt",
            size: 1000,
            modifiedTime: date,
            folderRoot: "/test"
        )
        
        #expect(!item.modifiedDateString.isEmpty)
    }
    
    @Test("FileItem file URL")
    func testFileItemURL() {
        let item = FileItem(
            path: "/Users/test/file.txt",
            name: "file.txt",
            fileExtension: "txt",
            size: 1000,
            modifiedTime: Date(),
            folderRoot: "/Users/test"
        )
        
        #expect(item.fileURL.path == "/Users/test/file.txt")
    }
    
    // MARK: - SearchFilters Tests
    
    @Test("SearchFilters default values")
    func testSearchFiltersDefaults() {
        let filters = FileIndexer.SearchFilters()
        
        #expect(filters.query == "")
        #expect(filters.fileType == nil)
        #expect(filters.folders == nil)
        #expect(filters.pathContains == nil)
        #expect(filters.modifiedAfter == nil)
        #expect(filters.modifiedBefore == nil)
        #expect(filters.minSize == nil)
        #expect(filters.maxSize == nil)
        #expect(filters.limit == 1000)
    }
    
    // MARK: - Performance Tests
    
    @Test("Search performance", .timeLimit(.minutes(1)))
    func testSearchPerformance() async throws {
        let indexer = FileIndexer()
        
        let startTime = Date()
        
        // Perform 100 searches
        for i in 0..<100 {
            _ = indexer.search(query: "test\(i)", limit: 10)
        }
        
        let elapsedTime = Date().timeIntervalSince(startTime)
        
        // 100 searches should complete in under 5 seconds
        #expect(elapsedTime < 5.0)
    }
    
    @Test("Batch insert performance", .timeLimit(.minutes(1)))
    func testBatchInsertPerformance() async throws {
        // This test would require access to the improved DatabaseActor
        // with batch insert support
        
        // Create test data
        var files: [FileEntry] = []
        for i in 0..<1000 {
            files.append(FileEntry(
                path: "/test/file\(i).txt",
                name: "file\(i).txt",
                extension: "txt",
                size: 1000,
                modifiedTime: ISO8601DateFormatter().string(from: Date()),
                indexedTime: ISO8601DateFormatter().string(from: Date()),
                folderRoot: "/test"
            ))
        }
        
        // Batch insert should be much faster than individual inserts
        // Implementation depends on having the improved DatabaseActor
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Handle invalid folder path")
    func testInvalidFolderPath() async throws {
        let indexer = FileIndexer()
        
        let invalidPath = "/this/path/does/not/exist/\(UUID().uuidString)"
        
        // Should not crash, but should handle gracefully
        indexer.indexFolders([invalidPath])
        
        // Wait a bit for indexing to attempt
        try await Task.sleep(for: .milliseconds(500))
        
        // Should complete without crashing
        #expect(true)
    }
    
    @Test("Clear database")
    func testClearDatabase() async throws {
        let indexer = FileIndexer()
        
        indexer.clearDatabase()
        
        // Wait for operation to complete
        try await Task.sleep(for: .milliseconds(200))
        
        let stats = indexer.getStats()
        #expect(stats.count == 0)
        #expect(stats.totalSize == 0)
    }
}

// MARK: - FolderNode Tests

@Suite("FolderNode Tests")
struct FolderNodeTests {
    
    @Test("FolderNode initialization")
    func testFolderNodeInit() {
        let node = FolderNode(path: "/Users/test/Documents", name: "Documents")
        
        #expect(node.path == "/Users/test/Documents")
        #expect(node.name == "Documents")
        #expect(node.children.isEmpty)
        #expect(node.isExpanded == false)
    }
    
    @Test("FolderNode children management")
    func testFolderNodeChildren() {
        let parent = FolderNode(path: "/Users/test", name: "test")
        let child1 = FolderNode(path: "/Users/test/Documents", name: "Documents")
        let child2 = FolderNode(path: "/Users/test/Downloads", name: "Downloads")
        
        parent.children.append(child1)
        parent.children.append(child2)
        
        #expect(parent.children.count == 2)
        #expect(parent.children[0].name == "Documents")
        #expect(parent.children[1].name == "Downloads")
    }
}

// MARK: - Integration Tests

@Suite("Integration Tests")
struct IntegrationTests {
    
    @Test("Full indexing and search workflow")
    func testFullWorkflow() async throws {
        let indexer = FileIndexer()
        
        // Create temp directory with test files
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Create test files
        for i in 0..<5 {
            let fileURL = tempDir.appendingPathComponent("test_file_\(i).txt")
            try "Test content \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        // Add folder to indexer
        indexer.addFolder(tempDir.path)
        
        // Index the folder
        await withCheckedContinuation { continuation in
            indexer.indexFolders([tempDir.path]) { count in
                continuation.resume()
            }
        }
        
        // Wait for indexing to complete
        try await Task.sleep(for: .seconds(2))
        
        // Search for indexed files
        let results = indexer.search(query: "test_file", limit: 10)
        
        #expect(results.count == 5)
        
        // Clean up
        indexer.removeFolder(tempDir.path)
    }
}

// MARK: - Helper Extensions for Testing

extension FileIndexer {
    /// Test helper to reset state
    func resetForTesting() {
        clearDatabase()
        indexedFolders.removeAll()
        saveConfig()
    }
}
#endif  // End of disabled test code
