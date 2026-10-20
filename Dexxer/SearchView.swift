//
//  SearchView.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import SwiftUI
import Quartz
import UniformTypeIdentifiers

struct SearchContentView: View {
    @ObservedObject var indexer: FileIndexer
    @ObservedObject var model: SearchModel
    @ObservedObject var scopesStore: ScopesStore

    @FocusState private var isSearchFocused: Bool
    @State private var showFolderSelector = false
    @State private var showingSyntaxGuide = false

    static let fileTypes = ["All", "pdf", "doc", "docx", "txt", "xls", "xlsx", "csv",
                            "ppt", "pptx", "jpg", "jpeg", "png", "heic", "gif", "mp4",
                            "mov", "zip", "py", "js", "html", "css", "json", "md"]

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                searchBar
                Divider()
                resultsArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }
            .frame(minWidth: 520)
            .layoutPriority(1)

            if model.showPreview, let item = model.selectedItem {
                PreviewPane(item: item,
                            onOpen: { model.open(item) },
                            onReveal: { model.reveal(item) },
                            onClose: { model.showPreview = false })
                    .frame(minWidth: 280, idealWidth: 380, maxWidth: 640)
            }
        }
        .sheet(isPresented: $showFolderSelector) {
            FolderSelectionView(indexer: indexer, store: scopesStore, selectedPaths: $model.folderFilter) {
                showFolderSelector = false
                model.search(debounce: false)
            }
        }
        .sheet(isPresented: $showingSyntaxGuide) {
            SearchSyntaxQuickGuide()
        }
        .onAppear {
            DispatchQueue.main.async { isSearchFocused = true }
        }
        .onChange(of: model.focusRequest) { _, _ in
            isSearchFocused = true
        }
        .onChange(of: indexer.isIndexing) { _, indexing in
            // Pick up newly indexed files
            if !indexing { model.search(debounce: false) }
        }
        // Space and Return belong to the search field while it's focused
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            if isSearchFocused { return .ignored }
            model.openSelected()
            return .handled
        }
        .onKeyPress(.space) {
            if isSearchFocused { return .ignored }
            model.showPreview.toggle()
            return .handled
        }
        .onKeyPress(.escape) {
            if model.showPreview {
                model.showPreview = false
                return .handled
            }
            if !model.text.isEmpty {
                model.text = ""
                isSearchFocused = true
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Search names, folders, and text in files", text: $model.text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .onSubmit { model.openSelected() }
                .onChange(of: model.text) { _, _ in model.search() }

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if !model.text.isEmpty {
                Button {
                    model.text = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            if !model.recentSearches.isEmpty {
                Menu {
                    ForEach(model.recentSearches.prefix(10), id: \.self) { recent in
                        Button(recent) { model.search(for: recent) }
                    }
                    Divider()
                    Button("Clear Recent Searches") { model.clearRecentSearches() }
                } label: {
                    Image(systemName: "clock")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Recent searches")
            }

            Divider()
                .frame(height: 20)

            Picker("File type", selection: $model.fileType) {
                ForEach(Self.fileTypes, id: \.self) { type in
                    Text(type == "All" ? "All Types" : type.uppercased()).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: model.fileType) { _, _ in model.search(debounce: false) }

            Button {
                showFolderSelector = true
            } label: {
                Label(folderFilterTitle, systemImage: model.folderFilter.isEmpty ? "folder" : "folder.fill")
            }
            .help("Limit the search to specific folders")

            if !model.folderFilter.isEmpty {
                Button {
                    model.folderFilter.removeAll()
                    model.search(debounce: false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Search all folders")
            }

            Button {
                showingSyntaxGuide = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Search syntax: type:, size:, modified:, path:")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var folderFilterTitle: String {
        switch model.folderFilter.count {
        case 0: return "All Folders"
        case 1: return FolderActions.displayName(model.folderFilter.first!)
        default: return "\(model.folderFilter.count) Folders"
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if indexer.indexedFolders.isEmpty {
            EmptyStateView(icon: "folder.badge.plus",
                           title: "Add a folder to get started",
                           message: "Dexxer indexes the folders you choose so you can search them instantly. You can also drag folders onto the sidebar.") {
                Button("Add Folder…") { FolderActions.chooseAndAdd(to: indexer) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if model.trimmedText.isEmpty {
            EmptyStateView(icon: "doc.text.magnifyingglass",
                           title: "Search \(indexer.stats.count.formatted()) files",
                           message: "Matches file names, folder names, and text inside documents and images. Try “invoice type:pdf modified:30d”.") {
                Button("Search Syntax…") { showingSyntaxGuide = true }
                    .buttonStyle(.link)
            }
        } else if model.rows.isEmpty {
            if model.isSearching {
                Color.clear
            } else {
                EmptyStateView(icon: "questionmark.folder",
                               title: "No results for “\(model.trimmedText)”",
                               message: noResultsHint) {
                    HStack {
                        if !model.folderFilter.isEmpty {
                            Button("Search All Folders") {
                                model.folderFilter.removeAll()
                                model.search(debounce: false)
                            }
                        }
                        if model.fileType != "All" {
                            Button("Search All Types") { model.fileType = "All" }
                        }
                    }
                }
            }
        } else {
            resultsList
        }
    }

    private var noResultsHint: String {
        if !model.folderFilter.isEmpty || model.fileType != "All" {
            return "The folder or type filter may be hiding results."
        }
        if indexer.isIndexing {
            return "Indexing is still running, so some files may not be searchable yet."
        }
        return "Check the spelling, or try fewer words."
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            if model.facets.count > 1 {
                FacetBar(model: model)
                Divider()
            }
            ResultsHeader(model: model)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { item in
                            FileRowView(item: item,
                                        isSelected: item.id == model.selection,
                                        onSelect: { model.selection = item.id },
                                        onOpen: { model.open(item) },
                                        onPreview: {
                                            model.selection = item.id
                                            model.showPreview = true
                                        },
                                        onReveal: { model.reveal(item) })
                                .id(item.id)
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .onChange(of: model.selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if !model.rows.isEmpty {
                Text(model.hitLimit
                     ? "Showing the top \(model.rows.count.formatted()) results"
                     : "\(model.rows.count.formatted()) result\(model.rows.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            if indexer.isIndexing {
                Label("Indexing…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.rows.isEmpty {
                Menu {
                    Picker("Sort By", selection: $model.sortOrder) {
                        ForEach(SearchModel.SortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("Sort: \(model.sortOrder.label)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    model.showPreview.toggle()
                } label: {
                    Label(model.showPreview ? "Hide Preview" : "Preview", systemImage: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("Preview the selected file (Space)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Folder chips

/// One chip per indexed folder (community) in the results, to narrow them with one click
struct FacetBar: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", count: model.facets.reduce(0) { $0 + $1.count }, isOn: model.rootFilter == nil) {
                    model.rootFilter = nil
                }
                ForEach(model.facets) { facet in
                    chip(facet.name, count: facet.count, isOn: model.rootFilter == facet.root) {
                        model.rootFilter = model.rootFilter == facet.root ? nil : facet.root
                    }
                    .help(facet.root)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ title: String, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Text(count.formatted())
                    .foregroundStyle(isOn ? Color.white.opacity(0.85) : Color.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isOn ? Color.accentColor : Color.primary.opacity(0.07))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Results header

struct ResultsHeader: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        HStack(spacing: 12) {
            column("Name", .nameAscending, .nameDescending)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 40)
            column("Size", .sizeDescending, .sizeAscending)
                .frame(width: 80, alignment: .trailing)
            column("Modified", .dateDescending, .dateAscending)
                .frame(width: 150, alignment: .trailing)
            Color.clear
                .frame(width: 76)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    /// Clicking a column sorts by it; clicking again reverses the order
    private func column(_ title: String, _ first: SearchModel.SortOrder, _ second: SearchModel.SortOrder) -> some View {
        Button {
            model.sortOrder = model.sortOrder == first ? second : first
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sortOrder == first || model.sortOrder == second {
                    Image(systemName: model.sortOrder == first ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.sortOrder == first || model.sortOrder == second ? .primary : .secondary)
    }
}

// MARK: - File row

struct FileRowView: View {
    let item: FileItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onPreview: () -> Void
    let onReveal: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(for: item.fileExtension))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.location)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                if let snippet = item.highlightedSnippet {
                    Text(snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.formattedSize)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(item.modifiedDateString)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)

            HStack(spacing: 10) {
                Button(action: onPreview) { Image(systemName: "eye") }
                    .help("Preview (Space)")
                Button(action: onOpen) { Image(systemName: "arrow.up.forward.square") }
                    .help("Open (Return)")
                Button(action: onReveal) { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered || isSelected ? 1 : 0)
            .frame(width: 76)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 && !isDemoScreenshot }
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .draggable(item.fileURL)
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Preview", action: onPreview)
            Button("Show in Finder", action: onReveal)
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.name, forType: .string)
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.05) }
        return .clear
    }
}

/// Icons by file type. Looking up by type avoids touching the file, which is slow on network shares.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for ext: String) -> NSImage {
        if let cached = cache[ext] { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = image
        return image
    }
}

// MARK: - Empty states

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            actions
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

struct PreviewPane: View {
    let item: FileItem
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close preview (Esc)")
            }
            .padding(12)

            Divider()

            Group {
                // Quick Look can't show Outlook messages, so render them ourselves
                if item.fileExtension == "msg" {
                    MessagePreview(item: item)
                } else {
                    QuickLookPreview(url: item.fileURL, folderRoot: item.folderRoot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(item.parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("\(item.formattedSize) • \(item.modifiedDateString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open", action: onOpen)
                    Button("Show in Finder", action: onReveal)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    let folderRoot: String

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.autostarts = true
        return preview
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        context.coordinator.show(url, root: folderRoot, in: nsView)
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        // Don't call close(): QLPreviewView asserts (and aborts the app) when closed during teardown
        nsView.previewItem = nil
        coordinator.endAccess()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Holds sandbox access to the file's indexed folder for as long as it's being previewed
    final class Coordinator {
        private var shownURL: URL?
        private var scopedRoot: URL?

        func show(_ url: URL, root: String, in view: QLPreviewView) {
            guard url != shownURL else { return }
            endAccess()
            if let rootURL = BookmarkStore.resolve(path: root), rootURL.startAccessingSecurityScopedResource() {
                scopedRoot = rootURL
            }
            shownURL = url
            view.previewItem = url as NSURL
        }

        func endAccess() {
            scopedRoot?.stopAccessingSecurityScopedResource()
            scopedRoot = nil
        }

        deinit {
            endAccess()
        }
    }
}

/// Headers, attachments, and body of an Outlook .msg file
struct MessagePreview: View {
    let item: FileItem
    @State private var message: OutlookMessage?
    @State private var failed = false

    var body: some View {
        Group {
            if let message {
                content(message)
            } else if failed {
                EmptyStateView(icon: "envelope.badge",
                               title: "Can't Read This Message",
                               message: "The file may be damaged or may not be an Outlook message.") { EmptyView() }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.path) {
            message = nil
            failed = false
            let url = item.fileURL
            let root = item.folderRoot
            let loaded = await Task.detached(priority: .userInitiated) {
                BookmarkStore.withAccess(to: root) { try? OutlookMessage(contentsOf: url) }
            }.value
            message = loaded
            failed = loaded == nil
        }
    }

    private func content(_ message: OutlookMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                header("From", message.from)
                header("To", message.to)
                header("Cc", message.cc)
                if let date = message.date {
                    header("Date", date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

            if !message.attachments.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.attachments) { attachment in
                            Button {
                                open(attachment, from: message)
                            } label: {
                                Label(attachment.name, systemImage: "paperclip")
                                    .lineLimit(1)
                            }
                            .help("Open \(attachment.name) (\(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)))")
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            ScrollView {
                // Very long bodies make Text slow to lay out
                Text(message.body.isEmpty ? "(No text body)" : String(message.body.prefix(100_000)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    @ViewBuilder
    private func header(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Text(value)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
    }

    /// Copies the attachment to a temporary folder and opens it in its default app
    private func open(_ attachment: OutlookMessage.Attachment, from message: OutlookMessage) {
        guard let data = message.data(for: attachment) else {
            infoAlert("Can't Open Attachment", "“\(attachment.name)” is an attached email, which can't be opened on its own yet.")
            return
        }
        let safeName = attachment.name.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(safeName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            infoAlert("Can't Open Attachment", error.localizedDescription)
        }
    }
}

// MARK: - Folder filter

/// How a folder relates to the current filter selection
private enum FolderSelectionState {
    case selected, inherited, none

    init(_ path: String, in selection: Set<String>) {
        if selection.contains(path) {
            self = .selected
        } else if selection.contains(where: { path.hasPrefix($0 + "/") }) {
            self = .inherited
        } else {
            self = .none
        }
    }

    var symbol: String {
        switch self {
        case .selected: return "checkmark.square.fill"
        case .inherited: return "checkmark.square"
        case .none: return "square"
        }
    }

    /// Selecting a folder replaces any selected subfolders, since they're now covered.
    /// Folders included through a selected parent can't be toggled on their own.
    static func toggle(_ path: String, in selection: inout Set<String>) {
        switch FolderSelectionState(path, in: selection) {
        case .selected:
            selection.remove(path)
        case .none:
            selection = selection.filter { !$0.hasPrefix(path + "/") }
            selection.insert(path)
        case .inherited:
            break
        }
    }
}

struct FolderSelectionView: View {
    @ObservedObject var indexer: FileIndexer
    @ObservedObject var store: ScopesStore
    @Binding var selectedPaths: Set<String>
    var onClose: () -> Void

    @State private var rootFolders: [LazyFolderNode] = []
    @State private var filterText = ""
    @State private var allFolders: [String] = []
    @State private var saveScopeName = ""
    @State private var showSaveScope = false

    private var filteredFolders: [String] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        return allFolders.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Search In Folders").font(.title2).bold()
                Text("Only files inside the checked folders will show up in results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !store.scopes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Saved:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(store.scopes) { scope in
                            Button {
                                selectedPaths = Set(scope.prefixes)
                            } label: {
                                Label(scope.name, systemImage: "star.fill")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(Set(scope.prefixes) == selectedPaths ? 0.3 : 0.12))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(scope.prefixes.joined(separator: "\n"))
                            .contextMenu {
                                Button("Delete Saved Selection") {
                                    if let index = store.scopes.firstIndex(where: { $0.id == scope.id }) {
                                        store.remove(at: IndexSet(integer: index))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter folders", text: $filterText)
                    .textFieldStyle(.plain)
                if !filterText.isEmpty {
                    Button { filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filterText.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(rootFolders) { node in
                            LazyFolderTreeRow(node: node, indexer: indexer, selectedPaths: $selectedPaths, level: 0)
                        }
                    } else {
                        ForEach(filteredFolders, id: \.self) { folder in
                            FolderListRow(folder: folder, state: FolderSelectionState(folder, in: selectedPaths)) {
                                FolderSelectionState.toggle(folder, in: &selectedPaths)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Text(selectedPaths.isEmpty
                     ? "No folders checked: searching everything"
                     : "\(selectedPaths.count) folder\(selectedPaths.count == 1 ? "" : "s") checked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { selectedPaths.removeAll() }
                    .disabled(selectedPaths.isEmpty)
                Button("Save Selection…") { showSaveScope = true }
                    .disabled(selectedPaths.isEmpty)
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            rootFolders = indexer.indexedFolders.map { LazyFolderNode(path: $0, indexer: indexer) }
            DispatchQueue.global(qos: .userInitiated).async {
                let folders = indexer.allFolders()
                DispatchQueue.main.async { allFolders = folders }
            }
        }
        .sheet(isPresented: $showSaveScope) {
            SaveScopeSheet(
                name: $saveScopeName,
                onSave: {
                    let name = saveScopeName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    store.add(name: name, prefixes: Array(selectedPaths).sorted())
                    saveScopeName = ""
                    showSaveScope = false
                },
                onCancel: {
                    saveScopeName = ""
                    showSaveScope = false
                }
            )
        }
    }
}

/// Folder tree node that loads its children on first expand
final class LazyFolderNode: Identifiable, ObservableObject {
    let path: String
    let name: String
    @Published var children: [LazyFolderNode] = []
    @Published var isExpanded = false
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    private let indexer: FileIndexer

    var id: String { path }

    init(path: String, indexer: FileIndexer) {
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.indexer = indexer
    }

    func toggleExpand() {
        isExpanded.toggle()
        guard isExpanded, !hasLoaded, !isLoading else { return }

        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let childNodes = self.indexer.immediateSubfolders(of: self.path).map {
                LazyFolderNode(path: $0, indexer: self.indexer)
            }
            DispatchQueue.main.async {
                self.children = childNodes
                self.isLoading = false
                self.hasLoaded = true
            }
        }
    }
}

struct LazyFolderTreeRow: View {
    @ObservedObject var node: LazyFolderNode
    let indexer: FileIndexer
    @Binding var selectedPaths: Set<String>
    let level: Int

    var body: some View {
        let state = FolderSelectionState(node.path, in: selectedPaths)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    node.toggleExpand()
                } label: {
                    Group {
                        if node.isLoading {
                            ProgressView().controlSize(.mini)
                        } else if node.hasLoaded && node.children.isEmpty {
                            Color.clear
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    FolderSelectionState.toggle(node.path, in: &selectedPaths)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.symbol)
                            .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        Text(node.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state == .inherited ? "Included because a parent folder is checked" : node.path)
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(level * 20) + 4)
            .padding(.trailing, 8)
            .background(state == .selected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            if node.isExpanded {
                ForEach(node.children) { child in
                    LazyFolderTreeRow(node: child, indexer: indexer, selectedPaths: $selectedPaths, level: level + 1)
                }
            }
        }
    }
}

private struct FolderListRow: View {
    let folder: String
    let state: FolderSelectionState
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: state.symbol)
                    .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(folder)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(state == .selected ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(state == .inherited ? "Included because a parent folder is checked" : folder)
    }
}

struct SaveScopeSheet: View {
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Folder Selection")
                .font(.title2)
                .bold()

            TextField("Name (e.g., Legal – Community A)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(onSave)

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }
}

// MARK: - Search Syntax Quick Guide

struct SearchSyntaxQuickGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search Syntax")
                        .font(.title.bold())
                    Text("Words match the start of words in file names, folder names, and extracted text. All words must match.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SyntaxSection(title: "Examples", icon: "sparkles", color: .yellow, rows: [
                        ("contract pdf", "Files with words starting “contract” and “pdf”"),
                        ("\"annual report\"", "The exact phrase"),
                        ("type:pdf size:>10MB modified:today", "Large PDFs changed today"),
                        ("invoice path:Legal modified:thismonth", "Invoices in a Legal folder from this month")
                    ])
                    SyntaxSection(title: "File Type", icon: "doc.fill", color: .blue, rows: [
                        ("type:pdf", "PDF files"),
                        ("ext:docx", "Word documents"),
                        ("type:jpg type:png", "JPEG or PNG images")
                    ])
                    SyntaxSection(title: "File Size", icon: "internaldrive", color: .green, rows: [
                        ("size:>10MB", "Larger than 10 MB"),
                        ("size:<1GB", "Smaller than 1 GB"),
                        ("size:5MB-50MB", "Between 5 and 50 MB")
                    ])
                    SyntaxSection(title: "Modified Date", icon: "calendar", color: .orange, rows: [
                        ("modified:today", "Changed today"),
                        ("modified:yesterday", "Since yesterday"),
                        ("modified:7d", "In the last 7 days"),
                        ("modified:thisweek", "This week"),
                        ("modified:thismonth", "This month"),
                        ("modified:>2024-01-01", "On or after Jan 1, 2024"),
                        ("modified:<2024-12-31", "Before Dec 31, 2024")
                    ])
                    SyntaxSection(title: "Folder", icon: "folder", color: .purple, rows: [
                        ("path:Legal", "Anywhere under a path containing “Legal”"),
                        ("folder:Documents", "Same as path:")
                    ])
                }
                .padding()
            }
        }
        .frame(width: 600, height: 640)
    }
}

private struct SyntaxSection: View {
    let title: String
    let icon: String
    let color: Color
    let rows: [(String, String)]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Divider()
                ForEach(rows, id: \.0) { syntax, description in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(syntax)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(minWidth: 240, alignment: .leading)
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(6)
        }
    }
}
