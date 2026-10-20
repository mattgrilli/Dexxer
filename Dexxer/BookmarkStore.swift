// BookmarkStore.swift
import Foundation

/// Security-scoped bookmarks for indexed folders, so the sandboxed app keeps access across launches.
enum BookmarkStore {
    private static let key = "DexxerIndexedFolderBookmarks"

    static func save(path: String, url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        var map = loadAll()
        map[path] = data
        store(map)
    }

    static func remove(path: String) {
        var map = loadAll()
        map[path] = nil
        store(map)
    }

    static func resolve(path: String) -> URL? {
        guard let data = loadAll()[path] else { return nil }
        var stale = false
        // Never mount or show UI: resolving a bookmark to an unmounted share would otherwise
        // try to connect to the server (and pop an error when it isn't reachable)
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope, .withoutMounting, .withoutUI],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }

        // Stale bookmarks (e.g. after a share remounts) stop working eventually; renew while we still can
        if stale, url.startAccessingSecurityScopedResource() {
            save(path: path, url: url)
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }

    /// Runs `body` with access to the indexed folder `root` (needed for files under network shares).
    static func withAccess<T>(to root: String, _ body: () -> T) -> T {
        let url = resolve(path: root)
        let didStart = url?.startAccessingSecurityScopedResource() ?? false
        defer { if didStart { url?.stopAccessingSecurityScopedResource() } }
        return body()
    }

    private static func store(_ map: [String: Data]) {
        if let blob = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: false) {
            UserDefaults.standard.set(blob, forKey: key)
        }
    }

    private static func loadAll() -> [String: Data] {
        guard let blob = UserDefaults.standard.data(forKey: key) else { return [:] }
        do {
            let classes = [NSDictionary.self, NSString.self, NSData.self]
            return try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: blob) as? [String: Data] ?? [:]
        } catch {
            print("⚠️ Failed to load bookmarks: \(error)")
            return [:]
        }
    }
}
