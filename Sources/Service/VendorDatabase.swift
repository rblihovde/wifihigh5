import Foundation
import Combine

/// What the registry can say about one MAC address.
enum VendorResult: Equatable {
    /// Resolved to a registered organisation.
    case known(String)
    /// Locally administered, so the address was assigned by software. There is
    /// no manufacturer to look up and the prefix means nothing.
    case randomised
    /// A real hardware address whose block is not in the registry.
    case unregistered
    case loading

    var displayName: String? {
        switch self {
        case .known(let name): return name
        case .randomised:      return "Randomised address"
        case .unregistered:    return "Not in IEEE registry"
        case .loading:         return nil
        }
    }
}

/// Everything the registry records about the block an address falls in.
struct VendorBlock: Equatable {
    var organisation: String
    /// ISO 3166 code from the registrant's address, when it gave one. This is
    /// where the registrant is based, not where the device was made.
    var countryCode: String?
    /// MA-L, MA-M, MA-S or IAB.
    var registry: String
    /// The assigned prefix, as colon-separated hex (a half octet for MA-M).
    var prefix: String
    /// Bits fixed by the assignment: 24, 28 or 36.
    var prefixBits: Int

    var countryName: String? {
        guard let countryCode else { return nil }
        return Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
    }

    /// How many addresses the block holds, in words.
    var sizeText: String {
        switch prefixBits {
        case 24: return "16.8 million addresses"
        case 28: return "1 million addresses"
        default: return "4,096 addresses"
        }
    }

    /// One line for an inspector: "00:1B:63 · MA-L · 16.8 million addresses".
    var summary: String { "\(prefix) · \(registry) · \(sizeText)" }
}

/// Resolves MAC addresses to the organisation that registered the block.
///
/// The database ships inside the app bundle and is generated from the IEEE
/// registry by `tools/update-oui.sh`. Nothing is fetched at runtime: this tool
/// is meant to be run on client networks, so it must not reach the network to
/// answer a question about a client's own hardware.
@MainActor
final class VendorDatabase: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var recordCount = 0
    @Published private(set) var retrieved: String?

    private struct Entry {
        var name: String
        var country: String?
        var registry: String?
    }

    /// Split by assignment size. A block registered as MA-M, MA-S or IAB sits
    /// inside a shared MA-L prefix, so the longest match is the accurate one.
    private var mal: [UInt64: Entry] = [:]   // 24-bit
    private var mam: [UInt64: Entry] = [:]   // 28-bit
    private var mas: [UInt64: Entry] = [:]   // 36-bit, MA-S and IAB

    /// `url` is injectable so the table can be exercised without an app bundle.
    init(url: URL? = nil) {
        load(from: url ?? Bundle.main.url(forResource: "OUI", withExtension: "txt"))
    }

    private func load(from url: URL?) {
        guard let url else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            var l: [UInt64: Entry] = [:], m: [UInt64: Entry] = [:], s: [UInt64: Entry] = [:]
            var retrieved: String?

            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("#") {
                    if line.hasPrefix("# retrieved: ") {
                        retrieved = String(line.dropFirst("# retrieved: ".count))
                    }
                    continue
                }
                // prefix, name, then optional country and registry columns.
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 2, !fields[1].isEmpty,
                      let key = UInt64(fields[0], radix: 16) else { continue }
                let country = fields.count > 2 && fields[2].count == 2 ? String(fields[2]) : nil
                let registry = fields.count > 3 && !fields[3].isEmpty ? String(fields[3]) : nil
                let entry = Entry(name: String(fields[1]), country: country, registry: registry)
                switch fields[0].count {
                case 6: l[key] = entry
                case 7: m[key] = entry
                case 9: s[key] = entry
                default: break
                }
            }

            let total = l.count + m.count + s.count
            Task { @MainActor in
                self.mal = l; self.mam = m; self.mas = s
                self.recordCount = total
                self.retrieved = retrieved
                self.isReady = true
            }
        }
    }

    /// Longest-prefix lookup, after ruling out software-assigned addresses.
    func lookup(_ mac: String?) -> VendorResult {
        guard let hex = Self.hex(mac), let firstByte = UInt8(hex.prefix(2), radix: 16) else {
            return .unregistered
        }
        // Bit 1 of the first octet marks a locally administered address.
        if firstByte & 0x02 != 0 { return .randomised }
        guard isReady else { return .loading }
        return block(hex: hex).map { .known($0.organisation) } ?? .unregistered
    }

    /// The registered block a hardware address falls in, with its country and
    /// registry. Nil for randomised, unregistered or malformed addresses.
    func block(for mac: String?) -> VendorBlock? {
        guard isReady, let hex = Self.hex(mac),
              let firstByte = UInt8(hex.prefix(2), radix: 16),
              firstByte & 0x02 == 0 else { return nil }
        return block(hex: hex)
    }

    private func block(hex: String) -> VendorBlock? {
        let tables: [(digits: Int, table: [UInt64: Entry], registry: String)] = [
            (9, mas, "MA-S"), (7, mam, "MA-M"), (6, mal, "MA-L")
        ]
        for (digits, table, registry) in tables where hex.count >= digits {
            guard let key = UInt64(hex.prefix(digits), radix: 16), let hit = table[key] else { continue }
            let pairs = stride(from: 0, to: digits, by: 2).map { offset -> String in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return String(hex[start..<hex.index(start, offsetBy: min(2, digits - offset))])
            }
            return VendorBlock(organisation: hit.name, countryCode: hit.country,
                               registry: hit.registry ?? registry,
                               prefix: pairs.joined(separator: ":"),
                               prefixBits: digits * 4)
        }
        return nil
    }

    /// Bare uppercase hex, or nil when there are not even three octets.
    private static func hex(_ mac: String?) -> String? {
        guard let mac else { return nil }
        let hex = mac.replacingOccurrences(of: ":", with: "")
                     .replacingOccurrences(of: "-", with: "")
                     .uppercased()
        guard hex.count >= 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// The vendor prefix itself, which stays useful even when unregistered.
    func prefix(of mac: String?) -> String? {
        guard let mac else { return nil }
        let parts = mac.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(3).joined(separator: ":")
    }
}
