//
//  SearchQueryParser.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation

/// Parses search box text into words and filters.
/// Supports: type:pdf size:>10MB modified:today path:Legal "exact phrase"
struct SearchQueryParser {

    struct ParsedQuery: Equatable {
        var textTokens: [String] = []          // Regular search terms
        var exactPhrases: [String] = []        // Quoted phrases
        var fileTypes: [String] = []           // type:pdf or ext:pdf
        var pathContains: [String] = []        // path:Legal or folder:Documents
        var minSize: Int64?                    // size:>10MB
        var maxSize: Int64?                    // size:<1GB
        var modifiedAfter: Date?               // modified:>2024-01-01 or modified:today
        var modifiedBefore: Date?              // modified:<2024-01-01

        var hasText: Bool { !textTokens.isEmpty || !exactPhrases.isEmpty }
    }

    // MARK: - Parsing

    static func parse(_ query: String) -> ParsedQuery {
        var result = ParsedQuery()
        guard !query.isEmpty else { return result }

        let (withoutQuotes, phrases) = extractQuotedPhrases(from: query)
        result.exactPhrases = phrases

        for token in withoutQuotes.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.contains(":") {
                parseFilter(token, into: &result)
            } else {
                result.textTokens.append(token)
            }
        }
        return result
    }

    // MARK: - FTS5

    /// Builds a safe FTS5 MATCH expression. Every word becomes a quoted prefix term, so
    /// punctuation in file names ("report.pdf", "my-file") can't break the query syntax,
    /// and partial words ("contr") still match while typing.
    static func ftsMatchExpression(for query: ParsedQuery) -> String? {
        var terms = query.textTokens.flatMap(words).map { "\"\($0)\"*" }
        terms += query.exactPhrases.map(words).filter { !$0.isEmpty }.map { "\"\($0.joined(separator: " "))\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    /// Splits text the way FTS5's unicode61 tokenizer does: runs of letters and digits.
    static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    // MARK: - Private Helpers

    private static func extractQuotedPhrases(from query: String) -> (remaining: String, phrases: [String]) {
        var remaining = query
        var phrases: [String] = []

        guard let regex = try? NSRegularExpression(pattern: #""([^"]+)""#) else { return (query, []) }
        let matches = regex.matches(in: query, range: NSRange(query.startIndex..., in: query))

        // Reverse order so earlier ranges stay valid while removing
        for match in matches.reversed() {
            guard let phraseRange = Range(match.range(at: 1), in: query),
                  let fullRange = Range(match.range, in: remaining) else { continue }
            phrases.insert(String(query[phraseRange]), at: 0)
            remaining.replaceSubrange(fullRange, with: " ")
        }
        return (remaining, phrases)
    }

    private static func parseFilter(_ token: String, into result: inout ParsedQuery) {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            result.textTokens.append(token)
            return
        }

        let key = parts[0].lowercased()
        let value = String(parts[1])

        switch key {
        case "type", "ext", "extension":
            result.fileTypes.append(value.lowercased().replacingOccurrences(of: ".", with: ""))
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

    /// Parses ">10MB", "<1GB", ">=5KB", "10MB-100MB" or a bare size (treated as a minimum)
    private static func parseSize(_ value: String, into result: inout ParsedQuery) {
        let lowerValue = value.lowercased()

        if lowerValue.contains("-") {
            let rangeParts = lowerValue.split(separator: "-")
            if rangeParts.count == 2 {
                result.minSize = parseSizeValue(String(rangeParts[0]))
                result.maxSize = parseSizeValue(String(rangeParts[1]))
            }
            return
        }

        // Check two-character operators before their one-character prefixes
        if lowerValue.hasPrefix(">=") {
            result.minSize = parseSizeValue(String(lowerValue.dropFirst(2)))
        } else if lowerValue.hasPrefix("<=") {
            result.maxSize = parseSizeValue(String(lowerValue.dropFirst(2)))
        } else if lowerValue.hasPrefix(">") {
            result.minSize = parseSizeValue(String(lowerValue.dropFirst()))
        } else if lowerValue.hasPrefix("<") {
            result.maxSize = parseSizeValue(String(lowerValue.dropFirst()))
        } else {
            result.minSize = parseSizeValue(lowerValue)
        }
    }

    /// Converts "10MB" to bytes
    static func parseSizeValue(_ value: String) -> Int64? {
        let cleanValue = value.trimmingCharacters(in: .whitespaces).lowercased()

        let pattern = #"^(\d+(?:\.\d+)?)\s*([kmgt]?b)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleanValue, range: NSRange(cleanValue.startIndex..., in: cleanValue)),
              let numberRange = Range(match.range(at: 1), in: cleanValue),
              let number = Double(cleanValue[numberRange]) else {
            return nil
        }

        var unit = "b"
        if let unitRange = Range(match.range(at: 2), in: cleanValue), !unitRange.isEmpty {
            unit = String(cleanValue[unitRange])
        }

        let multiplier: Double
        switch unit {
        case "kb": multiplier = 1024
        case "mb": multiplier = 1024 * 1024
        case "gb": multiplier = 1024 * 1024 * 1024
        case "tb": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return Int64(number * multiplier)
    }

    /// Parses "today", "7d", ">2024-01-01", "<2024-12-31"; no operator means "since"
    private static func parseDate(_ value: String, into result: inout ParsedQuery) {
        let lowerValue = value.lowercased()
        let isBefore = lowerValue.hasPrefix("<")
        let cleanValue = lowerValue.trimmingCharacters(in: CharacterSet(charactersIn: "<>="))

        guard let date = parseDateValue(cleanValue) else { return }
        if isBefore {
            result.modifiedBefore = date
        } else {
            result.modifiedAfter = date
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parseDateValue(_ value: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        switch value {
        case "today":
            return startOfToday
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: startOfToday)
        case "week", "thisweek":
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case "month", "thismonth":
            return calendar.dateInterval(of: .month, for: now)?.start
        case "year", "thisyear":
            return calendar.dateInterval(of: .year, for: now)?.start
        default:
            if let days = parseRelativeDays(value) {
                return calendar.date(byAdding: .day, value: -days, to: now)
            }
            return dayFormatter.date(from: value)
        }
    }

    /// "7d" -> 7
    private static func parseRelativeDays(_ value: String) -> Int? {
        guard value.hasSuffix("d") else { return nil }
        return Int(value.dropLast())
    }
}
