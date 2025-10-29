//
//  FileItem.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let name: String
    let fileExtension: String
    let size: Int64
    let modifiedTime: Date
    let folderRoot: String
    
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    var modifiedDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modifiedTime)
    }
    
    var fileURL: URL {
        URL(fileURLWithPath: path)
    }
}
