import Foundation
import SwiftUI

/// The part a device plays on this subnet, as far as this Mac can tell from
/// its own configuration.
///
/// Every case is derived from something the Mac already knows: the gateway it
/// was told to use, the DHCP and DNS servers in its lease, and the BSSID of the
/// radio it is associated with. Nothing here is probed or guessed at.
enum DeviceRole: Equatable {
    case thisMac
    case routerAndAccessPoint
    case router
    case accessPoint
    case dhcpServer
    case dnsServer
    case device

    var label: String {
        switch self {
        case .thisMac:              return "This Mac"
        case .routerAndAccessPoint: return "Router and access point"
        case .router:               return "Router"
        case .accessPoint:          return "Access point"
        case .dhcpServer:           return "DHCP server"
        case .dnsServer:            return "DNS server"
        case .device:               return "Observed device"
        }
    }

    /// Why the app believes this, in the words the Diagnostics tab uses.
    var basis: String? {
        switch self {
        case .thisMac:
            return "The address this Mac holds on the subnet."
        case .routerAndAccessPoint:
            return "This Mac's gateway, on a hardware address adjacent to the BSSID it is associated with, which means one box is doing both jobs."
        case .router:
            return "The gateway address this Mac was given for this network."
        case .accessPoint:
            return "The hardware address matches the BSSID this Mac is associated with."
        case .dhcpServer:
            return "The server that issued this Mac's address lease."
        case .dnsServer:
            return "One of the name servers this Mac was told to use."
        case .device:
            return nil
        }
    }

    var symbol: String {
        switch self {
        case .thisMac:              return "laptopcomputer"
        case .routerAndAccessPoint: return "wifi.router"
        case .router:               return "wifi.router"
        case .accessPoint:          return "dot.radiowaves.up.forward"
        case .dhcpServer:           return "square.and.arrow.down.on.square"
        case .dnsServer:            return "character.book.closed"
        case .device:               return "desktopcomputer"
        }
    }

    var tint: Color {
        switch self {
        case .thisMac:              return .accentColor
        case .routerAndAccessPoint: return .blue
        case .router:               return .blue
        case .accessPoint:          return .teal
        case .dhcpServer:           return .purple
        case .dnsServer:            return .purple
        case .device:               return .secondary
        }
    }

    /// Infrastructure sorts above ordinary hosts, so the shape of the network
    /// reads from the top of the list down.
    var sortRank: Int {
        switch self {
        case .thisMac:              return 0
        case .routerAndAccessPoint: return 1
        case .router:               return 1
        case .accessPoint:          return 2
        case .dhcpServer:           return 3
        case .dnsServer:            return 4
        case .device:               return 5
        }
    }
}

enum DeviceRoleResolver {

    /// Works out a device's role from configuration this Mac already holds.
    ///
    /// `bssid` is the radio this Mac is currently associated with. When the
    /// gateway's hardware address sits in the same vendor block and within a
    /// few addresses of it, the router and the access point are one box — the
    /// same reasoning the network map uses.
    static func role(forMAC mac: String,
                     ip: String,
                     config: IPConfig,
                     bssid: String?,
                     isSelf: Bool = false) -> DeviceRole {
        if isSelf { return .thisMac }

        let sameRadio = bssid.map { candidate in
            DeviceRegistry.normalise(candidate) == DeviceRegistry.normalise(mac)
                || ARPTable.likelySameChassis(candidate, mac)
        } ?? false

        if ip == config.router {
            return sameRadio ? .routerAndAccessPoint : .router
        }
        if sameRadio { return .accessPoint }
        if let dhcp = config.dhcpServer, ip == dhcp { return .dhcpServer }
        if config.dnsServers.contains(ip) { return .dnsServer }
        return .device
    }
}
