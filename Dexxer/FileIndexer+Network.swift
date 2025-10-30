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

    /// Enhanced reachability check with better network detection
    func isReachableFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false

        // First check basic existence
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }

        // Check if readable
        guard FileManager.default.isReadableFile(atPath: path) else {
            return false
        }

        // For network paths, do a deeper check by trying to list contents
        if isNetworkPath(path) {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return true
            } catch {
                print("⚠️ Network folder '\(path)' not reachable: \(error.localizedDescription)")
                return false
            }
        }

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
