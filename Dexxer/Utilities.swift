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
             confirmButton: String = "Re-Index",
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

/// Returns true for paths under mounted volumes (e.g., /Volumes/Share)
func isNetworkPath(_ path: String) -> Bool {
    return path.hasPrefix("/Volumes/")
}

/// Tiny single-line prompt (used for “Connect…”)
func promptForText(title: String, message: String, placeholder: String = "", defaultValue: String? = nil) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")

    let tf = NSTextField(string: defaultValue ?? "")
    tf.placeholderString = placeholder
    tf.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    alert.accessoryView = tf

    let resp = alert.runModal()
    return resp == .alertFirstButtonReturn ? tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}
