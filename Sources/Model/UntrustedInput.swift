import Foundation

/// Limits on an import file, checked before anything in it is merged.
///
/// Import is the one place the app reads a file someone else may have made.
/// Without limits a large or hostile file could exhaust memory or hang the
/// window, and a structurally valid one could carry values the app never writes
/// itself, such as a colour outside the palette.
enum ImportGuard {
    static let maxFileBytes = 20 * 1024 * 1024
    static let maxRecords = 10_000
    static let maxNameLength = 256
    static let maxSiteLength = 512
    static let maxNotesLength = 8_192
    static let maxKeyLength = 256

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case tooLarge(bytes: Int)
        case notAnExport
        case tooManyRecords(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "The file could not be opened. Nothing was imported."
            case .tooLarge(let bytes):
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                return "That file is \(size), far larger than any export this app writes. Nothing was imported."
            case .notAnExport:
                return "That file is not a WifiHigh5 export. Nothing was imported."
            case .tooManyRecords(let count):
                return "That file holds \(count) records, more than the \(maxRecords) an import accepts. Nothing was imported."
            }
        }
    }

    /// Reads a file only after checking its size, so an oversized file is
    /// refused without ever being loaded.
    static func read(_ url: URL) throws -> Data {
        let size: Int
        do {
            size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw Failure.unreadable
        }
        guard size <= maxFileBytes else { throw Failure.tooLarge(bytes: size) }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable
        }
    }
}

/// Text that arrived from somewhere the app does not control: an import file,
/// a Bonjour advertisement, a DNS answer.
enum UntrustedText {

    /// Bidirectional formatting controls. They can make a name display as
    /// something other than what it is, and nothing legitimate here needs them.
    private static let directionControls: Set<UInt32> = [
        0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    /// Removes control and direction-override characters and caps the length.
    /// Newlines survive only where asked, which is in notes.
    static func clean(_ text: String, limit: Int, allowNewlines: Bool = false) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if allowNewlines, scalar == "\n" {
                kept.append(scalar)
                continue
            }
            if scalar.properties.generalCategory == .control { continue }
            if directionControls.contains(scalar.value) { continue }
            kept.append(scalar)
        }
        let cleaned = String(kept)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }

    /// True for a dotted IPv4 address and nothing else.
    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil && $0.count <= 3 }
    }

    /// True for six hexadecimal octets separated by colons.
    static func isMAC(_ text: String) -> Bool {
        let octets = text.split(separator: ":", omittingEmptySubsequences: false)
        return octets.count == 6 && octets.allSatisfy {
            (1...2).contains($0.count) && UInt8($0, radix: 16) != nil
        }
    }
}

extension APKey {
    /// True for a key this app could have written: a BSSID, or a radio
    /// fingerprint.
    static func isWellFormed(_ raw: String) -> Bool {
        guard raw.count <= ImportGuard.maxKeyLength else { return false }
        if raw.hasPrefix("bssid:") { return UntrustedText.isMAC(String(raw.dropFirst(6))) }
        return raw.hasPrefix("fp:")
    }
}
