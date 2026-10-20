//
//  SearchQuickStart.swift
//  Dexxer
//
//  Quick examples showing how to use the new search features
//

import Foundation

/// Quick start guide for using advanced search in Dexxer
enum SearchQuickStart {
    
    // MARK: - Basic Examples
    
    /// Example 1: Simple text search
    static func example1_simpleSearch() {
        let indexer = FileIndexer()
        
        // Search for files containing "contract"
        let results = indexer.searchWithSyntax("contract")
        
        print("Found \(results.count) files containing 'contract'")
        for file in results.prefix(5) {
            print("  - \(file.name)")
        }
    }
    
    /// Example 2: Search by file type
    static func example2_fileType() {
        let indexer = FileIndexer()
        
        // Find all PDF files
        let pdfFiles = indexer.searchWithSyntax("type:pdf")
        print("Found \(pdfFiles.count) PDF files")
        
        // Find Word documents containing "report"
        let reports = indexer.searchWithSyntax("type:docx report")
        print("Found \(reports.count) Word documents with 'report'")
    }
    
    /// Example 3: Search by file size
    static func example3_fileSize() {
        let indexer = FileIndexer()
        
        // Find files larger than 10MB
        let largeFiles = indexer.searchWithSyntax("size:>10MB")
        print("Found \(largeFiles.count) files larger than 10MB")
        
        // Find small images (less than 1MB)
        let smallImages = indexer.searchWithSyntax("type:jpg size:<1MB")
        print("Found \(smallImages.count) small JPEG images")
        
        // Find files in size range
        let mediumFiles = indexer.searchWithSyntax("size:5MB-50MB")
        print("Found \(mediumFiles.count) files between 5-50MB")
    }
    
    /// Example 4: Search by modification date
    static func example4_modifiedDate() {
        let indexer = FileIndexer()
        
        // Find files modified today
        let todayFiles = indexer.searchWithSyntax("modified:today")
        print("Found \(todayFiles.count) files modified today")
        
        // Find files modified in last 7 days
        let recentFiles = indexer.searchWithSyntax("modified:7d")
        print("Found \(recentFiles.count) files from last week")
        
        // Find PDFs modified this month
        let recentPDFs = indexer.searchWithSyntax("type:pdf modified:thismonth")
        print("Found \(recentPDFs.count) PDFs modified this month")
    }
    
    /// Example 5: Search by path/folder
    static func example5_pathFilter() {
        let indexer = FileIndexer()
        
        // Find files in Legal folder
        let legalFiles = indexer.searchWithSyntax("path:Legal")
        print("Found \(legalFiles.count) files in Legal folder")
        
        // Find PDFs in Documents
        let docPDFs = indexer.searchWithSyntax("path:Documents type:pdf")
        print("Found \(docPDFs.count) PDFs in Documents")
    }
    
    /// Example 6: Exact phrase search
    static func example6_exactPhrase() {
        let indexer = FileIndexer()
        
        // Search for exact phrase
        let reports = indexer.searchWithSyntax("\"annual report\"")
        print("Found \(reports.count) files with exact phrase 'annual report'")
        
        // Combine with filters
        let quarterlyReports = indexer.searchWithSyntax(
            "\"quarterly report\" type:pdf modified:thismonth"
        )
        print("Found \(quarterlyReports.count) recent quarterly reports")
    }
    
    /// Example 7: Complex queries
    static func example7_complexQueries() {
        let indexer = FileIndexer()
        
        // Find large PDFs modified recently in Legal folder
        let query1 = "type:pdf size:>5MB modified:7d path:Legal"
        let results1 = indexer.searchWithSyntax(query1)
        print("Query: \(query1)")
        print("Results: \(results1.count) files")
        
        // Find recent invoices
        let query2 = "invoice type:pdf modified:thismonth size:>100KB"
        let results2 = indexer.searchWithSyntax(query2)
        print("\nQuery: \(query2)")
        print("Results: \(results2.count) files")
        
        // Find contract documents from this year
        let query3 = "\"contract agreement\" type:docx modified:>2024-01-01"
        let results3 = indexer.searchWithSyntax(query3)
        print("\nQuery: \(query3)")
        print("Results: \(results3.count) files")
    }
    
    // MARK: - Advanced Examples
    
    /// Example 8: Programmatic filters
    static func example8_programmaticFilters() {
        let indexer = FileIndexer()
        
        // Build filters programmatically
        var filters = FileIndexer.SearchFilters()
        filters.query = "contract"
        filters.fileType = "pdf"
        filters.minSize = 5 * 1024 * 1024  // 5MB
        filters.modifiedAfter = Calendar.current.startOfDay(for: Date())
        filters.pathContains = "Legal"
        filters.limit = 50
        
        let results = indexer.searchAdvanced(filters)
        print("Found \(results.count) matching files")
    }
    
    /// Example 9: Using the parser directly
    static func example9_usingParser() {
        // Parse a complex query
        let queryString = "type:pdf size:>10MB modified:today path:Legal contract"
        let parsed = SearchQueryParser.parse(queryString)
        
        print("Parsed Query:")
        print("  Text tokens: \(parsed.textTokens)")
        print("  File types: \(parsed.fileTypes)")
        print("  Min size: \(parsed.minSize ?? 0) bytes")
        print("  Modified after: \(parsed.modifiedAfter?.formatted() ?? "N/A")")
        print("  Path contains: \(parsed.pathContains)")
        
        // Convert to filters
        let filters = parsed.toSearchFilters()
        
        // Get FTS5 match query
        let ftsQuery = parsed.ftsMatchQuery
        print("  FTS5 query: \(ftsQuery)")
    }
    
    /// Example 10: Maintenance operations
    static func example10_maintenance() {
        let indexer = FileIndexer()
        
        // Rebuild FTS5 index (after database migration or if search is slow)
        print("Rebuilding FTS5 index...")
        indexer.rebuildFTS5Index()
        print("✅ FTS5 index rebuilt")
        
        // Optimize FTS5 index (run periodically for best performance)
        print("Optimizing FTS5 index...")
        indexer.optimizeFTS5Index()
        print("✅ FTS5 index optimized")
        
        // Get database statistics
        let stats = indexer.getStats()
        print("\nDatabase Statistics:")
        print("  Total files: \(stats.count)")
        print("  Total size: \(ByteCountFormatter.string(fromByteCount: stats.totalSize, countStyle: .file))")
    }
    
    // MARK: - Real-World Use Cases
    
    /// Use Case 1: Find large files to free up space
    static func useCase1_findLargeFiles() {
        let indexer = FileIndexer()
        
        // Find files larger than 100MB
        let largeFiles = indexer.searchWithSyntax("size:>100MB")
        
        print("=== Large Files (>100MB) ===")
        for file in largeFiles.sorted(by: { $0.size > $1.size }).prefix(10) {
            let sizeString = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
            print("\(file.name) - \(sizeString)")
        }
    }
    
    /// Use Case 2: Find recent work files
    static func useCase2_recentWork() {
        let indexer = FileIndexer()
        
        // Find documents modified in last 3 days
        let recentDocs = indexer.searchWithSyntax("modified:3d type:docx")
        
        print("=== Recent Word Documents ===")
        for file in recentDocs.sorted(by: { $0.modifiedTime > $1.modifiedTime }).prefix(10) {
            print("\(file.name) - \(file.modifiedDateString)")
        }
    }
    
    /// Use Case 3: Find old files for archival
    static func useCase3_oldFiles() {
        let indexer = FileIndexer()
        
        // Find files not modified in over a year
        let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        
        var filters = FileIndexer.SearchFilters()
        filters.modifiedBefore = oneYearAgo
        filters.limit = 100
        
        let oldFiles = indexer.searchAdvanced(filters)
        
        print("=== Old Files (>1 year) ===")
        for file in oldFiles.sorted(by: { $0.modifiedTime < $1.modifiedTime }).prefix(10) {
            print("\(file.name) - Last modified: \(file.modifiedDateString)")
        }
    }
    
    /// Use Case 4: Organize photos by size
    static func useCase4_organizePhotos() {
        let indexer = FileIndexer()
        
        // Small photos (< 1MB)
        let smallPhotos = indexer.searchWithSyntax("type:jpg size:<1MB")
        print("Small photos (<1MB): \(smallPhotos.count)")
        
        // Medium photos (1-5MB)
        let mediumPhotos = indexer.searchWithSyntax("type:jpg size:1MB-5MB")
        print("Medium photos (1-5MB): \(mediumPhotos.count)")
        
        // Large photos (>5MB)
        let largePhotos = indexer.searchWithSyntax("type:jpg size:>5MB")
        print("Large photos (>5MB): \(largePhotos.count)")
    }
    
    /// Use Case 5: Audit legal documents
    static func useCase5_auditLegalDocs() {
        let indexer = FileIndexer()
        
        // Find all contracts
        let contracts = indexer.searchWithSyntax("contract path:Legal type:pdf")
        print("Total contracts: \(contracts.count)")
        
        // Find recent contracts
        let recentContracts = indexer.searchWithSyntax("contract path:Legal type:pdf modified:thismonth")
        print("Contracts this month: \(recentContracts.count)")
        
        // Find large contract files
        let largeContracts = indexer.searchWithSyntax("contract path:Legal type:pdf size:>5MB")
        print("Large contracts (>5MB): \(largeContracts.count)")
    }
    
    // MARK: - Run All Examples
    
    /// Run all examples (for testing/demo purposes)
    static func runAllExamples() {
        print("=== Dexxer Search Quick Start Examples ===\n")
        
        print("Example 1: Simple Search")
        example1_simpleSearch()
        print()
        
        print("Example 2: File Type")
        example2_fileType()
        print()
        
        print("Example 3: File Size")
        example3_fileSize()
        print()
        
        print("Example 4: Modified Date")
        example4_modifiedDate()
        print()
        
        print("Example 5: Path Filter")
        example5_pathFilter()
        print()
        
        print("Example 6: Exact Phrase")
        example6_exactPhrase()
        print()
        
        print("Example 7: Complex Queries")
        example7_complexQueries()
        print()
        
        print("Example 8: Programmatic Filters")
        example8_programmaticFilters()
        print()
        
        print("Example 9: Using Parser")
        example9_usingParser()
        print()
        
        print("=== Real-World Use Cases ===\n")
        
        print("Use Case 1: Find Large Files")
        useCase1_findLargeFiles()
        print()
        
        print("Use Case 2: Recent Work")
        useCase2_recentWork()
        print()
        
        print("Use Case 3: Old Files")
        useCase3_oldFiles()
        print()
        
        print("Use Case 4: Organize Photos")
        useCase4_organizePhotos()
        print()
        
        print("Use Case 5: Audit Legal Docs")
        useCase5_auditLegalDocs()
        print()
    }
}

// MARK: - Helper Extension for Better Printing

extension FileItem {
    var summaryDescription: String {
        "\(name) - \(formattedSize) - \(modifiedDateString)"
    }
}
