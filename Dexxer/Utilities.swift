//
//  Utilities.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import AppKit

/// Blocking confirmation alert usable from anywhere (AppKit + SwiftUI contexts).
@discardableResult
func confirm(_ title: String,
             _ message: String,
             confirmButton: String = "OK",
             cancelButton: String = "Cancel",
             style: NSAlert.Style = .warning) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
    alert.addButton(withTitle: confirmButton)
    alert.addButton(withTitle: cancelButton)
    return alert.runModal() == .alertFirstButtonReturn
}

/// Simple info alert
func infoAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
