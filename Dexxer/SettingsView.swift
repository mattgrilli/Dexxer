//
//  SettingsView.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import SwiftUI

struct SettingsContentView: View {
    @ObservedObject var indexer: FileIndexer
    @State private var dbSize = "—"
    @State private var isRebuilding = false
    @State private var isDropTargeted = false

    var body: some View {
        Form {
            Section {
                if indexer.indexedFolders.isEmpty {
                    Text("No folders yet. Add one, or drag folders here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(indexer.indexedFolders, id: \.self) { folder in
                    SettingsFolderRow(folder: folder, indexer: indexer)
                }
                HStack {
                    Button("Add Folder…") { FolderActions.chooseAndAdd(to: indexer) }
                    Spacer()
                    if indexer.isIndexing {
                        Button("Stop Indexing") { indexer.cancelIndexing() }
                            .disabled(indexer.isCancellingIndex)
                    } else {
                        Button("Re-Index All") { indexer.indexFolders() }
                            .disabled(indexer.indexedFolders.isEmpty)
                    }
                }
            } header: {
                Text("Indexed Folders")
            } footer: {
                Text("Re-indexing only processes new and changed files, so it's safe to run any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Indexing") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Extract text from PDFs and images", isOn: $indexer.ocrEnabled)
                    Text("Reads the text in PDFs and recognizes text in images and scanned pages, so you can search by what's inside a file. Indexing is slower with this on. Takes effect the next time folders are indexed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Skip common junk files and folders", isOn: $indexer.excludePatternsEnabled)
                    Text("Skips \((indexer.excludedFolders + indexer.excludedFiles).joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Database") {
                LabeledContent("Indexed files", value: indexer.stats.count.formatted())
                LabeledContent("Size of indexed files",
                               value: ByteCountFormatter.string(fromByteCount: indexer.stats.totalSize, countStyle: .file))
                LabeledContent("Database size", value: dbSize)
                HStack {
                    Button("Show Database in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: indexer.dbPath)])
                    }
                    Button(isRebuilding ? "Rebuilding…" : "Rebuild Search Index") {
                        isRebuilding = true
                        indexer.rebuildSearchIndex {
                            isRebuilding = false
                            calculateDBSize()
                        }
                    }
                    .disabled(isRebuilding || indexer.isIndexing)
                    .help("Rebuilds the full-text index from the indexed files. Only needed if search results look wrong.")
                    Spacer()
                    Button("Clear Index…", role: .destructive) { clearAllData() }
                        .disabled(indexer.isIndexing)
                }
            }

            Section("About") {
                AboutView()
            }
        }
        .formStyle(.grouped)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FolderActions.handleDrop(providers, indexer: indexer)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(6)
            }
        }
        .onAppear { calculateDBSize() }
        .onChange(of: indexer.stats) { _, _ in calculateDBSize() }
    }

    private func calculateDBSize() {
        let path = indexer.dbPath
        DispatchQueue.global(qos: .utility).async {
            // Include the write-ahead log, which holds recent changes
            let total = [path, path + "-wal"].reduce(Int64(0)) { sum, file in
                let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int64 ?? 0
                return sum + size
            }
            let formatted = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            DispatchQueue.main.async { dbSize = formatted }
        }
    }

    private func clearAllData() {
        guard confirm("Clear the Entire Index?",
                      "All indexed file data, including text extracted from PDFs and images, will be deleted. Your folders stay in the list and your files aren't touched, but you'll need to re-index to search again.",
                      confirmButton: "Clear Index") else { return }
        indexer.clearDatabase()
    }
}

private struct SettingsFolderRow: View {
    let folder: String
    @ObservedObject var indexer: FileIndexer

    var body: some View {
        let reachable = indexer.isReachable(folder)

        HStack(spacing: 10) {
            Image(systemName: indexer.isNetworkFolder(folder) ? "server.rack" : "folder.fill")
                .foregroundStyle(reachable ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(FolderActions.displayName(folder))
                    if !reachable {
                        Text("Offline")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if indexer.currentlyIndexing == folder {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("\((indexer.folderFileCounts[folder] ?? 0).formatted()) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                FolderActions.reindex(folder, indexer: indexer)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(reachable ? "Re-index this folder" : "Folder is offline")
            .disabled(indexer.currentlyIndexing == folder)

            Button {
                FolderActions.confirmRemove(folder, indexer: indexer)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from Dexxer (files on disk aren't touched)")
        }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dexxer")
                        .font(.title2)
                        .bold()
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                    Text("Version \(version) (\(build))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
            }

            Divider()

            Text("Fast local file search for macOS")
                .font(.headline)

            Text("Made this because I can't find shit in macOS. Finder's search is slow and useless. This actually works.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Features:")
                    .font(.caption)
                    .bold()
                FeatureRow(icon: "bolt.fill", text: "Full-text search ranked by best match", color: .orange)
                FeatureRow(icon: "text.magnifyingglass", text: "Search syntax: type:, size:, modified:, path:", color: .blue)
                FeatureRow(icon: "doc.text.viewfinder", text: "Text from PDFs, images, and scanned pages", color: .purple)
                FeatureRow(icon: "network", text: "Network share support", color: .green)
                FeatureRow(icon: "arrow.clockwise", text: "Fast re-indexing of only what changed", color: .indigo)
            }

            Divider()

            Text("Created by Matt Grilli © 2025")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Built with Swift, SQLite, and determination")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .italic()

            Text("💪 No cloud. No tracking. Just local, fast search.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
