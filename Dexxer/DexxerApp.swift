//
//  DexxerApp.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import SwiftUI
import UserNotifications
import AppKit

@main
struct DexxerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar only app - no main window
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    let indexer: FileIndexer = {
        #if DEBUG
        if DemoMode.isEnabled { return FileIndexer(directory: DemoMode.resetDataDirectory()) }
        #endif
        return FileIndexer()
    }()
    lazy var searchModel = SearchModel(indexer: indexer)
    lazy var quickSearch = QuickSearchController(indexer: indexer) { [weak self] query in
        self?.openMainWindow()
        self?.searchModel.search(for: query)
    }
    private var mainWindow: NSWindow?
    private var autoIndexTimer: Timer?

    /// Folders not fully indexed within this long get re-indexed automatically
    private static let staleAge: TimeInterval = 12 * 60 * 60

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar style app (no Dock icon). If you want Dock icon, switch to .regular.
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // dexxer:// links (registered in Dexxer-Info.plist)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: "Dexxer")
            button.action = #selector(showMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        // Keep folder status current as shares come and go
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)

        #if DEBUG
        if DemoMode.isEnabled {
            DemoMode.run(self)
            return
        }
        #endif

        // Registers the global shortcut
        _ = quickSearch

        // Keep the index current: shortly after launch, then hourly
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.indexer.indexStaleFolders(olderThan: Self.staleAge)
        }
        autoIndexTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.indexer.indexStaleFolders(olderThan: Self.staleAge)
        }
    }

    // MARK: - URL Scheme Handling

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        handleDexxerURL(url)
    }

    /// dexxer://search?q=contract opens the window and runs the search; anything else just opens the window.
    /// Links can't add or index folders, since any web page can open them.
    func handleDexxerURL(_ url: URL) {
        guard url.scheme == "dexxer" else { return }
        openMainWindow()

        if url.host == "search",
           let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
            searchModel.search(for: query)
        }
    }

    // MARK: - Volume notifications

    @objc private func volumesChanged(_ note: Notification) {
        indexer.refreshReachability()
        // A share just came back: catch up on anything that changed while it was away
        if note.name == NSWorkspace.didMountNotification {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.indexer.indexStaleFolders(olderThan: Self.staleAge)
            }
        }
    }

    // MARK: - Menu

    @objc func showMenu() {
        // Uses cached status so a hung network share can't freeze the menu; refresh for next time
        indexer.refreshReachability()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Dexxer", action: #selector(openMainWindow), keyEquivalent: "o"))
        let quickItem = NSMenuItem(title: "Quick Search…", action: #selector(showQuickSearch), keyEquivalent: "")
        if quickSearch.shortcut != .off {
            quickItem.title += "  (\(quickSearch.shortcut.label))"
        }
        menu.addItem(quickItem)
        menu.addItem(.separator())

        let stats = indexer.stats
        if stats.count > 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: stats.totalSize, countStyle: .file)
            addInfoItem("\(stats.count.formatted()) files indexed (\(sizeStr))", to: menu)
        } else {
            addInfoItem("No files indexed yet", to: menu)
        }

        let networkFolders = indexer.indexedFolders.filter { indexer.isNetworkFolder($0) }
        let offline = networkFolders.filter { !indexer.isReachable($0) }.count
        if !networkFolders.isEmpty {
            if offline > 0 {
                addInfoItem("⚠️ \(offline) network share\(offline == 1 ? "" : "s") offline", to: menu)
            } else {
                addInfoItem("Network shares connected", to: menu)
            }
        }

        menu.addItem(.separator())

        if indexer.isIndexing {
            if indexer.isCancellingIndex {
                addInfoItem("Stopping…", to: menu)
            } else {
                addInfoItem("Indexing… \(indexer.progress.filesChecked.formatted()) files checked", to: menu)
                menu.addItem(NSMenuItem(title: "Stop Indexing", action: #selector(cancelIndexing), keyEquivalent: ""))
            }
        } else {
            let folders = indexer.indexedFolders
            if folders.isEmpty {
                menu.addItem(NSMenuItem(title: "Add Folders to Index…", action: #selector(openMainWindow), keyEquivalent: ""))
            } else {
                menu.addItem(NSMenuItem(title: "Re-Index All", action: #selector(quickReindex), keyEquivalent: "r"))

                if folders.count > 1 {
                    let folderSubmenu = NSMenu()
                    for folder in folders {
                        let item = NSMenuItem(title: FolderActions.displayName(folder), action: #selector(reindexFolder(_:)), keyEquivalent: "")
                        item.representedObject = folder
                        item.target = self
                        item.isEnabled = indexer.isReachable(folder)
                        folderSubmenu.addItem(item)
                    }
                    folderSubmenu.autoenablesItems = false
                    let folderMenuItem = NSMenuItem(title: "Re-Index Folder", action: nil, keyEquivalent: "")
                    folderMenuItem.submenu = folderSubmenu
                    menu.addItem(folderMenuItem)
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About Dexxer", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Dexxer", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func addInfoItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc func reindexFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        let folderName = FolderActions.displayName(folder)
        indexer.indexFolders([folder]) { count in
            self.sendNotification(title: "Dexxer", body: "Checked \(count.formatted()) files in \(folderName).")
        }
    }

    @objc func showQuickSearch() {
        quickSearch.show()
    }

    // MARK: - Window

    @objc func openMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Dexxer"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: MainView(indexer: indexer, search: searchModel, quickSearch: quickSearch))
            window.center()
            window.setFrameAutosaveName("DexxerMainWindow")
            mainWindow = window
            // SwiftUI's split view adds a toolbar even with no items; on macOS 27 it fades the
            // top of the content, which hid the search bar. Dexxer doesn't use a toolbar.
            DispatchQueue.main.async { window.toolbar = nil }
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil) // hide instead of closing the app
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    // MARK: - Actions

    @objc func quickReindex() {
        guard !indexer.indexedFolders.isEmpty else {
            openMainWindow()
            return
        }
        indexer.indexFolders { count in
            self.sendNotification(title: "Dexxer", body: "Re-index finished: checked \(count.formatted()) files.")
        }
    }

    @objc func cancelIndexing() {
        indexer.cancelIndexing()
    }

    @objc func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        NSApp.activate(ignoringOtherApps: true)
        infoAlert("About Dexxer", """
            Version \(version) (\(build))
            Created by Matt Grilli © 2025

            Made this because I can't find shit in macOS.
            Finder's search is slow and useless.
            This actually works.

            Built with Swift, SQLite, and determination.

            🔍 Features:
            • Full-text search ranked by best match
            • Search syntax (type:, size:, modified:, path:)
            • Text from PDFs, images, and scanned pages
            • Network share support
            • Fast re-indexing of only what changed
            • Quick Look previews
            • Saved folder selections

            💪 No cloud. No tracking. Just local, fast search.
            """)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
