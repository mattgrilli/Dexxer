//
//  MainView.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import SwiftUI
import Quartz

struct MainView: View {
    @ObservedObject var indexer: FileIndexer
    @State private var selectedView: NavigationItem = .search
    
    enum NavigationItem: String, CaseIterable {
        case search = "Search"
        case folders = "Folders"
        case settings = "Settings"
    }
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            VStack(spacing: 0) {
                List(selection: $selectedView) {
                    Section {
                        ForEach(NavigationItem.allCases, id: \.self) { item in
                            Label(item.rawValue, systemImage: icon(for: item))
                                .tag(item)
                        }
                    }
                    
                    Section("Quick Actions") {
                        Button(action: quickReindex) {
                            Label("Re-Index All", systemImage: "arrow.clockwise")
                        }
                        .disabled(indexer.isIndexing || indexer.indexedFolders.isEmpty)
                        .help("Re-scan all indexed folders (asks for confirmation)")
                    }
                }
                .listStyle(.sidebar)
                
                Spacer()
                
                // Stats at bottom
                VStack(alignment: .leading, spacing: 4) {
                    let stats = indexer.getStats()
                    Text("\(stats.count.formatted()) files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .id(indexer.indexProgress) // Force refresh when indexProgress changes
                    Text(ByteCountFormatter.string(fromByteCount: stats.totalSize, countStyle: .file))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .id(indexer.indexProgress)
                    if indexer.isIndexing {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Indexing...")
                                .font(.caption2)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            // Main content area
            switch selectedView {
            case .search:
                SearchContentView(indexer: indexer)
            case .folders:
                FolderContentView(indexer: indexer)
            case .settings:
                SettingsContentView(indexer: indexer)
            }
        }
        .frame(minWidth: 1100, minHeight: 750)
    }
    
    func icon(for item: NavigationItem) -> String {
        switch item {
        case .search: return "magnifyingglass"
        case .folders: return "folder"
        case .settings: return "gearshape"
        }
    }
    
    func quickReindex() {
        if indexer.isIndexing {
            let alert = NSAlert()
            alert.messageText = "Already Indexing"
            alert.informativeText = "Please wait for the current indexing task to complete."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        if indexer.indexedFolders.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No Folders"
            alert.informativeText = "Add folders in the Folders tab first."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        let est = indexer.indexedFolders.count
        guard confirm("Re-Index All Folders?",
                      "This will re-index \(est) folder\(est == 1 ? "" : "s"). Proceed?",
                      confirmButton: "Re-Index") else { return }
        
        indexer.indexFolders { _ in /* optional toast/notification */ }
    }
    
    
    // Search content with folder filtering
    struct SearchContentView: View {
        @ObservedObject var indexer: FileIndexer

        @StateObject private var scopesStore = ScopesStore()
        @State private var selectedScopeName: String = "All"
        @State private var showFolderSelector = false

        @State private var searchText = ""
        @State private var selectedFileType = "All"
        @State private var searchResults: [FileItem] = []
        @State private var sortOrder: SortOrder = .dateDescending
        @State private var isSearching = false
        @State private var searchTask: DispatchWorkItem?
        @State private var selectedFolderPaths: Set<String> = []
        @State private var showingPreview = false
        @State private var previewItem: FileItem?
        
        // Simple “scopes” map: name -> array of folder roots
        
        

        
        let fileTypes = ["All", ".pdf", ".doc", ".docx", ".txt", ".xls", ".xlsx",
                         ".ppt", ".pptx", ".jpg", ".jpeg", ".png", ".gif", ".mp4",
                         ".mov", ".zip", ".py", ".js", ".html", ".css", ".json", ".md"]
        
        enum SortOrder {
            case nameAscending, nameDescending
            case sizeAscending, sizeDescending
            case dateAscending, dateDescending
        }
        
        var sortedResults: [FileItem] {
            switch sortOrder {
            case .nameAscending:
                return searchResults.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            case .nameDescending:
                return searchResults.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
            case .sizeAscending:
                return searchResults.sorted { $0.size < $1.size }
            case .sizeDescending:
                return searchResults.sorted { $0.size > $1.size }
            case .dateAscending:
                return searchResults.sorted { $0.modifiedTime < $1.modifiedTime }
            case .dateDescending:
                return searchResults.sorted { $0.modifiedTime > $1.modifiedTime }
            }
        }
        
        var body: some View {
            HSplitView {
                // Main search area
                VStack(spacing: 0) {
                    // Search bar
                    searchBarView
                    
                    Divider()
                    
                    // Results area
                    resultsAreaView
                    
                    Divider()
                    
                    // Status bar
                    statusBarView
                }
                .sheet(isPresented: $showFolderSelector) {
                    FolderSelectionView(
                        indexer: indexer,
                        store: scopesStore,
                        selectedPaths: $selectedFolderPaths,
                        onClose: {
                            showFolderSelector = false
                            performSearch()
                        }
                    )
                }
                
                // Preview pane (optional)
                if showingPreview, let item = previewItem {
                    PreviewPane(item: item, isShowing: $showingPreview)
                        .frame(minWidth: 300, idealWidth: 400)
                }
            }
        }

        struct FolderSelectionView: View {
            @ObservedObject var indexer: FileIndexer
            @ObservedObject var store: ScopesStore
            @Binding var selectedPaths: Set<String>
            var onClose: () -> Void

            @State private var folderHierarchy: [FolderNode] = []
            @State private var saveScopeName: String = ""
            @State private var showSaveScope = false

            var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Filter by Folders").font(.title2).bold()
                            Text("Select specific folders and subfolders to search within")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Done") { onClose() }
                            .keyboardShortcut(.defaultAction)
                    }

                    Divider()

                    // Saved scopes section
                    if !store.scopes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Saved Scopes").font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(store.scopes) { scope in
                                        Button(action: {
                                            selectedPaths = Set(scope.prefixes)
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "folder.badge.questionmark")
                                                    .font(.caption)
                                                Text(scope.name)
                                                    .font(.caption)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.15))
                                            .cornerRadius(8)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("Delete") {
                                                if let idx = store.scopes.firstIndex(where: { $0.id == scope.id }) {
                                                    store.remove(at: IndexSet(integer: idx))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(height: 32)
                        }
                        Divider()
                    }

                    // Quick actions
                    HStack(spacing: 8) {
                        Button(action: {
                            selectedPaths = Set(indexer.indexedFolders)
                        }) {
                            Label("Select All Roots", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            selectedPaths.removeAll()
                        }) {
                            Label("Clear Selection", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        if !selectedPaths.isEmpty {
                            Button(action: {
                                showSaveScope = true
                            }) {
                                Label("Save as Scope", systemImage: "star")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    // Selection count
                    if !selectedPaths.isEmpty {
                        Text("\(selectedPaths.count) folder\(selectedPaths.count == 1 ? "" : "s") selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Folder tree
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(folderHierarchy) { node in
                                FolderTreeRow(
                                    node: node,
                                    selectedPaths: $selectedPaths,
                                    level: 0
                                )
                            }
                        }
                    }
                }
                .padding()
                .frame(minWidth: 700, minHeight: 500)
                .onAppear {
                    loadHierarchy()
                }
                .sheet(isPresented: $showSaveScope) {
                    SaveScopeSheet(
                        name: $saveScopeName,
                        onSave: {
                            guard !saveScopeName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            store.add(name: saveScopeName, prefixes: Array(selectedPaths))
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

            func loadHierarchy() {
                DispatchQueue.global(qos: .userInitiated).async {
                    let hierarchy = indexer.discoverFolderHierarchy()
                    DispatchQueue.main.async {
                        self.folderHierarchy = hierarchy
                    }
                }
            }
        }

        struct SaveScopeSheet: View {
            @Binding var name: String
            let onSave: () -> Void
            let onCancel: () -> Void

            var body: some View {
                VStack(spacing: 16) {
                    Text("Save Folder Selection as Scope")
                        .font(.title2)
                        .bold()

                    TextField("Scope name (e.g., Legal - Community A)", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 400)

                    HStack(spacing: 12) {
                        Button("Cancel") { onCancel() }
                            .keyboardShortcut(.cancelAction)
                        Button("Save") { onSave() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(24)
            }
        }

        struct FolderTreeRow: View {
            @ObservedObject var node: FolderNode
            @Binding var selectedPaths: Set<String>
            let level: Int

            var isSelected: Bool { selectedPaths.contains(node.path) }

            var body: some View {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        // Indent
                        if level > 0 {
                            Color.clear.frame(width: CGFloat(level * 20))
                        }

                        // Expand/collapse button
                        if !node.children.isEmpty {
                            Button(action: { node.isExpanded.toggle() }) {
                                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 16)
                        } else {
                            Color.clear.frame(width: 16)
                        }

                        // Checkbox
                        Button(action: {
                            if isSelected {
                                selectedPaths.remove(node.path)
                            } else {
                                selectedPaths.insert(node.path)
                            }
                        }) {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)

                        // Folder icon and name
                        Image(systemName: "folder.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)

                        Text(node.name)
                            .font(.system(size: 13))
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                    .cornerRadius(4)

                    // Children
                    if node.isExpanded {
                        ForEach(node.children) { child in
                            FolderTreeRow(
                                node: child,
                                selectedPaths: $selectedPaths,
                                level: level + 1
                            )
                        }
                    }
                }
            }
        }


        var searchBarView: some View {
            VStack(spacing: 12) {
                // Row 1: query + file type + folder filter
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title2).foregroundColor(.secondary)
                    TextField("Search for files...", text: $searchText)
                        .textFieldStyle(.plain).font(.title3)
                        .onSubmit { performSearch() }
                        .onChange(of: searchText) { _, _ in performSearch() }

                    Picker("Type", selection: $selectedFileType) {
                        ForEach(fileTypes, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu).frame(width: 120)
                    .onChange(of: selectedFileType) { _, _ in performSearch() }

                    Button {
                        showFolderSelector = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            if selectedFolderPaths.isEmpty {
                                Text("All Folders")
                            } else {
                                Text("\(selectedFolderPaths.count) selected")
                            }
                        }
                        .frame(minWidth: 120)
                    }
                    .help("Filter by specific folders")

                    if !selectedFolderPaths.isEmpty {
                        Button {
                            selectedFolderPaths.removeAll()
                            performSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear folder filter")
                    }

                    Spacer()
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }

        
        var resultsAreaView: some View {
            Group {
                if isSearching {
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Searching...")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else if searchResults.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: searchText.isEmpty ? "doc.text.magnifyingglass" : "questionmark.folder")
                            .font(.system(size: 64))
                            .foregroundColor(.gray)
                        Text(searchText.isEmpty ? "Enter a search term to find files" : "No results found")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        if searchText.isEmpty && indexer.indexedFolders.isEmpty {
                            Text("Add folders in the Folders tab to get started")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    // Results with tight headers
                    VStack(spacing: 0) {
                        // Compact header row
                        HStack(spacing: 0) {
                            sortHeader(title: "Name", ascending: .nameAscending, descending: .nameDescending, maxWidth: true)
                            sortHeader(title: "Size", ascending: .sizeAscending, descending: .sizeDescending, width: 100)
                            sortHeader(title: "Modified", ascending: .dateAscending, descending: .dateDescending, width: 180)
                            Color.clear.frame(width: 100)
                        }
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .frame(height: 24)
                        .background(Color(nsColor: .windowBackgroundColor))
                        
                        Divider()
                        
                        // Results
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(sortedResults) { item in
                                    FileRowView(
                                        item: item,
                                        onPreview: {
                                            previewItem = item
                                            showingPreview = true
                                        }
                                    )
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        
        func sortHeader(title: String, ascending: SortOrder, descending: SortOrder, maxWidth: Bool = false, width: CGFloat? = nil) -> some View {
            Button(action: { toggleSort(ascending, descending) }) {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: sortIcon(for: ascending, descending))
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .modifier(FrameModifier(maxWidth: maxWidth, width: width))
        }
        
        struct FrameModifier: ViewModifier {
            let maxWidth: Bool
            let width: CGFloat?
            
            func body(content: Content) -> some View {
                if maxWidth {
                    content.frame(maxWidth: .infinity, alignment: .leading)
                } else if let w = width {
                    content.frame(width: w, alignment: .trailing)
                } else {
                    content.frame(alignment: .trailing)
                }
            }
        }
        
        var statusBarView: some View {
            HStack {
                let stats = indexer.getStats()
                Text("📊 \(stats.count.formatted()) files indexed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .id(indexer.indexProgress) // Force refresh when index changes
                
                Spacer()
                
                if !searchResults.isEmpty {
                    Text("\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: { showingPreview.toggle() }) {
                        Label(showingPreview ? "Hide Preview" : "Show Preview",
                              systemImage: showingPreview ? "sidebar.right" : "sidebar.left")
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        
        private func performSearch() {
            // cancel any pending delayed search
            searchTask?.cancel()

            // empty query -> clear results
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                searchResults = []
                return
            }

            let task = DispatchWorkItem {
                DispatchQueue.main.async { self.isSearching = true }

                var f = FileIndexer.SearchFilters()
                f.query = self.searchText

                // file type (ignore "All")
                if self.selectedFileType != "All" {
                    f.fileType = self.selectedFileType
                }

                // Use selected folder paths for filtering
                if !self.selectedFolderPaths.isEmpty {
                    f.folders = Array(self.selectedFolderPaths)
                } else {
                    f.folders = nil  // search across all indexed folders
                }

                f.limit = 1000

                let results = self.indexer.searchAdvanced(f)

                DispatchQueue.main.async {
                    self.searchResults = results
                    self.isSearching = false
                }
            }

            self.searchTask = task
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + 0.2, execute: task)   // light debounce
        }



        
        private func toggleSort(_ ascending: SortOrder, _ descending: SortOrder) {
            if sortOrder == ascending {
                sortOrder = descending
            } else {
                sortOrder = ascending
            }
        }
        
        private func sortIcon(for ascending: SortOrder, _ descending: SortOrder) -> String {
            if sortOrder == ascending {
                return "chevron.up"
            } else if sortOrder == descending {
                return "chevron.down"
            }
            return "chevron.up.chevron.down"
        }
    }
    
    // Folder filter popover
    struct FolderFilterView: View {
        let allFolders: [String]
        @Binding var selectedFolders: Set<String>
        let onApply: () -> Void
        @Environment(\.dismiss) var dismiss
        
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filter by Folders")
                    .font(.headline)
                
                Divider()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(allFolders, id: \.self) { folder in
                            Toggle(isOn: Binding(
                                get: { selectedFolders.contains(folder) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedFolders.insert(folder)
                                    } else {
                                        selectedFolders.remove(folder)
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: folder).lastPathComponent)
                                        .font(.caption)
                                    Text(folder)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 300)
                
                Divider()
                
                HStack {
                    Button("Clear All") {
                        selectedFolders.removeAll()
                        onApply()
                    }
                    
                    Button("Select All") {
                        selectedFolders = Set(allFolders)
                        onApply()
                    }
                    
                    Spacer()
                    
                    Button("Apply") {
                        onApply()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 400)
        }
    }
    
    // Preview pane
    struct PreviewPane: View {
        let item: FileItem
        @Binding var isShowing: Bool
        
        var body: some View {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Preview")
                        .font(.headline)
                    Spacer()
                    Button(action: { isShowing = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
                
                // Quick Look preview
                QuickLookPreview(url: item.fileURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider()
                
                // File info
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name)
                        .font(.caption)
                        .bold()
                        .lineLimit(2)
                    Text(item.path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack {
                        Text(item.formattedSize)
                        Text("•")
                        Text(item.modifiedDateString)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
    
    // Quick Look wrapper
    struct QuickLookPreview: NSViewRepresentable {
        let url: URL
        
        func makeNSView(context: Context) -> QLPreviewView {
            let preview = QLPreviewView()
            preview.autostarts = true
            return preview
        }
        
        func updateNSView(_ nsView: QLPreviewView, context: Context) {
            nsView.previewItem = url as QLPreviewItem
        }
    }
    
    // File row with preview button
    struct FileRowView: View {
        let item: FileItem
        let onPreview: () -> Void
        @State private var isHovered = false
        
        var body: some View {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Text(item.path)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Text(item.formattedSize)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .trailing)
                
                Text(item.modifiedDateString)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 180, alignment: .trailing)
                
                // Action buttons
                HStack(spacing: 8) {
                    Button(action: onPreview) {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.plain)
                    .help("Preview")
                    
                    Button(action: { openFile() }) {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.plain)
                    .help("Open file")
                    
                    Button(action: { revealInFinder() }) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
                .opacity(isHovered ? 1 : 0)
                .frame(width: 100)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(isHovered ? Color(nsColor: .controlAccentColor).opacity(0.1) : Color.clear)
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture(count: 2) {
                openFile()
            }
            .onTapGesture {
                onPreview()
            }
            .contextMenu {
                Button("Open") { openFile() }
                Button("Preview") { onPreview() }
                Button("Show in Finder") { revealInFinder() }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
            }
        }
        
        private func openFile() {
            // Use NSWorkspace with proper URL
            NSWorkspace.shared.open(item.fileURL)
        }
        
        private func revealInFinder() {
            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
        }
    }
    
    // Settings view
    struct SettingsContentView: View {
        @ObservedObject var indexer: FileIndexer
        @State private var dbSize: String = "Calculating..."

        var body: some View {
            Form {
                Section("Database") {
                    LabeledContent("Location") {
                        Text("~/.dexxer.db")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    LabeledContent("Size") {
                        Text(dbSize)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button("Open Database Location") {
                        let homeDir = FileManager.default.homeDirectoryForCurrentUser
                        NSWorkspace.shared.selectFile(homeDir.appendingPathComponent(".dexxer.db").path,
                                                      inFileViewerRootedAtPath: homeDir.path)
                    }
                }

                Section("Indexing") {
                    let stats = indexer.getStats()
                    LabeledContent("Total Files") {
                        Text("\(stats.count.formatted())")
                    }
                    LabeledContent("Total Size") {
                        Text(ByteCountFormatter.string(fromByteCount: stats.totalSize, countStyle: .file))
                    }
                    LabeledContent("Folders Indexed") {
                        Text("\(indexer.indexedFolders.count)")
                    }

                    Button("Clear All Index Data") {
                        clearAllData()
                    }
                    .foregroundColor(.red)
                }

                Section("About") {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
                    LabeledContent("Version", value: "\(version) (\(build))")

                    LabeledContent("Created by", value: "Matt Grilli")

                    Button("View on GitHub") {
                        if let url = URL(string: "https://github.com/mattgrilli/Dexxer") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                calculateDBSize()
            }
        }

        private func calculateDBSize() {
            DispatchQueue.global().async {
                let homeDir = FileManager.default.homeDirectoryForCurrentUser
                let dbPath = homeDir.appendingPathComponent(".dexxer.db").path
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
                   let size = attrs[.size] as? Int64 {
                    let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                    DispatchQueue.main.async {
                        dbSize = formatted
                    }
                }
            }
        }
        
        private func clearAllData() {
            let alert = NSAlert()
            alert.messageText = "Clear All Index Data?"
            alert.informativeText = "This will delete all indexed file data. Your actual files will not be affected. You'll need to re-index your folders."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Clear Data")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                // Use the indexer's method to clear data
                indexer.clearDatabase()
                
                // Show confirmation
                let doneAlert = NSAlert()
                doneAlert.messageText = "Index Cleared"
                doneAlert.informativeText = "All index data has been cleared. Your folders are still configured and you can re-index them anytime."
                doneAlert.alertStyle = .informational
                doneAlert.runModal()
            }
        }
    }
    
    // Folder content (keep existing)
    struct FolderContentView: View {
        @ObservedObject var indexer: FileIndexer
        @State private var draggedOver = false
        @State private var showingIndexProgress = false
        @State private var indexingMessage = ""
        
        var body: some View {
            ZStack {
                VStack(spacing: 0) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Indexed Folders")
                            .font(.title)
                            .bold()
                        Text("Add folders to index and search through their files")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    
                    Divider()
                    
                    // Main content
                    if indexer.indexedFolders.isEmpty {
                        emptyStateView
                    } else {
                        folderListView
                    }
                    
                    Divider()
                    
                    // Bottom bar
                    bottomBarView
                }
                
                // Indexing overlay
                if indexer.isIndexing || showingIndexProgress {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(2)
                            .progressViewStyle(.circular)
                        
                        VStack(spacing: 8) {
                            Text("Indexing Files...")
                                .font(.title2)
                                .bold()
                            
                            Text("\(indexer.indexProgress) files indexed")
                                .font(.title3)
                                .foregroundColor(.secondary)
                            
                            if !indexingMessage.isEmpty {
                                Text(indexingMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(40)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                }
            }
        }
        
        var emptyStateView: some View {
            VStack(spacing: 24) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 72))
                    .foregroundColor(.blue)
                
                VStack(spacing: 8) {
                    Text("No Folders Added Yet")
                        .font(.title2)
                        .bold()
                    Text("Add folders to start indexing and searching files")
                        .foregroundColor(.secondary)
                }
                
                VStack(spacing: 16) {
                    Button(action: selectFolder) {
                        Label("Choose Folder", systemImage: "folder.badge.plus")
                            .font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    Text("or drag and drop folders here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(draggedOver ? Color.blue.opacity(0.1) : Color.clear)
            .onDrop(of: [.fileURL], isTargeted: $draggedOver) { providers in
                handleDrop(providers: providers)
            }
        }
        
        var folderListView: some View {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(indexer.indexedFolders, id: \.self) { folder in
                            FolderRowView(
                                folder: folder,
                                indexer: indexer
                            )
                            Divider()
                        }
                    }
                }
                
                // Drop zone at bottom
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                    Text("Drag folders here to add them")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(draggedOver ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                .onDrop(of: [.fileURL], isTargeted: $draggedOver) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        
        var bottomBarView: some View {
            HStack {
                Button(action: selectFolder) {
                    Label("Add Folder", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .help("Choose a folder to add to the search index")
                
                if !indexer.indexedFolders.isEmpty {
                    Button(action: reindexAll) {
                        Label("Re-Index All", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(indexer.isIndexing)
                    .help("Re-scan all indexed folders (asks for confirmation)")
                }
                
                Spacer()
                
                if indexer.isIndexing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Indexing... \(indexer.indexProgress) files")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        
        private func selectFolder() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select Folder"
            panel.message = "Choose a folder to index"
            
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    addFolder(url: url)
                }
            }
        }
        
        private func addFolder(url: URL) {
            let path = url.path
            if indexer.indexedFolders.contains(path) {
                let alert = NSAlert()
                alert.messageText = "Folder Already Added"
                alert.informativeText = "This folder is already in your index."
                alert.alertStyle = .informational
                alert.runModal()
                return
            }
            
            indexer.addFolder(path)
            BookmarkStore.save(path: path, url: url)
            
            
            showingIndexProgress = true
            indexingMessage = "Scanning \"\(url.lastPathComponent)\"..."
            
            indexer.indexFolders([path]) { count in
                DispatchQueue.main.async {
                    self.showingIndexProgress = false
                    
                    let alert = NSAlert()
                    if count > 0 {
                        alert.messageText = "Indexing Complete! ✅"
                        alert.informativeText = "Successfully indexed \(count) files from \"\(url.lastPathComponent)\""
                        alert.alertStyle = .informational
                    } else {
                        alert.messageText = "No Files Found ⚠️"
                        alert.informativeText = """
                    No files were found in "\(url.lastPathComponent)".
                    
                    This might be due to:
                    • Permission issues (especially for external drives)
                    • Empty folder
                    • Only hidden files present
                    
                    Try granting Full Disk Access in System Settings > Privacy & Security.
                    """
                        alert.alertStyle = .warning
                    }
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
        
        private func handleDrop(providers: [NSItemProvider]) -> Bool {
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    guard let url = url else { return }
                    
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        DispatchQueue.main.async {
                            self.addFolder(url: url)
                        }
                    }
                }
            }
            return true
        }
        
        private func reindexAll() {
            // Busy guard to prevent accidental double-runs
            if indexer.isIndexing {
                infoAlert("Already Indexing", "Please wait for the current indexing task to finish.")
                return
            }
            
            // Nothing to do
            let total = indexer.indexedFolders.count
            if total == 0 {
                infoAlert("No Folders", "Add folders first in the Folders tab before re-indexing.")
                return
            }
            
            // Confirm
            let ok = confirm(
                "Re-Index All \(total) Folder\(total == 1 ? "" : "s")?",
            """
            This will fully rescan and update all indexed folders.

            ⚠️ This operation will:
            • Re-scan \(total) folder\(total == 1 ? "" : "s") and all their contents
            • Replace all existing index entries
            • Take several minutes depending on folder sizes
            • Use significant system resources during indexing

            Your actual files will not be modified.

            Proceed with re-indexing all folders?
            """,
                confirmButton: "Re-Index All",
                cancelButton: "Cancel",
                style: .warning
            )
            if !ok { return }
            
            // Kick off indexing
            indexer.indexFolders { count in
                DispatchQueue.main.async {
                    let done = NSAlert()
                    done.messageText = "Re-Indexing Complete"
                    done.informativeText = "Indexed \(count) total files"
                    done.alertStyle = .informational
                    done.addButton(withTitle: "OK")
                    done.runModal()
                }
            }
        }
        
        
        struct FolderRowView: View {
            let folder: String
            @ObservedObject var indexer: FileIndexer
            @State private var isHovered = false
            @State private var fileCount: Int = 0
            @State private var reachable: Bool = false
            @State private var isNetwork: Bool = false

            var folderName: String { URL(fileURLWithPath: folder).lastPathComponent }

            var body: some View {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundColor(isNetwork ? .blue : .accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(folderName)
                                .font(.system(size: 15, weight: .medium))
                                .lineLimit(1)

                            // Status chip
                            if isNetwork {
                                Text(reachable ? "Network • Connected" : "Network • Disconnected")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(reachable ? Color.green.opacity(0.18) : Color.red.opacity(0.18))
                                    .foregroundColor(reachable ? .green : .red)
                                    .cornerRadius(6)
                            } else {
                                Text("Local")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .foregroundColor(.secondary)
                                    .cornerRadius(6)
                            }
                        }

                        Text(folder)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if fileCount > 0 {
                            Text("\(fileCount) files indexed")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    // Actions
                    HStack(spacing: 12) {
                        Button(action: reindexFolder) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(indexer.isIndexing || (isNetwork && !reachable) ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                        .help("Re-Index: Re-scan and update files in this folder (asks for confirmation)")
                        .disabled(indexer.isIndexing || (isNetwork && !reachable))

                        Button(action: revealInFinder) {
                            Image(systemName: "folder.badge.gearshape")
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder: Open this folder in Finder")

                        // Connect only shows for network + disconnected
                        if isNetwork && !reachable {
                            Button(action: connectToServer) {
                                Image(systemName: "bolt.horizontal.icloud")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Connect: Connect to this network share (SMB/AFP/NFS)")
                        }

                        Button(action: removeFolder) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Remove: Remove this folder from index (does not delete files, asks for confirmation)")
                    }
                    .opacity(isHovered ? 1 : 0.5)
                    .font(.system(size: 15))
                }
                .padding()
                .background(isHovered ? Color(nsColor: .controlAccentColor).opacity(0.05) : Color.clear)
                .onHover { isHovered = $0 }
                .onAppear { refreshStatus() }
                .onChange(of: indexer.indexProgress) { _, _ in
                    if !indexer.isIndexing { updateFileCount() }
                }
            }

            private func refreshStatus() {
                isNetwork = indexer.isNetworkFolder(folder)
                reachable = indexer.isReachableFolder(folder)
                print("📁 Folder: \(folder)")
                print("   isNetwork: \(isNetwork), reachable: \(reachable)")
                updateFileCount()
            }

            private func updateFileCount() {
                guard reachable else { fileCount = 0; return }
                DispatchQueue.global(qos: .background).async {
                    let results = indexer.search(query: "", folders: [folder], limit: 20000)
                    DispatchQueue.main.async { self.fileCount = results.count }
                }
            }

            private func reindexFolder() {
                if indexer.isIndexing {
                    infoAlert("Already Indexing", "Please wait for the current indexing task to complete before re-indexing a folder.")
                    return
                }
                if isNetwork && !reachable {
                    infoAlert("Share Disconnected", "This network folder is not reachable. Click Connect… to mount it, then try again.")
                    return
                }
                let ok = confirm(
                    "Re-Index \"\(folderName)\"?",
                    """
                    This will fully rescan and update all files in:
                    \(folder)

                    ⚠️ This operation will:
                    • Replace existing index entries for this folder
                    • Scan all files (may take several minutes for large folders)
                    • Use system resources during indexing

                    Your actual files will not be modified.

                    Proceed with re-indexing?
                    """,
                    confirmButton: "Re-Index",
                    cancelButton: "Cancel",
                    style: .warning
                )
                if !ok { return }
                indexer.indexFolders([folder]) { _ in updateFileCount() }
            }

            private func revealInFinder() {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
            }

            private func connectToServer() {
                // Prompt for SMB/NFS URL and open it (e.g., smb://server/Share)
                if let text = promptForText(title: "Connect to Server",
                                            message: "Enter a server URL (e.g., smb://fileserver/TeamShare)",
                                            placeholder: "smb://server/Share"),
                   let url = URL(string: text), ["smb", "afp", "nfs"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                    // Give the system a moment to mount, then refresh
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { refreshStatus() }
                } else {
                    infoAlert("Invalid URL", "Use a valid server URL like smb://fileserver/TeamShare")
                }
            }

            private func removeFolder() {
                let alert = NSAlert()
                alert.messageText = "Remove \"\(folderName)\" from Index?"
                alert.informativeText = """
                This will remove this folder from your search index:
                \(folder)

                ⚠️ This action will:
                • Remove all indexed file entries for this folder
                • Stop searching within this folder
                • NOT delete any actual files (they remain on disk)

                You can always add it back later.

                Remove from index?
                """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Remove from Index")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    indexer.removeFolder(folder)
                }
            }
        }

        
        #Preview {
            MainView(indexer: FileIndexer())
        }
    }
}
