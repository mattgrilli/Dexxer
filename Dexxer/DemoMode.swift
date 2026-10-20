//
//  DemoMode.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

#if DEBUG
import AppKit

/// Builds a fictional property-management share, indexes it, and screenshots the main window
/// for the README hero. Debug builds only; uses its own folder, never the real index.
///
///     Dexxer.app/Contents/MacOS/Dexxer -DexxerDemo YES
///
/// The screenshot is written to `screenshot.png` in the "Dexxer Demo" folder of the app's temp directory.
enum DemoMode {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "DexxerDemo") }

    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Dexxer Demo", isDirectory: true)
    static var dataDirectory: URL { root.appendingPathComponent("Data", isDirectory: true) }

    /// Starts from an empty demo folder. Must run before the demo FileIndexer opens its database.
    static func resetDataDirectory() -> URL {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        return dataDirectory
    }
    private static var share: URL { root.appendingPathComponent("Shared Drive", isDirectory: true) }
    private static var screenshotURL: URL { root.appendingPathComponent("screenshot.png") }

    static let query = "fence"

    private static let communities = ["Maple Ridge HOA", "Cedar Point Condominiums", "Willow Creek Association", "Harbor View Townhomes"]

    /// Files that mention fences, so the search shows matches across every community
    private static let featured: [(path: String, text: String, daysAgo: Int)] = [
        ("Maple Ridge HOA/Architectural Requests/2025/Fence Approval - 14 Birch Lane.pdf",
         "The Architectural Review Committee approved the request to install a 6 ft cedar privacy fence along the rear property line, provided the finished side faces outward.", 3),
        ("Cedar Point Condominiums/Board Meetings/2025/Board Minutes 2025-09-16.docx",
         "Old business: the motion to replace the pool fence with black aluminum passed 4-1. Management will collect three bids before the October meeting.", 9),
        ("Willow Creek Association/Rules & Documents/Fence and Wall Guidelines.pdf",
         "No fence may exceed four feet in front yards or six feet in rear yards. Chain link fence material is not permitted on any lot.", 140),
        ("Harbor View Townhomes/Violations/2025/Violation Notice - Unit 22.docx",
         "Our inspection on August 4 found the rear fence at Unit 22 is leaning and missing two panels. Please repair the fence within 30 days.", 21),
        ("Maple Ridge HOA/Vendors & Contracts/Fence Repair Bid - Northgate Fence Co.pdf",
         "Proposal to repair 120 linear feet of split-rail fence at the north entrance, including new posts set in concrete.", 33),
        ("Cedar Point Condominiums/Reserve Study/Reserve Study 2024.pdf",
         "Component 14: perimeter fence, estimated remaining life 3 years. Replacement cost of $48,500 is scheduled for 2027.", 260),
        ("Willow Creek Association/Owner Correspondence/Re Fence height question - Lot 31.txt",
         "Thanks for checking before you build. A five foot fence is fine in the back yard, but you will need to submit an architectural request first.", 47),
        ("Harbor View Townhomes/Board Meetings/2025/Board Minutes 2025-07-08.docx",
         "The board reviewed resident complaints about the dog park fence gate. Maintenance will install a self-closing hinge.", 98)
    ]

    /// Ordinary files that fill out each community, without fence matches
    private static let filler: [(folder: String, names: [String], text: String)] = [
        ("Board Meetings/2025", ["Board Minutes 2025-01-14.docx", "Board Minutes 2025-03-11.docx", "Board Minutes 2025-05-13.docx", "Agenda 2025-10-14.pdf", "Annual Meeting Notice 2025.pdf"],
         "Call to order, approval of prior minutes, treasurer's report, landscaping update, owner forum, adjournment."),
        ("Financials", ["Monthly Financials - Jan 2025.pdf", "Monthly Financials - Feb 2025.pdf", "Monthly Financials - Mar 2025.pdf", "Monthly Financials - Apr 2025.pdf", "Monthly Financials - May 2025.pdf", "Monthly Financials - Jun 2025.pdf", "2026 Operating Budget.xlsx", "Delinquency Report Q3 2025.xlsx", "Audit 2024.pdf"],
         "Operating fund balance, reserve contributions, assessment income, and year-to-date expenses compared with budget."),
        ("Violations/2025", ["Violation Notice - Unit 7 Trash Cans.docx", "Violation Notice - Unit 15 Parking.docx", "Violation Notice - Unit 31 Landscaping.docx", "Second Notice - Unit 15.docx", "Hearing Letter - Unit 15.docx"],
         "This letter is a courtesy reminder of the community rules. Please correct the condition within 14 days."),
        ("Architectural Requests/2025", ["ARC Request - 9 Oak Street - Shed.pdf", "ARC Request - 22 Elm Court - Patio.pdf", "ARC Request - 5 Pine Way - Solar Panels.pdf", "ARC Approval - 22 Elm Court.pdf"],
         "Application for exterior modification, including plans, materials, colors, and contractor information."),
        ("Vendors & Contracts", ["Landscaping Contract 2025.pdf", "Snow Removal Agreement 2025-2026.pdf", "Pool Management Contract.pdf", "Trash Hauling Agreement.pdf", "Pest Control Proposal.pdf"],
         "Scope of services, schedule, pricing, insurance requirements, and termination terms."),
        ("Insurance", ["Master Policy 2025.pdf", "Certificate of Insurance - GreenScape Landscaping.pdf", "Certificate of Insurance - Clearwater Pools.pdf", "D&O Policy Renewal.pdf"],
         "Named insured, policy period, coverage limits, and additional insured endorsements."),
        ("Owner Correspondence", ["Welcome Letter - New Owners.docx", "Assessment Increase Notice 2026.docx", "Pool Opening Announcement.docx", "Re Parking permit request.txt", "Re Water leak in garage.txt"],
         "Thank you for reaching out. Please see the details below and let us know if you have any questions."),
        ("Rules & Documents", ["Declaration.pdf", "Bylaws.pdf", "Rules and Regulations 2025.pdf", "Pool Rules.pdf", "Parking Policy.pdf", "Collection Policy.pdf"],
         "Governing documents adopted by the board of directors, as amended."),
        ("Photos", ["Entrance Sign.jpg", "Pool Deck.jpg", "Clubhouse.jpg", "Retention Pond.jpg"], "")
    ]

    // MARK: - Run

    static func run(_ app: AppDelegate) {
        do {
            try buildShare()
        } catch {
            NSLog("Demo setup failed: \(error)")
            NSApp.terminate(nil)
            return
        }

        let indexer = app.indexer
        indexer.ocrEnabled = true
        for community in communities {
            _ = indexer.addFolder(share.appendingPathComponent(community, isDirectory: true))
        }
        indexer.indexFolders { _ in
            // Let the stats and last-indexed times settle before showing the window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                app.openMainWindow()
                if let window = NSApp.windows.first(where: { $0.title == "Dexxer" }) {
                    window.appearance = NSAppearance(named: .aqua)
                    window.setContentSize(NSSize(width: 1240, height: 720))
                    window.center()
                    // Keep the pointer off the window so no row shows hover controls
                    if window.frame.contains(NSEvent.mouseLocation), let screen = window.screen?.visibleFrame {
                        let x = NSEvent.mouseLocation.x > screen.midX ? screen.minX : screen.maxX - window.frame.width
                        window.setFrameOrigin(NSPoint(x: x, y: window.frame.minY))
                    }
                }
                app.searchModel.search(for: query)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { capture(app) }
            }
        }
    }

    private static func capture(_ app: AppDelegate) {
        // Window frame view, so the title bar is included; drawn at 2x for a sharp hero
        if let frameView = NSApp.windows.first(where: { $0.title == "Dexxer" })?.contentView?.superview,
           let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(frameView.bounds.width * 2), pixelsHigh: Int(frameView.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            bitmap.size = frameView.bounds.size
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: screenshotURL)
            NSLog("Demo screenshot written to \(screenshotURL.path)")
        }
        // Demo folders saved bookmarks into the real settings; clean them up
        for folder in app.indexer.indexedFolders {
            BookmarkStore.remove(path: folder)
        }
        NSApp.terminate(nil)
    }

    // MARK: - Fictional files

    private static func buildShare() throws {
        for file in featured {
            try write(file.path, text: file.text, daysAgo: file.daysAgo)
        }
        for (communityIndex, community) in communities.enumerated() {
            for (folderIndex, group) in filler.enumerated() {
                for (nameIndex, name) in group.names.enumerated() {
                    let daysAgo = 5 + (communityIndex * 37 + folderIndex * 23 + nameIndex * 11) % 400
                    try write("\(community)/\(group.folder)/\(name)", text: group.text, daysAgo: daysAgo)
                }
            }
        }
    }

    private static func write(_ relativePath: String, text: String, daysAgo: Int) throws {
        let url = share.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let document = NSAttributedString(string: text)
        switch url.pathExtension.lowercased() {
        case "pdf":
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
            view.string = text
            try view.dataWithPDF(inside: view.bounds).write(to: url)
        case "docx":
            try document.data(from: NSRange(location: 0, length: document.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        default:
            try Data(text.utf8).write(to: url)
        }

        // Business hours, varied per file
        let day = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
        let date = day.addingTimeInterval(8.5 * 3600 + Double(relativePath.count * 397 % 30_000))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
#endif
