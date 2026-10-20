//
//  FileIndexer+Network.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation

extension FileIndexer {

    /// True when the folder exists and its contents can actually be listed with the access
    /// we hold. Can block for a long time on a hung network mount, so never call it on the main thread.
    func isReachableFolder(_ path: String) -> Bool {
        let scopedURL = BookmarkStore.resolve(path: path)
        let didStartScope = scopedURL?.startAccessingSecurityScopedResource() ?? false
        defer { if didStartScope { scopedURL?.stopAccessingSecurityScopedResource() } }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // Existence alone isn't enough: in the sandbox a folder can exist but be unreadable
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Check if folder is on a network volume (SMB, AFP, NFS, etc.)
    func isNetworkFolder(_ path: String) -> Bool {
        if path.hasPrefix("/Volumes/") {
            return true
        }

        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal {
            return !isLocal
        }
        return false
    }
}
