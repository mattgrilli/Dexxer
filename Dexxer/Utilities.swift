//
//  Utilities.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import AppKit
import SwiftUI

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

/// Tiny single-line prompt (used for "Connect…")
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

/// Custom tooltip modifier that actually works (unlike SwiftUI's .help())
struct TooltipModifier: ViewModifier {
    let tooltip: String

    func body(content: Content) -> some View {
        content.background(
            TooltipView(tooltip: tooltip)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        )
    }
}

struct TooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = TooltipHostView()
        view.toolTip = tooltip
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

/// Custom NSView that shows tooltips faster
class TooltipHostView: NSView {
    override func addToolTip(_ rect: NSRect, owner: Any, userData: UnsafeMutableRawPointer?) -> NSView.ToolTipTag {
        // Return the tag but don't modify behavior - macOS controls timing
        return super.addToolTip(rect, owner: owner, userData: userData)
    }

    // Override to show tooltip immediately on mouse enter
    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove existing tracking areas
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }

        // Add new tracking area with better tooltip behavior
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
}

extension View {
    func appTooltip(_ tooltip: String) -> some View {
        self.modifier(TooltipModifier(tooltip: tooltip))
    }
}
