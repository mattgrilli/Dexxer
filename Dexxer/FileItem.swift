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

    var fileURL: URL {
        URL(fileURLWithPath: path)
    }

    /// Folder containing the file, shown under the name in results
    var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }
}
