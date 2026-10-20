//
//  DexxerTests.swift
//  DexxerTests
//
//  Created by Matthew Grilli on 10/24/25.
//

import XCTest
import AppKit
@testable import Dexxer

final class SearchQueryParserTests: XCTestCase {

    func testFiltersAndText() {
        let parsed = SearchQueryParser.parse("invoice type:PDF path:Legal size:>=10MB modified:7d")
        XCTAssertEqual(parsed.textTokens, ["invoice"])
        XCTAssertEqual(parsed.fileTypes, ["pdf"])
        XCTAssertEqual(parsed.pathContains, ["Legal"])
        XCTAssertEqual(parsed.minSize, 10 * 1024 * 1024)
        XCTAssertNotNil(parsed.modifiedAfter)
    }

    func testSizeOperators() {
        XCTAssertEqual(SearchQueryParser.parse("size:<=1KB").maxSize, 1024)
        XCTAssertEqual(SearchQueryParser.parse("size:<1GB").maxSize, 1024 * 1024 * 1024)
        let range = SearchQueryParser.parse("size:5MB-50MB")
        XCTAssertEqual(range.minSize, 5 * 1024 * 1024)
        XCTAssertEqual(range.maxSize, 50 * 1024 * 1024)
    }

    func testDates() {
        let before = SearchQueryParser.parse("modified:<2024-12-31")
        XCTAssertNotNil(before.modifiedBefore)
        XCTAssertNil(before.modifiedAfter)
        XCTAssertEqual(SearchQueryParser.parse("modified:today").modifiedAfter, Calendar.current.startOfDay(for: Date()))
    }

    func testPhrasesAndUnknownFilters() {
        let parsed = SearchQueryParser.parse("\"annual report\" foo:bar")
        XCTAssertEqual(parsed.exactPhrases, ["annual report"])
        XCTAssertEqual(parsed.textTokens, ["foo:bar"])
    }

    func testMatchExpressionEscapesPunctuation() {
        XCTAssertEqual(SearchQueryParser.ftsMatchExpression(for: .init(textTokens: ["report.pdf"])), "\"report\"* \"pdf\"*")
        XCTAssertEqual(SearchQueryParser.ftsMatchExpression(for: .init(textTokens: ["my-file"])), "\"my\"* \"file\"*")
        XCTAssertEqual(SearchQueryParser.ftsMatchExpression(for: .init(exactPhrases: ["Q4 2024"])), "\"Q4 2024\"*")
        XCTAssertNil(SearchQueryParser.ftsMatchExpression(for: .init(textTokens: ["__"])))
    }
}

final class FileIndexerTests: XCTestCase {
    private var workDir: URL!
    private var root: URL!
    private var indexer: FileIndexer!
    private var savedDefaults: [String: Any] = [:]
    private let settingsKeys = ["DexxerOCREnabled", "DexxerExcludePatternsEnabled"]

    override func setUpWithError() throws {
        // Tests run inside the app, so keep its real settings intact
        for key in settingsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }

        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("DexxerTests-\(UUID().uuidString)")
        root = workDir.appendingPathComponent("Root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write("a/invoice-2024.pdf", pdfText: "Quarterly zebra statement")
        try write("a/notes.txt")
        try write("ab/other.txt")
        try write("node_modules/dependency.js")

        indexer = FileIndexer(directory: workDir)
        indexer.ocrEnabled = true
        indexer.excludePatternsEnabled = true
        guard case .added = indexer.addFolder(root) else { return XCTFail("folder not added") }
    }

    override func tearDownWithError() throws {
        indexer = nil
        try? FileManager.default.removeItem(at: workDir)
        for key in settingsKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func write(_ relativePath: String, pdfText: String? = nil) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let pdfText {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            view.string = pdfText
            try view.dataWithPDF(inside: view.bounds).write(to: url)
        } else {
            try Data("hello".utf8).write(to: url)
        }
    }

    private func index() {
        let done = expectation(description: "indexed")
        indexer.indexFolders { _ in done.fulfill() }
        wait(for: [done], timeout: 60)
    }

    private func names(_ query: String, folders: [String] = []) -> Set<String> {
        Set(indexer.search(query, folders: folders).map(\.name))
    }

    func testIndexesAndSearches() {
        index()
        XCTAssertEqual(names("invoice"), ["invoice-2024.pdf"])
        XCTAssertEqual(names("invoice-2024.pdf"), ["invoice-2024.pdf"], "punctuation must not break the query")
        XCTAssertEqual(names("invo"), ["invoice-2024.pdf"], "partial words match")
        XCTAssertEqual(names("zebra"), ["invoice-2024.pdf"], "PDF text is searchable")
        XCTAssertEqual(names("type:txt"), ["notes.txt", "other.txt"])
        XCTAssertTrue(names("dependency").isEmpty, "excluded folders are skipped")
    }

    func testFolderFilterDoesNotMatchSiblingPrefix() {
        index()
        let folderA = root.appendingPathComponent("a").path
        XCTAssertEqual(names("type:txt", folders: [folderA]), ["notes.txt"])
    }

    func testReindexKeepsExtractedTextWhenOCRIsOff() {
        index()
        indexer.ocrEnabled = false
        index()
        XCTAssertEqual(names("zebra"), ["invoice-2024.pdf"])
    }

    func testReindexPicksUpAddedAndDeletedFiles() throws {
        index()
        try FileManager.default.removeItem(at: root.appendingPathComponent("a/notes.txt"))
        try write("a/minutes.txt")
        index()
        XCTAssertTrue(names("notes").isEmpty)
        XCTAssertEqual(names("minutes"), ["minutes.txt"])
    }

    func testRemoveFolderDeletesItsRows() {
        index()
        indexer.removeFolder(root.standardizedFileURL.path)
        XCTAssertTrue(names("invoice").isEmpty)
    }
}
