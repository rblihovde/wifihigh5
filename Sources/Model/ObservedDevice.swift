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

    var id: String { mac }

    var category: DeviceCategory { record?.category ?? .unlabelled }

    var nickname: String? {
        guard let record, record.hasNickname else { return nil }
        return record.nickname
    }

    /// What the row is called: the user's name for it, else its role, else the
    /// category they filed it under.
    var displayName: String {
        if let nickname { return nickname }
        if role != .device { return role.label }
        if category != .unlabelled { return category.label }
        return "Observed device"
    }

    var symbol: String {
        if role != .device { return role.symbol }
        if category != .unlabelled { return category.symbol }
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
        [displayName, ip, mac, vendorText, role.label, category.label,
         record?.notes ?? ""].joined(separator: " ")
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
