import Foundation
import SwiftUI

/// One row of the observed devices list, assembled once per refresh so the
/// row view does no lookups of its own.
struct ObservedDevice: Identifiable {
    var mac: String
    var ip: String
    var role: DeviceRole
    var record: DeviceRecord?
    var vendor: VendorResult
    /// The registered block behind `vendor`, with its country and registry.
    var vendorBlock: VendorBlock? = nil
    var sighting: DevicePresence.Sighting?
    var isLocallyAdministered: Bool
    /// False for a device seen earlier in this session that has since dropped
    /// out of the neighbour cache.
    var isPresent: Bool
    /// What the manufacturer implies, when it implies anything. Never shown in
    /// place of something the user or the device itself said.
    var guess: DeviceGuess?
    /// What the device said about itself, if the user chose to ask.
    var finding: DeviceFinding?
    /// Additional IPv6 addresses associated with the same hardware address.
    var ipv6Addresses: [String] = []
    /// Used for hosts outside the local neighbour table, where no MAC exists.
    var identityKey: String? = nil

    var id: String { identityKey ?? mac }
    var hasHardwareAddress: Bool { DeviceRegistry.isValidMAC(mac) }

    var addressSummary: String {
        ([ip] + ipv6Addresses.filter { $0 != ip }).joined(separator: "\n")
    }

    var category: DeviceCategory { record?.category ?? .unlabelled }

    var nickname: String? {
        guard let record, record.hasNickname else { return nil }
        return record.nickname
    }

    /// What the row is called. The user's own name wins, then a name the
    /// device published for itself, then what this Mac worked out. A guess
    /// never supplies the name — it only ever appears as a hedge underneath.
    var displayName: String {
        if let nickname { return nickname }
        if let discovered = finding?.bestName { return discovered }
        if role != .device { return role.label }
        if category != .unlabelled { return category.label }
        return "Observed device"
    }

    /// True when anything in this row came from asking rather than watching.
    var wasDiscovered: Bool { finding?.isEmpty == false }

    var wasActivelyScanned: Bool { finding?.scanObservedAt != nil }

    var openPortSummary: String? {
        guard let ports = finding?.openPorts, !ports.isEmpty else { return nil }
        return ports.sorted().map { port in
            "\(LANScanner.serviceName(for: port)) \(port)"
        }.joined(separator: ", ")
    }

    var symbol: String {
        if role != .device { return role.symbol }
        if category != .unlabelled { return category.symbol }
        if let suggested = guess?.category { return suggested.symbol }
        return "desktopcomputer"
    }

    var tint: Color {
        if role != .device { return role.tint }
        return category == .unlabelled ? .secondary : .indigo
    }

    var vendorText: String {
        guard hasHardwareAddress else { return "Not available outside local link" }
        switch vendor {
        case .known(let name): return name
        case .randomised:      return "Not available for private addresses"
        case .unregistered:    return "Not identified"
        case .loading:         return "Loading…"
        }
    }

    var isNew: Bool { sighting?.arrivedWhileWatching == true && isPresent }

    var searchHaystack: String {
        var terms: [String] = [displayName, ip, mac, vendorText, role.label, category.label]
        terms.append(record?.notes ?? "")
        terms.append(guess?.summary ?? "")
        if let finding {
            terms.append(finding.advertisedName ?? "")
            terms.append(finding.model ?? "")
            terms.append(finding.hostname ?? "")
            terms.append(finding.smbName ?? "")
            terms.append(finding.smbDomain ?? "")
            terms.append(contentsOf: finding.services)
            terms.append(contentsOf: finding.openPorts.map(String.init))
        }
        terms.append(contentsOf: ipv6Addresses)
        return terms.joined(separator: " ")
    }
}

enum DeviceSort: String, CaseIterable, Identifiable {
    case address = "Address"
    case role = "Role"
    case name = "Name"
    case manufacturer = "Manufacturer"
    case firstSeen = "First seen"

    var id: String { rawValue }
}
