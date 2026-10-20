//
//  SearchModel.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import AppKit

/// Search state, kept outside the views so it survives switching to Settings and back,
/// and so the menu bar and dexxer:// links can drive it.
final class SearchModel: ObservableObject {
    enum SortOrder: String, CaseIterable, Identifiable {
        case relevance, nameAscending, nameDescending, sizeDescending, sizeAscending, dateDescending, dateAscending

        var id: Self { self }

        var label: String {
            switch self {
            case .relevance: return "Best Match"
            case .nameAscending: return "Name (A–Z)"
            case .nameDescending: return "Name (Z–A)"
            case .sizeDescending: return "Largest First"
            case .sizeAscending: return "Smallest First"
            case .dateDescending: return "Newest First"
            case .dateAscending: return "Oldest First"
            }
        }
    }

    static let resultLimit = 1000

    @Published var text = ""
    @Published var fileType = "All"
    @Published var folderFilter: Set<String> = []
    @Published var sortOrder: SortOrder = .relevance {
        didSet { updateRows() }
    }
    @Published var selection: FileItem.ID?
    @Published var showPreview = false
    @Published private(set) var rows: [FileItem] = []
    /// Indexed folder (e.g. a community) to narrow the current results to; nil shows all
    @Published var rootFilter: String? {
        didSet { updateRows() }
    }
    /// Result counts per indexed folder, for the filter chips
    @Published private(set) var facets: [Facet] = []

    struct Facet: Identifiable {
        let root: String
        let count: Int
        var id: String { root }
        var name: String { URL(fileURLWithPath: root).lastPathComponent }
    }
    @Published private(set) var isSearching = false
    @Published private(set) var recentSearches: [String] = []
    /// Bumped to ask the search field to take focus
    @Published private(set) var focusRequest = 0

    private let indexer: FileIndexer
    private var results: [FileItem] = []
    private var pending: DispatchWorkItem?
    /// Incremented per search so a slow, older search can't overwrite newer results
    private var generation = 0
    private static let recentSearchesKey = "RecentSearches"

    init(indexer: FileIndexer) {
        self.indexer = indexer
        if let data = UserDefaults.standard.data(forKey: Self.recentSearchesKey),
           let searches = try? JSONDecoder().decode([String].self, from: data) {
            recentSearches = searches
        }
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hitLimit: Bool { results.count >= Self.resultLimit }

    var selectedItem: FileItem? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    func requestFocus() {
        focusRequest += 1
    }

    // MARK: - Searching

    func search(debounce: Bool = true) {
        pending?.cancel()
        generation += 1
        let currentGeneration = generation

        let query = trimmedText
        guard !query.isEmpty else {
            results = []
            rows = []
            facets = []
            selection = nil
            isSearching = false
            return
        }

        let type = fileType == "All" ? nil : fileType
        let folders = Array(folderFilter)
        let indexer = indexer

        let work = DispatchWorkItem { [weak self] in
            self?.isSearching = true
            DispatchQueue.global(qos: .userInitiated).async {
                let found = indexer.search(query, fileType: type, folders: folders, limit: Self.resultLimit)
                DispatchQueue.main.async {
                    guard let self, currentGeneration == self.generation else { return }
                    self.results = found
                    self.facets = Dictionary(grouping: found, by: \.folderRoot)
                        .map { Facet(root: $0.key, count: $0.value.count) }
                        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
                    if let root = self.rootFilter, !self.facets.contains(where: { $0.root == root }) {
                        self.rootFilter = nil
                    }
                    self.updateRows()
                    self.isSearching = false
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.15 : 0), execute: work)
    }

    /// Runs a search immediately, e.g. from a dexxer://search link
    func search(for query: String) {
        text = query
        search(debounce: false)
        requestFocus()
    }

    private func updateRows() {
        rows = sorted(rootFilter.map { root in results.filter { $0.folderRoot == root } } ?? results)
        if !rows.contains(where: { $0.id == selection }) {
            selection = rows.first?.id
        }
    }

    private func sorted(_ items: [FileItem]) -> [FileItem] {
        switch sortOrder {
        case .relevance:
            return items
        case .nameAscending:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeDescending:
            return items.sorted { $0.size > $1.size }
        case .sizeAscending:
            return items.sorted { $0.size < $1.size }
        case .dateDescending:
            return items.sorted { $0.modifiedTime > $1.modifiedTime }
        case .dateAscending:
            return items.sorted { $0.modifiedTime < $1.modifiedTime }
        }
    }

    // MARK: - Selection and actions

    func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : rows.count)
        selection = rows[min(max(current + offset, 0), rows.count - 1)].id
    }

    func openSelected() {
        if let selectedItem { open(selectedItem) }
    }

    func open(_ item: FileItem) {
        rememberSearch()
        BookmarkStore.withAccess(to: item.folderRoot) {
            _ = NSWorkspace.shared.open(item.fileURL)
        }
    }

    func reveal(_ item: FileItem) {
        rememberSearch()
        BookmarkStore.withAccess(to: item.folderRoot) {
            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
        }
    }

    // MARK: - Recent searches

    /// Recorded when a result is used, so the list holds searches that actually found something
    private func rememberSearch() {
        let query = trimmedText
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0 == query }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(20))
        saveRecentSearches()
    }

    func clearRecentSearches() {
        recentSearches.removeAll()
        saveRecentSearches()
    }

    private func saveRecentSearches() {
        if let data = try? JSONEncoder().encode(recentSearches) {
            UserDefaults.standard.set(data, forKey: Self.recentSearchesKey)
        }
    }
}
