//
//  OutlookMessage.swift
//  Dexxer
//
//  Created by Matt Grilli on 2025
//

import Foundation

/// An Outlook .msg file, read without Outlook. macOS has no built-in support for these.
struct OutlookMessage {
    struct Attachment: Identifiable {
        let id: Int        // directory entry of the attachment's storage
        let name: String
        let size: Int
    }

    var subject = ""
    var from = ""
    var to = ""
    var cc = ""
    var date: Date?
    var body = ""
    var attachments: [Attachment] = []

    private let file: CompoundFile

    /// Headers, attachment names, and body, for the search index
    var searchableText: String {
        [subject, from, to, cc, attachments.map(\.name).joined(separator: " "), body]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    init(contentsOf url: URL) throws {
        // mappedIfSafe reads network files into memory rather than mapping them,
        // so a dropped share can't crash us when pages are touched later
        file = try CompoundFile(data: Data(contentsOf: url, options: .mappedIfSafe))
        let root = file.childrenByName(of: 0)

        subject = text("0037", in: root)
        let senderName = text("0C1A", in: root)
        let senderAddress = [text("5D01", in: root), text("0C1F", in: root)].first { $0.contains("@") } ?? ""
        from = [senderName, senderAddress.isEmpty || senderAddress == senderName ? "" : "<\(senderAddress)>"]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        to = text("0E04", in: root)
        cc = text("0E03", in: root)
        date = messageDate(in: root)

        body = text("1000", in: root)
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let html = root["__substg1.0_10130102"].map(file.stream) {
            body = Self.plainText(fromHTML: html)
        }

        let attachmentStorages = root
            .filter { $0.key.hasPrefix("__attach_version1.0_#") }
            .sorted { $0.key < $1.key }
        for (offset, entry) in attachmentStorages.enumerated() {
            let storage = file.childrenByName(of: entry.value)
            // Long filename, short filename, then display name
            var name = "Attachment \(offset + 1)"
            for tag in ["3707", "3704", "3001"] {
                let candidate = text(tag, in: storage)
                if !candidate.isEmpty {
                    name = candidate
                    break
                }
            }
            let dataEntry = storage["__substg1.0_37010102"]
            attachments.append(Attachment(id: entry.value,
                                          name: name,
                                          size: dataEntry.map { Int(file.entries[$0].size) } ?? 0))
        }
    }

    /// The attachment's contents; nil for attachments that are themselves embedded messages
    func data(for attachment: Attachment) -> Data? {
        file.childrenByName(of: attachment.id)["__substg1.0_37010102"].map(file.stream)
    }

    // MARK: - Properties

    /// String property stored as its own stream: Unicode (001F) or 8-bit (001E)
    private func text(_ tag: String, in storage: [String: Int]) -> String {
        if let index = storage["__substg1.0_\(tag)001F"] {
            return Self.clean(String(data: file.stream(index), encoding: .utf16LittleEndian))
        }
        if let index = storage["__substg1.0_\(tag)001E"] {
            return Self.clean(String(data: file.stream(index), encoding: .windowsCP1252))
        }
        return ""
    }

    /// Sent or received time, from the fixed-size property table
    private func messageDate(in root: [String: Int]) -> Date? {
        guard let index = root["__properties_version1.0"] else { return nil }
        let table = file.stream(index)
        var sent: Date?
        var received: Date?

        // A top-level message's table has a 32-byte header, then 16-byte entries
        var offset = 32
        while offset + 16 <= table.count {
            let tag = table.uint32(at: offset)
            if tag & 0xFFFF == 0x0040 {  // PT_SYSTIME
                let date = Self.date(fromFileTime: table.uint64(at: offset + 8))
                switch tag >> 16 {
                case 0x0039: sent = date       // PR_CLIENT_SUBMIT_TIME
                case 0x0E06: received = date   // PR_MESSAGE_DELIVERY_TIME
                default: break
                }
            }
            offset += 16
        }
        return sent ?? received
    }

    private static func date(fromFileTime value: UInt64) -> Date? {
        guard value > 0 else { return nil }
        // FILETIME counts 100ns intervals since 1601
        return Date(timeIntervalSince1970: Double(value) / 10_000_000 - 11_644_473_600)
    }

    private static func clean(_ string: String?) -> String {
        (string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    }

    static func plainText(fromHTML data: Data) -> String {
        var html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        for pattern in ["(?is)<(style|script)[^>]*>.*?</\\1>", "(?i)<br\\s*/?>|</p>|</div>|</tr>", "<[^>]+>"] {
            let replacement = pattern.contains("br") ? "\n" : " "
            html = html.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, character) in entities {
            html = html.replacingOccurrences(of: entity, with: character)
        }
        return html
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Compound File Binary

enum CompoundFileError: Error {
    case notCompoundFile
    case corrupt
}

/// Minimal reader for Microsoft's Compound File Binary format ("OLE2"), the container .msg files use.
/// It's a small file system: fixed-size sectors, an allocation table chaining them together,
/// and a directory of storages (folders) and streams (files).
struct CompoundFile {
    struct Entry {
        let name: String
        let type: UInt8          // 1 storage, 2 stream, 5 root
        let left: UInt32
        let right: UInt32
        let child: UInt32
        let start: UInt32
        let size: UInt64
    }

    private static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let noEntry: UInt32 = 0xFFFF_FFFF

    let entries: [Entry]
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: Int
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let miniStream: Data

    init(data: Data) throws {
        guard data.count >= 512, Array(data.prefix(8)) == Self.signature else { throw CompoundFileError.notCompoundFile }
        self.data = data

        let sectorShift = Int(data.uint16(at: 0x1E))
        let miniSectorShift = Int(data.uint16(at: 0x20))
        guard (9...12).contains(sectorShift), miniSectorShift == 6 else { throw CompoundFileError.corrupt }
        sectorSize = 1 << sectorShift
        miniSectorSize = 1 << miniSectorShift
        miniStreamCutoff = Int(data.uint32(at: 0x38))

        // The allocation table's own sectors are listed in the header, then in a chain of extra sectors
        var fatSectors: [UInt32] = (0..<109).map { data.uint32(at: 0x4C + $0 * 4) }
        var difatSector = data.uint32(at: 0x44)
        var difatCount = Int(data.uint32(at: 0x48))
        let perDifatSector = sectorSize / 4 - 1
        while difatCount > 0, difatSector < Self.endOfChain {
            let offset = (Int(difatSector) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { throw CompoundFileError.corrupt }
            fatSectors += (0..<perDifatSector).map { data.uint32(at: offset + $0 * 4) }
            difatSector = data.uint32(at: offset + perDifatSector * 4)
            difatCount -= 1
        }
        let fatSectorCount = Int(data.uint32(at: 0x2C))
        var fat: [UInt32] = []
        for sector in fatSectors.prefix(fatSectorCount) where sector < Self.endOfChain {
            let offset = (Int(sector) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { throw CompoundFileError.corrupt }
            fat += (0..<(sectorSize / 4)).map { data.uint32(at: offset + $0 * 4) }
        }
        self.fat = fat

        // Directory entries are 128 bytes each
        let directory = Self.readChain(from: data.uint32(at: 0x30), fat: fat, data: data, sectorSize: sectorSize)
        var entries: [Entry] = []
        var offset = 0
        while offset + 128 <= directory.count {
            let nameLength = min(Int(directory.uint16(at: offset + 0x40)), 64)
            let nameData = directory.subdata(in: offset..<(offset + max(nameLength - 2, 0)))
            entries.append(Entry(
                name: String(data: nameData, encoding: .utf16LittleEndian) ?? "",
                type: directory[offset + 0x42],
                left: directory.uint32(at: offset + 0x44),
                right: directory.uint32(at: offset + 0x48),
                child: directory.uint32(at: offset + 0x4C),
                start: directory.uint32(at: offset + 0x74),
                // Version 3 files only use the low 32 bits
                size: sectorSize == 512 ? UInt64(directory.uint32(at: offset + 0x78)) : directory.uint64(at: offset + 0x78)
            ))
            offset += 128
        }
        guard let root = entries.first, root.type == 5 else { throw CompoundFileError.corrupt }
        self.entries = entries

        // Small streams live in the "mini stream", which is stored as the root entry's data
        miniStream = Self.readChain(from: root.start, fat: fat, data: data, sectorSize: sectorSize).prefix(Int(root.size))
        let miniFatData = Self.readChain(from: data.uint32(at: 0x3C), fat: fat, data: data, sectorSize: sectorSize)
        miniFat = (0..<(miniFatData.count / 4)).map { miniFatData.uint32(at: $0 * 4) }
    }

    /// Children of a storage, keyed by name. Siblings are kept in a binary tree.
    func childrenByName(of index: Int) -> [String: Int] {
        guard entries.indices.contains(index) else { return [:] }
        var result: [String: Int] = [:]
        var stack = [entries[index].child]
        var visited = Set<UInt32>()
        while let id = stack.popLast() {
            guard id != Self.noEntry, Int(id) < entries.count, visited.insert(id).inserted else { continue }
            let entry = entries[Int(id)]
            result[entry.name] = Int(id)
            stack.append(entry.left)
            stack.append(entry.right)
        }
        return result
    }

    func stream(_ index: Int) -> Data {
        guard entries.indices.contains(index) else { return Data() }
        let entry = entries[index]
        let size = Int(min(entry.size, UInt64(Int.max)))

        guard size < miniStreamCutoff else {
            return Self.readChain(from: entry.start, fat: fat, data: data, sectorSize: sectorSize).prefix(size)
        }

        var result = Data()
        var sector = entry.start
        var steps = 0
        while sector < Self.endOfChain, Int(sector) < miniFat.count, steps <= miniFat.count, result.count < size {
            let offset = Int(sector) * miniSectorSize
            guard offset + miniSectorSize <= miniStream.count else { break }
            result += miniStream.subdata(in: (miniStream.startIndex + offset)..<(miniStream.startIndex + offset + miniSectorSize))
            sector = miniFat[Int(sector)]
            steps += 1
        }
        return result.prefix(size)
    }

    private static func readChain(from start: UInt32, fat: [UInt32], data: Data, sectorSize: Int) -> Data {
        var result = Data()
        var sector = start
        var steps = 0
        // Bounded by the table size so a corrupt, looping chain can't hang indexing
        while sector < endOfChain, Int(sector) < fat.count, steps <= fat.count {
            let offset = (Int(sector) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { break }
            result += data.subdata(in: offset..<(offset + sectorSize))
            sector = fat[Int(sector)]
            steps += 1
        }
        return result
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return self[(startIndex + offset)..<(startIndex + offset + 2)].reversed().reduce(0) { $0 << 8 | UInt16($1) }
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return self[(startIndex + offset)..<(startIndex + offset + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return self[(startIndex + offset)..<(startIndex + offset + 8)].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}
