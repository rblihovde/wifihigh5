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

    /// Split by assignment size. A block registered as MA-M or MA-S sits inside
    /// a shared MA-L prefix, so the longest match is the accurate one.
    private var mal: [UInt64: String] = [:]   // 24-bit
    private var mam: [UInt64: String] = [:]   // 28-bit
    private var mas: [UInt64: String] = [:]   // 36-bit

    /// `url` is injectable so the table can be exercised without an app bundle.
    init(url: URL? = nil) {
        load(from: url ?? Bundle.main.url(forResource: "OUI", withExtension: "txt"))
    }

    private func load(from url: URL?) {
        guard let url else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            var l: [UInt64: String] = [:], m: [UInt64: String] = [:], s: [UInt64: String] = [:]
            var retrieved: String?

            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("#") {
                    if line.hasPrefix("# retrieved: ") {
                        retrieved = String(line.dropFirst("# retrieved: ".count))
                    }
                    continue
                }
                guard let tab = line.firstIndex(of: "\t") else { continue }
                let prefix = line[line.startIndex..<tab]
                let name = String(line[line.index(after: tab)...])
                guard let key = UInt64(prefix, radix: 16) else { continue }
                switch prefix.count {
                case 6: l[key] = name
                case 7: m[key] = name
                case 9: s[key] = name
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
        guard let mac else { return .unregistered }
        let hex = mac.replacingOccurrences(of: ":", with: "")
                     .replacingOccurrences(of: "-", with: "")
                     .uppercased()
        guard hex.count >= 6, let firstByte = UInt8(hex.prefix(2), radix: 16) else {
            return .unregistered
        }
        // Bit 1 of the first octet marks a locally administered address.
        if firstByte & 0x02 != 0 { return .randomised }
        guard isReady else { return .loading }

        if hex.count >= 9, let k = UInt64(hex.prefix(9), radix: 16), let hit = mas[k] {
            return .known(hit)
        }
        if hex.count >= 7, let k = UInt64(hex.prefix(7), radix: 16), let hit = mam[k] {
            return .known(hit)
        }
        if let k = UInt64(hex.prefix(6), radix: 16), let hit = mal[k] {
            return .known(hit)
        }
        return .unregistered
    }

    /// The vendor prefix itself, which stays useful even when unregistered.
    func prefix(of mac: String?) -> String? {
        guard let mac else { return nil }
        let parts = mac.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(3).joined(separator: ":")
    }
}
