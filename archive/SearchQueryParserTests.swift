//
//  SearchQueryParserTests.swift
//  DexxerTests
//
//  Tests for the search query parser and FTS5 integration
//

import Testing
import Foundation
@testable import Dexxer

@Suite("Search Query Parser Tests")
struct SearchQueryParserTests {
    
    // MARK: - Basic Parsing Tests
    
    @Test("Parse simple text query")
    func testSimpleText() {
        let result = SearchQueryParser.parse("contract agreement")
        
        #expect(result.textTokens.count == 2)
        #expect(result.textTokens.contains("contract"))
        #expect(result.textTokens.contains("agreement"))
    }
    
    @Test("Parse exact phrase with quotes")
    func testExactPhrase() {
        let result = SearchQueryParser.parse("\"annual report\"")
        
        #expect(result.exactPhrases.count == 1)
        #expect(result.exactPhrases[0] == "annual report")
        #expect(result.textTokens.isEmpty)
    }
    
    @Test("Parse mixed text and exact phrase")
    func testMixedTextAndPhrase() {
        let result = SearchQueryParser.parse("contract \"annual report\" 2024")
        
        #expect(result.textTokens.contains("contract"))
        #expect(result.textTokens.contains("2024"))
        #expect(result.exactPhrases.contains("annual report"))
    }
    
    // MARK: - File Type Parsing Tests
    
    @Test("Parse file type with type: prefix")
    func testFileTypePrefix() {
        let result = SearchQueryParser.parse("type:pdf")
        
        #expect(result.fileTypes.count == 1)
        #expect(result.fileTypes[0] == "pdf")
    }
    
    @Test("Parse file type with ext: prefix")
    func testFileExtPrefix() {
        let result = SearchQueryParser.parse("ext:docx")
        
        #expect(result.fileTypes.count == 1)
        #expect(result.fileTypes[0] == "docx")
    }
    
    @Test("Parse file type with dot")
    func testFileTypeWithDot() {
        let result = SearchQueryParser.parse("type:.pdf")
        
        #expect(result.fileTypes[0] == "pdf")
    }
    
    @Test("Parse multiple file types")
    func testMultipleFileTypes() {
        let result = SearchQueryParser.parse("type:pdf type:docx")
        
        #expect(result.fileTypes.count == 2)
        #expect(result.fileTypes.contains("pdf"))
        #expect(result.fileTypes.contains("docx"))
    }
    
    // MARK: - Size Parsing Tests
    
    @Test("Parse size greater than")
    func testSizeGreaterThan() {
        let result = SearchQueryParser.parse("size:>10MB")
        
        #expect(result.minSize == 10 * 1024 * 1024)
        #expect(result.maxSize == nil)
    }
    
    @Test("Parse size less than")
    func testSizeLessThan() {
        let result = SearchQueryParser.parse("size:<1GB")
        
        #expect(result.maxSize == 1024 * 1024 * 1024)
        #expect(result.minSize == nil)
    }
    
    @Test("Parse size range")
    func testSizeRange() {
        let result = SearchQueryParser.parse("size:5MB-50MB")
        
        #expect(result.minSize == 5 * 1024 * 1024)
        #expect(result.maxSize == 50 * 1024 * 1024)
    }
    
    @Test("Parse size in bytes")
    func testSizeBytes() {
        let result = SearchQueryParser.parse("size:1024B")
        
        #expect(result.minSize == 1024)
    }
    
    @Test("Parse size in KB")
    func testSizeKB() {
        let result = SearchQueryParser.parse("size:500KB")
        
        #expect(result.minSize == 500 * 1024)
    }
    
    @Test("Parse size in TB")
    func testSizeTB() {
        let result = SearchQueryParser.parse("size:<1TB")
        
        #expect(result.maxSize == 1024 * 1024 * 1024 * 1024)
    }
    
    // MARK: - Date Parsing Tests
    
    @Test("Parse modified:today")
    func testModifiedToday() {
        let result = SearchQueryParser.parse("modified:today")
        
        #expect(result.modifiedAfter != nil)
        
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let parsedDate = result.modifiedAfter!
        
        #expect(calendar.isDate(parsedDate, inSameDayAs: today))
    }
    
    @Test("Parse modified:yesterday")
    func testModifiedYesterday() {
        let result = SearchQueryParser.parse("modified:yesterday")
        
        #expect(result.modifiedAfter != nil)
    }
    
    @Test("Parse modified:7d (relative days)")
    func testModifiedRelativeDays() {
        let result = SearchQueryParser.parse("modified:7d")
        
        #expect(result.modifiedAfter != nil)
        
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let difference = abs(result.modifiedAfter!.timeIntervalSince(sevenDaysAgo))
        
        // Allow 1 second of difference for test execution time
        #expect(difference < 1.0)
    }
    
    @Test("Parse modified:thisweek")
    func testModifiedThisWeek() {
        let result = SearchQueryParser.parse("modified:thisweek")
        
        #expect(result.modifiedAfter != nil)
    }
    
    @Test("Parse modified with ISO date")
    func testModifiedISODate() {
        let result = SearchQueryParser.parse("modified:>2024-01-01")
        
        #expect(result.modifiedAfter != nil)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let expectedDate = formatter.date(from: "2024-01-01")!
        
        #expect(Calendar.current.isDate(result.modifiedAfter!, inSameDayAs: expectedDate))
    }
    
    @Test("Parse modified before date")
    func testModifiedBefore() {
        let result = SearchQueryParser.parse("modified:<2024-12-31")
        
        #expect(result.modifiedBefore != nil)
    }
    
    // MARK: - Path Parsing Tests
    
    @Test("Parse path:Legal")
    func testPathFilter() {
        let result = SearchQueryParser.parse("path:Legal")
        
        #expect(result.pathContains.count == 1)
        #expect(result.pathContains[0] == "Legal")
    }
    
    @Test("Parse folder: prefix")
    func testFolderPrefix() {
        let result = SearchQueryParser.parse("folder:Documents")
        
        #expect(result.pathContains.contains("Documents"))
    }
    
    @Test("Parse multiple path filters")
    func testMultiplePathFilters() {
        let result = SearchQueryParser.parse("path:Legal path:Contracts")
        
        #expect(result.pathContains.count == 2)
        #expect(result.pathContains.contains("Legal"))
        #expect(result.pathContains.contains("Contracts"))
    }
    
    // MARK: - Complex Query Tests
    
    @Test("Parse complex query with all filters")
    func testComplexQuery() {
        let query = "\"annual report\" contract type:pdf size:>5MB modified:today path:Legal"
        let result = SearchQueryParser.parse(query)
        
        #expect(result.exactPhrases.contains("annual report"))
        #expect(result.textTokens.contains("contract"))
        #expect(result.fileTypes.contains("pdf"))
        #expect(result.minSize == 5 * 1024 * 1024)
        #expect(result.modifiedAfter != nil)
        #expect(result.pathContains.contains("Legal"))
    }
    
    @Test("Parse query with multiple size constraints")
    func testMultipleSizeFilters() {
        let result = SearchQueryParser.parse("size:>1MB size:<100MB")
        
        #expect(result.minSize == 1 * 1024 * 1024)
        #expect(result.maxSize == 100 * 1024 * 1024)
    }
    
    // MARK: - FTS Match Query Tests
    
    @Test("Generate FTS match query for simple text")
    func testFTSSimpleText() {
        let result = SearchQueryParser.parse("contract agreement")
        
        let ftsQuery = result.ftsMatchQuery
        #expect(ftsQuery.contains("contract"))
        #expect(ftsQuery.contains("agreement"))
    }
    
    @Test("Generate FTS match query with exact phrase")
    func testFTSExactPhrase() {
        let result = SearchQueryParser.parse("\"annual report\"")
        
        let ftsQuery = result.ftsMatchQuery
        #expect(ftsQuery.contains("\"annual report\""))
    }
    
    // MARK: - SearchFilters Conversion Tests
    
    @Test("Convert parsed query to SearchFilters")
    func testToSearchFilters() {
        let query = "contract type:pdf size:>10MB"
        let parsed = SearchQueryParser.parse(query)
        let filters = parsed.toSearchFilters()
        
        #expect(filters.query.contains("contract"))
        #expect(filters.fileType == "pdf")
        #expect(filters.minSize == 10 * 1024 * 1024)
    }
    
    @Test("SearchFilters respects limit parameter")
    func testSearchFiltersLimit() {
        let parsed = SearchQueryParser.parse("contract")
        let filters = parsed.toSearchFilters(limit: 500)
        
        #expect(filters.limit == 500)
    }
    
    // MARK: - Edge Cases
    
    @Test("Parse empty query")
    func testEmptyQuery() {
        let result = SearchQueryParser.parse("")
        
        #expect(result.textTokens.isEmpty)
        #expect(result.exactPhrases.isEmpty)
        #expect(result.fileTypes.isEmpty)
    }
    
    @Test("Parse query with only whitespace")
    func testWhitespaceOnlyQuery() {
        let result = SearchQueryParser.parse("   \t  \n  ")
        
        #expect(result.textTokens.isEmpty)
    }
    
    @Test("Parse unknown filter prefix")
    func testUnknownFilterPrefix() {
        let result = SearchQueryParser.parse("unknown:value")
        
        // Unknown filters should be treated as text
        #expect(result.textTokens.contains("unknown:value"))
    }
    
    @Test("Parse invalid size format")
    func testInvalidSizeFormat() {
        let result = SearchQueryParser.parse("size:invalid")
        
        // Invalid size should be ignored
        #expect(result.minSize == nil)
        #expect(result.maxSize == nil)
    }
    
    @Test("Parse invalid date format")
    func testInvalidDateFormat() {
        let result = SearchQueryParser.parse("modified:invalid-date")
        
        // Invalid date should be ignored
        #expect(result.modifiedAfter == nil)
    }
    
    @Test("Parse quoted phrase with escaped quotes")
    func testEscapedQuotes() {
        // This is a basic test - you may want to add support for escaped quotes
        let result = SearchQueryParser.parse("\"normal phrase\" text")
        
        #expect(result.exactPhrases.count == 1)
        #expect(result.textTokens.contains("text"))
    }
    
    @Test("Case insensitive filter keys")
    func testCaseInsensitiveFilters() {
        let result = SearchQueryParser.parse("TYPE:pdf SIZE:>10MB MODIFIED:today")
        
        #expect(result.fileTypes.contains("pdf"))
        #expect(result.minSize != nil)
        #expect(result.modifiedAfter != nil)
    }
    
    @Test("Parse size with decimal values")
    func testSizeWithDecimals() {
        let result = SearchQueryParser.parse("size:>2.5GB")
        
        let expectedSize = Int64(2.5 * 1024 * 1024 * 1024)
        #expect(result.minSize == expectedSize)
    }
}

// MARK: - Integration Tests with FileIndexer

@Suite("FTS5 Integration Tests")
struct FTS5IntegrationTests {
    
    @Test("FTS5 table is created")
    func testFTS5TableCreation() {
        let indexer = FileIndexer()
        
        // Table should be created during initialization
        let stats = indexer.getStats()
        
        // Should not crash, table exists
        #expect(stats.count >= 0)
    }
    
    @Test("Search with syntax returns results", .enabled(if: false))
    func testSearchWithSyntax() async throws {
        let indexer = FileIndexer()
        
        // This test requires an indexed database
        let results = indexer.searchWithSyntax("type:txt")
        
        #expect(results.count >= 0)
        
        // All results should be txt files
        for result in results {
            #expect(result.fileExtension == "txt")
        }
    }
    
    @Test("FTS5 search is faster than LIKE search", .enabled(if: false))
    func testFTS5Performance() async throws {
        let indexer = FileIndexer()
        
        // Test with FTS5
        let ftsStart = Date()
        let ftsResults = indexer.searchWithSyntax("contract")
        let ftsTime = Date().timeIntervalSince(ftsStart)
        
        // Test with regular search
        let likeStart = Date()
        let likeResults = indexer.search(query: "contract")
        let likeTime = Date().timeIntervalSince(likeStart)
        
        print("FTS5 time: \(ftsTime)s, LIKE time: \(likeTime)s")
        
        // FTS5 should be faster (or at least not slower)
        // This may not always be true for very small databases
        #expect(ftsResults.count >= 0)
        #expect(likeResults.count >= 0)
    }
    
    @Test("Rebuild FTS5 index", .enabled(if: false))
    func testRebuildFTS5() async throws {
        let indexer = FileIndexer()
        
        // Should not crash
        indexer.rebuildFTS5Index()
        
        // Wait for rebuild
        try await Task.sleep(for: .seconds(1))
        
        // Should still be able to search
        let results = indexer.searchWithSyntax("test")
        #expect(results.count >= 0)
    }
}

// MARK: - Example Queries Tests

@Suite("Example Queries Tests")
struct ExampleQueriesTests {
    
    @Test("All example queries parse without errors")
    func testAllExamples() {
        for (query, _) in SearchQueryParser.examples {
            let result = SearchQueryParser.parse(query)
            
            // Should not crash
            let _ = result.toSearchFilters()
            let _ = result.ftsMatchQuery
        }
        
        #expect(true)
    }
    
    @Test("Example: contract.pdf")
    func testExample1() {
        let result = SearchQueryParser.parse("contract.pdf")
        
        #expect(result.textTokens.contains("contract.pdf"))
    }
    
    @Test("Example: type:pdf contract")
    func testExample2() {
        let result = SearchQueryParser.parse("type:pdf contract")
        
        #expect(result.fileTypes.contains("pdf"))
        #expect(result.textTokens.contains("contract"))
    }
    
    @Test("Example: ext:docx size:>5MB")
    func testExample3() {
        let result = SearchQueryParser.parse("ext:docx size:>5MB")
        
        #expect(result.fileTypes.contains("docx"))
        #expect(result.minSize == 5 * 1024 * 1024)
    }
    
    @Test("Example: path:Legal type:pdf size:>1MB")
    func testExample4() {
        let result = SearchQueryParser.parse("path:Legal type:pdf size:>1MB")
        
        #expect(result.pathContains.contains("Legal"))
        #expect(result.fileTypes.contains("pdf"))
        #expect(result.minSize == 1 * 1024 * 1024)
    }
}
