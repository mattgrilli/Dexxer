// BookmarkStore.swift
import Foundation

enum BookmarkStore {
    private static let key = "DexxerIndexedFolderBookmarks"
    
    // path -> bookmarkData
    static func save(path: String, url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            var map = loadAll()
            map[path] = data
            if let blob = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: false) {
                UserDefaults.standard.set(blob, forKey: key)
            }
        }
    }
    
    static func resolve(path: String) -> URL? {
        let map = loadAll()
        guard let data = map[path] else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return url
        }
        return nil
    }
    
    private static func loadAll() -> [String: Data] {
        guard let blob = UserDefaults.standard.data(forKey: key) else {
            return [:]
        }
        do {
            if #available(macOS 10.15, *) {
                // New API with proper allowed classes
                let classes = [NSDictionary.self, NSString.self, NSData.self]
                return try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: blob) as? [String: Data] ?? [:]
            } else {
                // Fallback for older systems
                return try (NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(blob) as? [String: Data]) ?? [:]
            }
        } catch {
            print("⚠️ Failed to load bookmarks: \(error)")
            return [:]
        }
    }
}

