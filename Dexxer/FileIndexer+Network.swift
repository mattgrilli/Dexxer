//
//  FileIndexer+Network.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation

extension FileIndexer {

    /// Called when a volume mounts (e.g., /Volumes/TeamShare).
    /// If any saved indexed folder is inside that volume, notify but don't auto-index.
    func resumeIfFolderInside(mountedVolumeURL: URL) {
        let root = mountedVolumeURL.path  // e.g., "/Volumes/TeamShare"
        // match either the root itself or subpaths under it
        let matches = indexedFolders.filter { $0 == root || $0.hasPrefix(root + "/") }
        guard !matches.isEmpty else { return }

        print("📡 Network share mounted: \(root)")
        print("   Found \(matches.count) indexed folder(s) on this share")

        // Don't auto-reindex - just log the event
        // User can manually refresh from the Folders tab if needed
    }

    /// Enhanced reachability check - matches what indexing uses
    func isReachableFolder(_ path: String) -> Bool {
        // Try to resolve security-scoped bookmark first
        let urlForPath: URL = BookmarkStore.resolve(path: path) ?? URL(fileURLWithPath: path)

        var didStartScope = false
        if urlForPath.startAccessingSecurityScopedResource() {
            didStartScope = true
        }

        defer {
            if didStartScope {
                urlForPath.stopAccessingSecurityScopedResource()
            }
        }

        var isDir: ObjCBool = false

        // First check basic existence
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else {
            print("⚠️ Folder '\(path)' does not exist or is not a directory")
            return false
        }

        // Test reachability the same way indexing does: try to enumerate
        // Note: isReadableFile() gives false negatives for ODrive/virtual filesystems
        let fileManager = FileManager.default
        guard let _ = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            print("⚠️ Folder '\(path)' cannot be enumerated (permission denied)")
            return false
        }

        print("✅ Folder '\(path)' is reachable and enumerable")
        return true
    }

    /// Check if folder is on a network volume (SMB, AFP, NFS, etc.)
    func isNetworkFolder(_ path: String) -> Bool {
        // Check standard /Volumes/ mount point
        if path.hasPrefix("/Volumes/") {
            print("🌐 \(path) detected as network (starts with /Volumes/)")
            return true
        }

        // Check URL resource values for network volume
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey]),
           let isLocal = values.volumeIsLocal {
            let isNet = !isLocal
            print("🌐 \(path) volumeIsLocal=\(isLocal), detected as \(isNet ? "network" : "local")")
            return isNet  // Not local = network
        }

        print("🌐 \(path) - couldn't determine, defaulting to local")
        return false
    }
}
