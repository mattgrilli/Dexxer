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
    var indexer = FileIndexer()
    private var mainWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar style app (no Dock icon). If you want Dock icon, switch to .regular.
        NSApp.setActivationPolicy(.accessory)

        // Notifications (optional)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: "Dexxer")
            button.action = #selector(showMenu)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        // 🔔 Watch for volumes mounting/unmounting (SMB/NFS shares show up here)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumeMounted(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeUnmounted(_:)),
                       name: NSWorkspace.willUnmountNotification, object: nil)
    }

    // MARK: - Volume notifications

    @objc private func volumeMounted(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        // Ask indexer to resume if any saved folder lives under this mounted volume
        indexer.resumeIfFolderInside(mountedVolumeURL: url)
    }

    @objc private func volumeUnmounted(_ note: Notification) {
        // Optional: you could notify the user or cancel an in-flight index here.
        // Leaving empty keeps behavior simple.
    }

    // MARK: - Menu

    @objc func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "🔍 Open Dexxer", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(.separator())

        // Stats (local + total)
        let stats = indexer.getStats()
        let sizeStr = ByteCountFormatter.string(fromByteCount: stats.totalSize, countStyle: .file)
        let statsItem = NSMenuItem(title: "📊 \(stats.count.formatted()) files (\(sizeStr))", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        // Network summary
        let networkFolders = indexer.indexedFolders.filter { indexer.isNetworkFolder($0) }
        if !networkFolders.isEmpty {
            let connected = networkFolders.filter { indexer.isReachableFolder($0) }.count
            let disconnected = networkFolders.count - connected
            let net = NSMenuItem(title: "🌐 Network: \(connected) connected, \(disconnected) disconnected", action: nil, keyEquivalent: "")
            net.isEnabled = false
            menu.addItem(net)
        }

        menu.addItem(.separator())

        if indexer.isIndexing {
            let indexingItem = NSMenuItem(title: "⏳ Indexing... \(indexer.indexProgress) files", action: nil, keyEquivalent: "")
            indexingItem.isEnabled = false
            menu.addItem(indexingItem)
        } else {
            let re = NSMenuItem(title: "🔄 Quick Re-Index", action: #selector(quickReindex), keyEquivalent: "")
            menu.addItem(re)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "ℹ️ About Dexxer", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dexxer", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }


    // MARK: - Window

    @objc func openMainWindow() {
        if mainWindow == nil {
            let w = createWindow(title: "Dexxer", width: 1100, height: 750)
            w.delegate = self
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView(indexer: indexer))
            mainWindow = w
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

    private func createWindow(title: String, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - Actions

    @objc func quickReindex() {
        if indexer.isIndexing {
            showAlert(title: "Already Indexing", message: "Please wait for the current indexing task to finish.")
            return
        }
        if indexer.indexedFolders.isEmpty {
            showAlert(title: "No Folders", message: "Please add folders first in Manage Folders.")
            return
        }
        sendNotification(title: "Dexxer", body: "Re-indexing all folders...")
        indexer.indexFolders { count in
            DispatchQueue.main.async {
                self.sendNotification(title: "Dexxer", body: "Indexed \(count) files!")
            }
        }
    }

    @objc func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

        showAlert(
            title: "About Dexxer",
            message: """
            Version \(version) (\(build))
            Created by Matt Grilli © 2025

            Made this because I can't find shit in macOS.
            Finder's search is slow and useless.
            This actually works.

            Built with Swift, SQLite, and determination.

            🔍 Fast local file indexing
            📊 Search thousands of files instantly
            💪 No BS, just results
            """
        )
    }


    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
