//
//  QuickSearch.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import SwiftUI
import Carbon.HIToolbox

/// The Spotlight-style search panel and the global shortcut that shows it
final class QuickSearchController: NSObject, ObservableObject, NSWindowDelegate {
    enum Shortcut: String, CaseIterable, Identifiable {
        case off, optionSpace, controlSpace, commandShiftSpace

        var id: Self { self }

        var label: String {
            switch self {
            case .off: return "Off"
            case .optionSpace: return "⌥ Space"
            case .controlSpace: return "⌃ Space"
            case .commandShiftSpace: return "⇧⌘ Space"
            }
        }

        fileprivate var modifiers: UInt32? {
            switch self {
            case .off: return nil
            case .optionSpace: return UInt32(optionKey)
            case .controlSpace: return UInt32(controlKey)
            case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
            }
        }
    }

    private static let shortcutKey = "DexxerQuickSearchShortcut"
    private static let width: CGFloat = 680

    @Published var shortcut: Shortcut {
        didSet {
            UserDefaults.standard.set(shortcut.rawValue, forKey: Self.shortcutKey)
            registerHotKey()
        }
    }
    /// Set when another app already owns the chosen shortcut
    @Published private(set) var shortcutUnavailable = false

    let model: SearchModel
    private let openInMainWindow: (String) -> Void
    private var hotKey: GlobalHotKey?
    private var panel: QuickSearchPanel?

    init(indexer: FileIndexer, openInMainWindow: @escaping (String) -> Void) {
        model = SearchModel(indexer: indexer)
        self.openInMainWindow = openInMainWindow
        shortcut = UserDefaults.standard.string(forKey: Self.shortcutKey).flatMap(Shortcut.init) ?? .optionSpace
        super.init()
        registerHotKey()
    }

    private func registerHotKey() {
        hotKey = nil
        shortcutUnavailable = false
        guard let modifiers = shortcut.modifiers else { return }
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: modifiers) { [weak self] in
            self?.toggle()
        }
        shortcutUnavailable = hotKey == nil
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Upper third of the screen the mouse is on, like Spotlight
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let top = visible.maxY - visible.height * 0.22
            panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - Self.width / 2, y: top))
        }
        panel.makeKeyAndOrderFront(nil)
        model.requestFocus()
        model.search(debounce: false)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickSearchPanel {
        let panel = QuickSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 56),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let view = QuickSearchView(
            model: model,
            onDismiss: { [weak self] in self?.hide() },
            onShowAll: { [weak self] in
                guard let self else { return }
                self.hide()
                self.openInMainWindow(self.model.text)
            },
            onHeightChange: { [weak panel] height in
                // Grow downward from a fixed top edge
                guard let panel else { return }
                var frame = panel.frame
                let contentHeight = panel.contentRect(forFrameRect: frame).height
                frame.origin.y -= height - contentHeight
                frame.size.height += height - contentHeight
                panel.setFrame(frame, display: true)
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// Borderless-looking panel that can take keyboard focus without activating the app
final class QuickSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct QuickSearchView: View {
    @ObservedObject var model: SearchModel
    let onDismiss: () -> Void
    let onShowAll: () -> Void
    let onHeightChange: (CGFloat) -> Void
    @FocusState private var isFocused: Bool

    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 8

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("Search files", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($isFocused)
                    .onSubmit(openSelected)
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            if !model.rows.isEmpty {
                Divider()
                results
                Divider()
                HStack {
                    Text(model.hitLimit ? "Top \(model.rows.count.formatted()) results" : "\(model.rows.count.formatted()) results")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show All in Dexxer", action: onShowAll)
                        .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .frame(height: 30)
            } else if !model.trimmedText.isEmpty && !model.isSearching {
                Divider()
                Text("No results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
        }
        .frame(width: 680)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .onChange(of: model.text) { _, _ in model.search() }
        .onChange(of: model.focusRequest) { _, _ in isFocused = true }
        .onAppear { isFocused = true }
        .onKeyPress(.downArrow) {
            model.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows.prefix(100)) { item in
                        QuickResultRow(item: item, isSelected: item.id == model.selection)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selection = item.id }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                model.selection = item.id
                                openSelected()
                            })
                    }
                }
            }
            .frame(height: CGFloat(min(model.rows.count, Self.visibleRows)) * Self.rowHeight)
            .onChange(of: model.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func openSelected() {
        guard model.selectedItem != nil else { return }
        model.openSelected()
        onDismiss()
    }
}

private struct QuickResultRow: View {
    let item: FileItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: item.fileExtension))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if let snippet = item.highlightedSnippet {
                        Text(snippet)
                    } else {
                        Text(item.parentPath)
                            .truncationMode(.head)
                    }
                }
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(item.modifiedTime.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}

/// A system-wide keyboard shortcut. Uses the Carbon hot key API, which works in the
/// sandbox and doesn't need Accessibility permission.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Fails if the shortcut is already taken
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4458_5852), id: 1)  // "DXXR"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
