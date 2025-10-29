//
//  ScopesStore.swift
//  Dexxer
//

import Foundation

struct SearchScope: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String                    // e.g. "Legal – Community A"
    var prefixes: [String]              // e.g. ["/Volumes/Share/CommunityA/Legal"]
}

final class ScopesStore: ObservableObject {
    @Published var scopes: [SearchScope] = []

    private let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.dexxer_scopes.json"
    }()

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            scopes = []; return
        }
        do { scopes = try JSONDecoder().decode([SearchScope].self, from: data) }
        catch { print("⚠️ Failed to load scopes: \(error)"); scopes = [] }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(scopes)
            try data.write(to: URL(fileURLWithPath: path))
        } catch { print("⚠️ Failed to save scopes: \(error)") }
    }

    func add(name: String, prefixes: [String]) {
        scopes.append(SearchScope(name: name, prefixes: prefixes))
        save()
    }

    func remove(at offsets: IndexSet) {
        scopes.remove(atOffsets: offsets)
        save()
    }
}
