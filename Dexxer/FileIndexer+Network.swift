//
//  FileIndexer+Network.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation

extension FileIndexer {

    /// Called when a volume mounts (e.g., /Volumes/TeamShare).
    /// If any saved indexed folder is inside that volume, re-index them.
    func resumeIfFolderInside(mountedVolumeURL: URL) {
        let root = mountedVolumeURL.path  // e.g., "/Volumes/TeamShare"
        // match either the root itself or subpaths under it
        let matches = indexedFolders.filter { $0 == root || $0.hasPrefix(root + "/") }
        guard !matches.isEmpty else { return }
        if !isIndexing {
            indexFolders(matches) { _ in }
        }
    }

    /// Cheap reachability check (use in UI if you want to label disconnected folders).
    func isReachableFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return FileManager.default.isReadableFile(atPath: path)
    }
}
