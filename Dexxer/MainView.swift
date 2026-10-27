//
//  MainView.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import SwiftUI

struct MainView: View {
    @ObservedObject var indexer: FileIndexer
    @ObservedObject var search: SearchModel
    @ObservedObject var quickSearch: QuickSearchController
    @StateObject private var scopesStore = ScopesStore()
    @State private var selectedView: NavigationItem = .search
    @State private var isDropTargeted = false
    @State private var columnVisibility = NavigationSplitViewVisibility.demoAware

    enum NavigationItem: String, CaseIterable {
        case search = "Search"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .search: return "magnifyingglass"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                List(selection: $selectedView) {
                    Section {
                        ForEach(NavigationItem.allCases, id: \.self) { item in
                            Label(item.rawValue, systemImage: item.icon)
                                .tag(item)
                        }
                    }

                    Section("Indexed Folders") {
                        ForEach(indexer.indexedFolders, id: \.self) { folder in
                            SidebarFolderRow(folder: folder, indexer: indexer)
                        }
                        Button {
                            FolderActions.chooseAndAdd(to: indexer)
                        } label: {
                            Label("Add Folder…", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.sidebar)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    FolderActions.handleDrop(providers, indexer: indexer)
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .padding(4)
                    }
                }

                Divider()
                SidebarStatusView(indexer: indexer)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            switch selectedView {
            case .search:
                SearchContentView(indexer: indexer, model: search, scopesStore: scopesStore)
            case .settings:
                SettingsContentView(indexer: indexer, quickSearch: quickSearch)
            }
        }
        // The sidebar toggle is the only toolbar item. Removing it removes the toolbar, whose
        // taller glass on macOS 27 otherwise covers the search bar. The sidebar still drags open and closed.
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 900, minHeight: 560)
        .onChange(of: search.focusRequest) { _, _ in
            selectedView = .search
        }
    }
}

// MARK: - Sidebar

struct SidebarFolderRow: View {
    let folder: String
    @ObservedObject var indexer: FileIndexer

    private var name: String { FolderActions.displayName(folder) }

    private func lastIndexedSummary(count: Int) -> String {
        let files = "\(count.formatted()) files"
        guard let date = indexer.lastIndexed[folder] else { return "\(files) · not fully indexed" }
        if Date().timeIntervalSince(date) < 60 { return "\(files) · just now" }
        return "\(files) · \(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
    }

    private var tooltip: String {
        guard let date = indexer.lastIndexed[folder] else { return folder }
        return "\(folder)\nLast fully indexed \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        let reachable = indexer.isReachable(folder)
        let isNetwork = indexer.isNetworkFolder(folder)
        let count = indexer.folderFileCounts[folder] ?? 0

        HStack(spacing: 6) {
            Image(systemName: isNetwork ? "server.rack" : "folder.fill")
                .foregroundStyle(reachable ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(reachable ? .primary : .secondary)
                if reachable {
                    Text(lastIndexedSummary(count: count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Offline")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 4)

            if indexer.currentlyIndexing == folder {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .help(tooltip)
        .contextMenu {
            Button("Re-Index") { FolderActions.reindex(folder, indexer: indexer) }
                .disabled(indexer.currentlyIndexing == folder)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
            }
            .disabled(!reachable)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folder, forType: .string)
            }

            Divider()

            if isNetwork && !reachable {
                Button("Connect to Server…") { FolderActions.connectToServer() }
            }
            Button("Grant Access…") { FolderActions.grantAccess(folder, indexer: indexer) }

            Divider()

            Button("Remove from Dexxer…") { FolderActions.confirmRemove(folder, indexer: indexer) }
        }
    }
}

struct SidebarStatusView: View {
    @ObservedObject var indexer: FileIndexer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if indexer.isIndexing {
                HStack {
                    Text(statusTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Stop") { indexer.cancelIndexing() }
                        .controlSize(.small)
                        .disabled(indexer.isCancellingIndex)
                }
                ProgressView()
                    .progressViewStyle(.linear)
                Text("\(indexer.indexProgress.formatted()) files checked")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let fileName = indexer.currentFileName {
                    Text("Reading \(fileName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(indexer.stats.count.formatted()) files indexed")
                            .font(.caption)
                        Text(ByteCountFormatter.string(fromByteCount: indexer.stats.totalSize, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        indexer.indexFolders()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Re-index all folders. Only new and changed files are processed.")
                    .disabled(indexer.indexedFolders.isEmpty)
                }

                if !indexer.lastSkippedFolders.isEmpty {
                    Label("Skipped \(indexer.lastSkippedFolders.count) offline folder\(indexer.lastSkippedFolders.count == 1 ? "" : "s")",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(indexer.lastSkippedFolders.joined(separator: "\n"))
                }
            }

            if indexer.textRecognitionStalled {
                Label("Text recognition stopped responding, so scanned pages were skipped", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("macOS's text recognition didn't respond. Scanned files will be retried the next time folders are indexed; restarting the Mac usually clears this.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusTitle: String {
        if indexer.isCancellingIndex { return "Stopping…" }
        guard let folder = indexer.currentlyIndexing else { return "Indexing…" }
        return "Indexing \(FolderActions.displayName(folder))…"
    }
}

// MARK: - Folder actions

/// Folder management shared by the sidebar, Settings, and empty states
enum FolderActions {
    static func displayName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func chooseAndAdd(to indexer: FileIndexer) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to index"
        guard panel.runModal() == .OK else { return }
        add(panel.urls, to: indexer)
    }

    /// Adds folders and starts indexing the new ones right away
    static func add(_ urls: [URL], to indexer: FileIndexer) {
        var added: [String] = []
        var notes: [String] = []

        for url in urls {
            switch indexer.addFolder(url) {
            case .added(let path):
                added.append(path)
            case .alreadyIndexed:
                notes.append("“\(url.lastPathComponent)” is already indexed.")
            case .coveredBy(let root):
                notes.append("“\(url.lastPathComponent)” is already included in “\(displayName(root))”.")
            }
        }

        if !added.isEmpty { indexer.indexFolders(added) }
        if !notes.isEmpty {
            infoAlert(added.isEmpty ? "Nothing to Add" : "Some Folders Weren't Added", notes.joined(separator: "\n"))
        }
    }

    static func handleDrop(_ providers: [NSItemProvider], indexer: FileIndexer) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var folders: [URL] = []

        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
                lock.lock()
                folders.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            if !folders.isEmpty { add(folders, to: indexer) }
        }
        return true
    }

    static func reindex(_ folder: String, indexer: FileIndexer) {
        guard indexer.isReachable(folder) else {
            showUnavailable(folder, indexer: indexer)
            return
        }
        indexer.indexFolders([folder])
    }

    static func showUnavailable(_ folder: String, indexer: FileIndexer) {
        let isNetwork = indexer.isNetworkFolder(folder)
        let alert = NSAlert()
        alert.messageText = "“\(displayName(folder))” Isn't Available"
        alert.informativeText = isNetwork
            ? "Connect to the server that hosts this share, then try again.\n\n\(folder)"
            : "Dexxer can't read this folder. It may have moved, or Dexxer may need permission again.\n\n\(folder)"
        if isNetwork { alert.addButton(withTitle: "Connect to Server…") }
        alert.addButton(withTitle: "Grant Access…")
        alert.addButton(withTitle: "Cancel")

        switch (alert.runModal(), isNetwork) {
        case (.alertFirstButtonReturn, true): connectToServer()
        case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true): grantAccess(folder, indexer: indexer)
        default: break
        }
    }

    /// Opens Finder's Connect to Server dialog; the sidebar updates when the share mounts
    static func connectToServer() {
        if let url = URL(string: "smb://") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Re-select a folder so the sandbox grants fresh access to it
    static func grantAccess(_ folder: String, indexer: FileIndexer) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        panel.prompt = "Grant Access"
        panel.message = "Select “\(displayName(folder))” so Dexxer can read it"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard url.standardizedFileURL.path == folder else {
            infoAlert("Different Folder Selected", "Please select “\(displayName(folder))” at:\n\(folder)")
            return
        }
        indexer.grantAccess(to: folder, using: url)
    }

    static func confirmRemove(_ folder: String, indexer: FileIndexer) {
        let count = indexer.folderFileCounts[folder] ?? 0
        guard confirm("Remove “\(displayName(folder))” from Dexxer?",
                      "Its \(count.formatted()) indexed files will no longer show up in search. Nothing on disk is changed.",
                      confirmButton: "Remove") else { return }
        indexer.removeFolder(folder)
    }
}

/// True while generating the README screenshot (debug builds only)
var isDemoScreenshot: Bool {
    #if DEBUG
    return DemoMode.isEnabled
    #else
    return false
    #endif
}

extension NavigationSplitViewVisibility {
    /// Demo screenshots can't capture the floating glass sidebar, so they hide it
    static var demoAware: NavigationSplitViewVisibility {
        isDemoScreenshot ? .detailOnly : .automatic
    }
}
