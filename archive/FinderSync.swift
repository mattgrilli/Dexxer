//
//  FinderSync.swift
//  Dexxer Finder Sync Extension
//
//  Adds badges, context menus, and toolbar buttons to Finder
//

import Cocoa
import FinderSync

class FinderSync: FIFinderSync {
    
    var indexedFolders: Set<URL> = []
    var monitoredURLs: Set<URL> = []
    
    override init() {
        super.init()
        
        print("🔍 Dexxer Finder Sync Extension initialized")
        
        // Load indexed folders from shared container or UserDefaults
        loadIndexedFolders()
        
        // Set up monitoring for indexed folders
        setupMonitoring()
        
        // Listen for updates from main app
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indexedFoldersChanged),
            name: NSNotification.Name("DexxerIndexedFoldersChanged"),
            object: nil
        )
    }
    
    // MARK: - Setup
    
    func loadIndexedFolders() {
        // Try to load from shared container (if configured)
        // For now, use UserDefaults with app group
        if let sharedDefaults = UserDefaults(suiteName: "group.com.mattgrilli.dexxer") {
            if let folders = sharedDefaults.array(forKey: "IndexedFolders") as? [String] {
                indexedFolders = Set(folders.compactMap { URL(fileURLWithPath: $0) })
                print("📂 Loaded \(indexedFolders.count) indexed folders")
            }
        }
        
        // Fallback to standard UserDefaults
        if indexedFolders.isEmpty {
            if let folders = UserDefaults.standard.array(forKey: "DexxerIndexedFolders") as? [String] {
                indexedFolders = Set(folders.compactMap { URL(fileURLWithPath: $0) })
                print("📂 Loaded \(indexedFolders.count) indexed folders (fallback)")
            }
        }
    }
    
    func setupMonitoring() {
        // Clear existing monitored URLs
        FIFinderSyncController.default().directoryURLs = Set()
        monitoredURLs.removeAll()
        
        // Monitor all indexed folders
        for folder in indexedFolders {
            monitoredURLs.insert(folder)
        }
        
        if !monitoredURLs.isEmpty {
            FIFinderSyncController.default().directoryURLs = monitoredURLs
            print("👁️ Monitoring \(monitoredURLs.count) folders")
        }
    }
    
    @objc func indexedFoldersChanged() {
        print("🔄 Indexed folders changed, reloading...")
        loadIndexedFolders()
        setupMonitoring()
    }
    
    // MARK: - Badge Images
    
    override func requestBadgeIdentifier(for url: URL) {
        // Check if file is in an indexed folder
        if isFileIndexed(url) {
            FIFinderSyncController.default().setBadgeIdentifier("indexed", for: url)
        } else {
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
        }
    }
    
    func isFileIndexed(_ url: URL) -> Bool {
        let path = url.path
        
        // Check if file is within any indexed folder
        for folder in indexedFolders {
            if path.hasPrefix(folder.path) {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Context Menu
    
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")
        
        switch menuKind {
        case .contextualMenuForItems:
            // Right-click on files
            menu.addItem(withTitle: "Search in Dexxer", action: #selector(searchInDexxer(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Show File Info", action: #selector(showFileInfo(_:)), keyEquivalent: "")
            
        case .contextualMenuForContainer:
            // Right-click in empty space
            menu.addItem(withTitle: "Index This Folder in Dexxer", action: #selector(indexFolder(_:)), keyEquivalent: "")
            
        case .toolbarItemMenu:
            // Toolbar button menu
            menu.addItem(withTitle: "Open Dexxer", action: #selector(openDexxer(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Search Files...", action: #selector(searchInDexxer(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Index Current Folder", action: #selector(indexCurrentFolder(_:)), keyEquivalent: "")
            
        @unknown default:
            break
        }
        
        return menu
    }
    
    // MARK: - Toolbar
    
    override var toolbarItemName: String {
        return "Dexxer"
    }
    
    override var toolbarItemToolTip: String {
        return "Search and index with Dexxer"
    }
    
    override var toolbarItemImage: NSImage {
        return NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: "Dexxer")!
    }
    
    // MARK: - Actions
    
    @objc func searchInDexxer(_ sender: AnyObject?) {
        // Get selected files
        guard let target = FIFinderSyncController.default().targetedURL(),
              let selectedItems = FIFinderSyncController.default().selectedItemURLs() else {
            // No selection, just open Dexxer
            openDexxerURL("dexxer://open")
            return
        }
        
        if selectedItems.isEmpty {
            // Search for the current folder
            let folderName = target.lastPathComponent
            openDexxerURL("dexxer://search?q=\(folderName.urlEncoded)")
        } else if selectedItems.count == 1, let file = selectedItems.first {
            // Search for the file name
            let fileName = file.lastPathComponent
            openDexxerURL("dexxer://search?q=\(fileName.urlEncoded)")
        } else {
            // Multiple files selected, just open Dexxer
            openDexxerURL("dexxer://open")
        }
    }
    
    @objc func showFileInfo(_ sender: AnyObject?) {
        guard let selectedItems = FIFinderSyncController.default().selectedItemURLs(),
              let file = selectedItems.first else {
            return
        }
        
        // Show alert with file info
        let alert = NSAlert()
        alert.messageText = "File: \(file.lastPathComponent)"
        alert.informativeText = """
        Path: \(file.path)
        Indexed: \(isFileIndexed(file) ? "Yes" : "No")
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Search in Dexxer")
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            searchInDexxer(sender)
        }
    }
    
    @objc func indexFolder(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else {
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Index Folder?"
        alert.informativeText = "Add \(target.lastPathComponent) to Dexxer index?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Index")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let path = target.path.urlEncoded
            openDexxerURL("dexxer://index?path=\(path)")
        }
    }
    
    @objc func indexCurrentFolder(_ sender: AnyObject?) {
        indexFolder(sender)
    }
    
    @objc func openDexxer(_ sender: AnyObject?) {
        openDexxerURL("dexxer://open")
    }
    
    // MARK: - Helpers
    
    func openDexxerURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL: \(urlString)")
            return
        }
        
        NSWorkspace.shared.open(url)
    }
}

// MARK: - String Extension

extension String {
    var urlEncoded: String {
        return self.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
