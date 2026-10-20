//
//  ShareExtension.swift
//  Dexxer Share Extension
//
//  Allows users to share files directly to Dexxer for indexing
//

import Foundation
import AppKit

@objc(ShareExtension)
class ShareExtension: NSObject, NSExtensionRequestHandling {
    
    func beginRequest(with context: NSExtensionContext) {
        // Get shared items (files)
        guard let items = context.inputItems as? [NSExtensionItem] else {
            context.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        
        var filePaths: [String] = []
        let group = DispatchGroup()
        
        for item in items {
            guard let attachments = item.attachments else { continue }
            
            for provider in attachments {
                // Check if it's a file URL
                if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                    group.enter()
                    
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (item, error) in
                        defer { group.leave() }
                        
                        if let error = error {
                            print("Error loading item: \(error)")
                            return
                        }
                        
                        if let url = item as? URL {
                            filePaths.append(url.path)
                        }
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            if filePaths.isEmpty {
                self.showAlert(title: "No Files", message: "No files were shared.")
                context.cancelRequest(withError: NSError(domain: "DexxerShareExtension", code: -1))
                return
            }
            
            // Show confirmation
            let alert = NSAlert()
            alert.messageText = "Add to Dexxer?"
            alert.informativeText = "Index \(filePaths.count) file\(filePaths.count == 1 ? "" : "s")?\n\n\(filePaths.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n"))\(filePaths.count > 3 ? "\n..." : "")"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Add to Index")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            
            if response == .alertFirstButtonReturn {
                // User confirmed - trigger indexing via URL scheme
                self.triggerIndexing(filePaths: filePaths)
                context.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                context.cancelRequest(withError: NSError(domain: "DexxerShareExtension", code: 0))
            }
        }
    }
    
    private func triggerIndexing(filePaths: [String]) {
        // For individual files, we'll use the dexxer:// URL scheme
        // to communicate with the main app
        
        if filePaths.count == 1, let path = filePaths.first {
            // Single file - use URL scheme
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
            if let url = URL(string: "dexxer://index?path=\(encodedPath)") {
                NSWorkspace.shared.open(url)
            }
        } else {
            // Multiple files - for now, just open Dexxer
            // In a real implementation, you'd want to use shared container
            // or XPC to communicate with the main app
            if let url = URL(string: "dexxer://open") {
                NSWorkspace.shared.open(url)
            }
            
            // Show notification
            let notification = NSUserNotification()
            notification.title = "Dexxer"
            notification.informativeText = "Shared \(filePaths.count) files. Please add their parent folders to index them."
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
