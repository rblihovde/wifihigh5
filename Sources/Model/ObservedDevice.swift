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

    var id: String { mac }

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
            terms.append(contentsOf: finding.services)
        }
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
