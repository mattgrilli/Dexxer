//
//  SearchQueryParser.swift
//  Dexxer
//
//  Advanced search query parser with support for filters
//  Supports syntax like: type:pdf size:>10MB modified:today path:Legal "exact phrase"
//

import Foundation

/// Parses natural language search queries into structured filters
public struct SearchQueryParser {
    
    // MARK: - Parsed Query Result
    
    public struct ParsedQuery {
        var textTokens: [String] = []          // Regular search terms
        var exactPhrases: [String] = []        // Quoted phrases
        var fileTypes: [String] = []           // type:pdf or ext:pdf
        var pathContains: [String] = []        // path:Legal or folder:Documents
        var minSize: Int64?                    // size:>10MB
        var maxSize: Int64?                    // size:<1GB
        var modifiedAfter: Date?               // modified:>2024-01-01 or modified:today
        var modifiedBefore: Date?              // modified:<2024-01-01
        
        /// Converts to SearchFilters for database query
        public func toSearchFilters(limit: Int = 1000) -> FileIndexer.SearchFilters {
            var filters = FileIndexer.SearchFilters()
            
            // Combine text tokens and exact phrases into query
            let allTerms = textTokens + exactPhrases
            filters.query = allTerms.joined(separator: " ")
            
            // File type (take first one if multiple specified)
            filters.fileType = fileTypes.first
            
            // Path contains (combine all path filters)
            if !pathContains.isEmpty {
                filters.pathContains = pathContains.joined(separator: " ")
            }
            
            // Size filters
            filters.minSize = minSize
            filters.maxSize = maxSize
            
            // Date filters
            filters.modifiedAfter = modifiedAfter
            filters.modifiedBefore = modifiedBefore
            
            filters.limit = limit
            
            return filters
        }
        
        /// FTS5 match query for full-text search
        public var ftsMatchQuery: String {
            var components: [String] = []
            
            // Add individual tokens
            components.append(contentsOf: textTokens)
            
            // Add exact phrases with quotes
            components.append(contentsOf: exactPhrases.map { "\"\($0)\"" })
            
            return components.joined(separator: " ")
        }
    }
    
    // MARK: - Parsing
    
    /// Parse a search query string into structured components
    public static func parse(_ query: String) -> ParsedQuery {
        var result = ParsedQuery()
        
        guard !query.isEmpty else { return result }
        
        // Extract quoted phrases first
        let (withoutQuotes, phrases) = extractQuotedPhrases(from: query)
        result.exactPhrases = phrases
        
        // Tokenize remaining query
        let tokens = tokenize(withoutQuotes)
        
        // Process each token
        for token in tokens {
            if token.contains(":") {
                parseFilter(token, into: &result)
            } else {
                // Regular search term
                result.textTokens.append(token)
            }
        }
        
        return result
    }
    
    // MARK: - Private Helpers
    
    /// Extract quoted phrases from query
    private static func extractQuotedPhrases(from query: String) -> (remaining: String, phrases: [String]) {
        var remaining = query
        var phrases: [String] = []
        
        // Match content between quotes
        let pattern = #""([^"]+)""#
        
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: query, range: NSRange(query.startIndex..., in: query))
            
            // Extract phrases (reverse order to preserve string indices)
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: query) {
                    let phrase = String(query[range])
                    phrases.insert(phrase, at: 0)
                    
                    // Remove from remaining string
                    if let fullRange = Range(match.range, in: remaining) {
                        remaining.removeSubrange(fullRange)
                    }
                }
            }
        }
        
        return (remaining, phrases)
    }
    
    /// Tokenize query into individual terms
    private static func tokenize(_ query: String) -> [String] {
        return query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }
    
    /// Parse a filter token (e.g., "type:pdf", "size:>10MB")
    private static func parseFilter(_ token: String, into result: inout ParsedQuery) {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        
        let key = parts[0].lowercased()
        let value = String(parts[1])
        
        switch key {
        case "type", "ext", "extension":
            parseFileType(value, into: &result)
            
        case "path", "folder", "dir", "directory":
            result.pathContains.append(value)
            
        case "size":
            parseSize(value, into: &result)
            
        case "modified", "date", "mod":
            parseDate(value, into: &result)
            
        default:
            // Unknown filter, treat as regular text
            result.textTokens.append(token)
        }
    }
    
    /// Parse file type filter
    private static func parseFileType(_ value: String, into result: inout ParsedQuery) {
        let cleaned = value.lowercased().replacingOccurrences(of: ".", with: "")
        result.fileTypes.append(cleaned)
    }
    
    /// Parse size filter (e.g., ">10MB", "<1GB", "10MB-100MB")
    private static func parseSize(_ value: String, into result: inout ParsedQuery) {
        let lowerValue = value.lowercased()
        
        // Handle range: "10MB-100MB" or "10-100MB"
        if lowerValue.contains("-") {
            let rangeParts = lowerValue.split(separator: "-")
            if rangeParts.count == 2 {
                result.minSize = parseSizeValue(String(rangeParts[0]))
                result.maxSize = parseSizeValue(String(rangeParts[1]))
            }
            return
        }
        
        // Handle comparison operators
        if lowerValue.hasPrefix(">") {
            let sizeStr = String(lowerValue.dropFirst())
            result.minSize = parseSizeValue(sizeStr)
        } else if lowerValue.hasPrefix("<") {
            let sizeStr = String(lowerValue.dropFirst())
            result.maxSize = parseSizeValue(sizeStr)
        } else if lowerValue.hasPrefix(">=") {
            let sizeStr = String(lowerValue.dropFirst(2))
            result.minSize = parseSizeValue(sizeStr)
        } else if lowerValue.hasPrefix("<=") {
            let sizeStr = String(lowerValue.dropFirst(2))
            result.maxSize = parseSizeValue(sizeStr)
        } else {
            // Exact size (treat as minimum)
            result.minSize = parseSizeValue(lowerValue)
        }
    }
    
    /// Convert size string to bytes (e.g., "10MB" -> 10485760)
    private static func parseSizeValue(_ value: String) -> Int64? {
        let cleanValue = value.trimmingCharacters(in: .whitespaces).lowercased()
        
        // Extract number and unit
        let pattern = #"^(\d+(?:\.\d+)?)\s*([kmgt]?b)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: cleanValue, range: NSRange(cleanValue.startIndex..., in: cleanValue)),
              let numberRange = Range(match.range(at: 1), in: cleanValue) else {
            return nil
        }
        
        guard let number = Double(cleanValue[numberRange]) else { return nil }
        
        // Get unit (default to bytes)
        let unit: String
        if let unitRange = Range(match.range(at: 2), in: cleanValue), !unitRange.isEmpty {
            unit = String(cleanValue[unitRange])
        } else {
            unit = "b"
        }
        
        // Convert to bytes
        let multiplier: Double
        switch unit {
        case "b": multiplier = 1
        case "kb": multiplier = 1024
        case "mb": multiplier = 1024 * 1024
        case "gb": multiplier = 1024 * 1024 * 1024
        case "tb": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        
        return Int64(number * multiplier)
    }
    
    /// Parse date filter (e.g., "today", ">2024-01-01", "7d")
    private static func parseDate(_ value: String, into result: inout ParsedQuery) {
        let lowerValue = value.lowercased()
        
        // Handle comparison operators
        let isAfter = lowerValue.hasPrefix(">")
        let isBefore = lowerValue.hasPrefix("<")
        let cleanValue = lowerValue.trimmingCharacters(in: CharacterSet(charactersIn: "><"))
        
        guard let date = parseDateValue(cleanValue) else { return }
        
        if isAfter {
            result.modifiedAfter = date
        } else if isBefore {
            result.modifiedBefore = date
        } else {
            // No operator - assume "after this date"
            result.modifiedAfter = date
        }
    }
    
    /// Convert date string to Date
    private static func parseDateValue(_ value: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        
        switch value {
        case "today":
            return calendar.startOfDay(for: now)
            
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
            
        case "week", "thisweek":
            return calendar.date(byAdding: .day, value: -7, to: now)
            
        case "month", "thismonth":
            return calendar.date(byAdding: .month, value: -1, to: now)
            
        case "year", "thisyear":
            return calendar.date(byAdding: .year, value: -1, to: now)
            
        default:
            // Try relative days (e.g., "7d", "30d")
            if let days = parseRelativeDays(value) {
                return calendar.date(byAdding: .day, value: -days, to: now)
            }
            
            // Try ISO date format (YYYY-MM-DD)
            if let date = ISO8601DateFormatter().date(from: value) {
                return date
            }
            
            // Try date without time
            let dateOnlyFormatter = DateFormatter()
            dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
            if let date = dateOnlyFormatter.date(from: value) {
                return date
            }
            
            return nil
        }
    }
    
    /// Parse relative days (e.g., "7d" -> 7, "30d" -> 30)
    private static func parseRelativeDays(_ value: String) -> Int? {
        let pattern = #"^(\d+)d$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let numberRange = Range(match.range(at: 1), in: value),
              let days = Int(value[numberRange]) else {
            return nil
        }
        return days
    }
}

// MARK: - Examples and Documentation

public extension SearchQueryParser {
    /// Example queries demonstrating syntax
    static let examples = [
        "contract.pdf" : "Search for files with 'contract' and 'pdf' in name",
        "\"annual report\"" : "Search for exact phrase 'annual report'",
        "type:pdf contract" : "Search for PDF files containing 'contract'",
        "ext:docx size:>5MB" : "Word documents larger than 5MB",
        "modified:today" : "Files modified today",
        "modified:>2024-01-01 type:pdf" : "PDFs modified after Jan 1, 2024",
        "size:<1MB modified:7d" : "Small files modified in last 7 days",
        "path:Legal type:pdf size:>1MB" : "Large PDFs in Legal folder",
        "invoice ext:pdf modified:thismonth" : "PDF invoices from this month",
        "type:jpg size:10MB-100MB" : "JPEG images between 10-100MB"
    ]
    
    /// Help text for search syntax
    static let helpText = """
    Search Syntax:
    
    Basic Search:
      • contract              Search for files containing 'contract'
      • "annual report"       Search for exact phrase
    
    File Type:
      • type:pdf              Filter by extension (pdf, docx, jpg, etc.)
      • ext:docx              Same as type:
    
    File Size:
      • size:>10MB            Files larger than 10MB
      • size:<1GB             Files smaller than 1GB
      • size:5MB-50MB         Files between 5-50MB
      • Units: B, KB, MB, GB, TB
    
    Modified Date:
      • modified:today        Files modified today
      • modified:yesterday    Files modified yesterday
      • modified:7d           Modified in last 7 days
      • modified:thisweek     Modified this week
      • modified:thismonth    Modified this month
      • modified:>2024-01-01  Modified after date
      • modified:<2024-12-31  Modified before date
    
    Path Filter:
      • path:Legal            Files with 'Legal' in path
      • folder:Documents      Files in Documents folder
    
    Combine Filters:
      • type:pdf size:>5MB modified:today path:Legal
      • "quarterly report" ext:docx modified:thismonth
    """
}

// MARK: - Testing Helpers

#if DEBUG
extension SearchQueryParser {
    /// Test the parser with example queries
    static func runTests() {
        print("🧪 Testing SearchQueryParser\n")
        
        // Test 1: Basic text search
        let test1 = parse("contract agreement")
        assert(test1.textTokens == ["contract", "agreement"])
        print("✅ Test 1: Basic text search")
        
        // Test 2: Exact phrase
        let test2 = parse("\"annual report\"")
        assert(test2.exactPhrases == ["annual report"])
        print("✅ Test 2: Exact phrase")
        
        // Test 3: File type
        let test3 = parse("type:pdf")
        assert(test3.fileTypes == ["pdf"])
        print("✅ Test 3: File type")
        
        // Test 4: Size filter
        let test4 = parse("size:>10MB")
        assert(test4.minSize == 10 * 1024 * 1024)
        print("✅ Test 4: Size filter")
        
        // Test 5: Complex query
        let test5 = parse("\"annual report\" type:pdf size:>5MB modified:today path:Legal")
        assert(test5.exactPhrases.contains("annual report"))
        assert(test5.fileTypes.contains("pdf"))
        assert(test5.minSize == 5 * 1024 * 1024)
        assert(test5.modifiedAfter != nil)
        assert(test5.pathContains.contains("Legal"))
        print("✅ Test 5: Complex query")
        
        print("\n✅ All tests passed!")
    }
}
#endif
