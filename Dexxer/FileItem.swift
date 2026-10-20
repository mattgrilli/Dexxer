//
//  FileItem.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation

struct FileItem: Identifiable, Hashable {
    let path: String
    let name: String
    let fileExtension: String
    let size: Int64
    let modifiedTime: Date
    let folderRoot: String
    /// Excerpt around a match inside the file's text, with highlights marked (see FileIndexer.highlightStart)
    var snippet: String? = nil

    /// The path is unique in the index, so it keeps selection stable across searches
    var id: String { path }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var formattedSize: String {
        Self.sizeFormatter.string(fromByteCount: size)
    }

    var modifiedDateString: String {
        Self.dateFormatter.string(from: modifiedTime)
    }

    /// The snippet with matched words in bold
    var highlightedSnippet: AttributedString? {
        guard let snippet else { return nil }
        var result = AttributedString()
        // Alternates plain and highlighted pieces: "plain \u{2}match\u{3} plain"
        for (offset, piece) in snippet.components(separatedBy: FileIndexer.highlightStart).enumerated() {
            let parts = piece.components(separatedBy: FileIndexer.highlightEnd)
            if offset > 0, let match = parts.first {
                var bold = AttributedString(match)
                bold.inlinePresentationIntent = .stronglyEmphasized
                result += bold
                result += AttributedString(parts.dropFirst().joined())
            } else {
                result += AttributedString(piece)
            }
        }
        return result
    }

    var fileURL: URL {
        URL(fileURLWithPath: path)
    }

    /// Folder containing the file
    var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }

    /// Where the file is, starting from its indexed folder: "Maple Ridge HOA › Vendors & Contracts".
    /// Shown under the name in results; the full path is in the preview and tooltip.
    var location: String {
        let parent = parentPath
        guard !folderRoot.isEmpty, parent == folderRoot || parent.hasPrefix(folderRoot + "/") else { return parent }
        let subfolders = parent.dropFirst(folderRoot.count).split(separator: "/").map(String.init)
        return ([(folderRoot as NSString).lastPathComponent] + subfolders).joined(separator: " › ")
    }
}
