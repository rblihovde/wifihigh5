import Foundation

// Lightweight stand-ins for OS-facing services. They let the topology builder
// be tested as a pure transformation without starting CoreWLAN or ICMP work.
enum LinkStatus: Equatable {
    case connected, disconnected, poweredOff, noInterface
}

struct IPConfig {
    var ipv4: String?
    var subnetMask: String?
    var router: String?
    var ipv6: [String] = []
    var dnsServers: [String] = []
    var searchDomains: [String] = []
    var dhcpServer: String?
    var leaseStart: Date?
    var leaseDuration: TimeInterval?
    var primaryInterface: String?
    var activeMAC: String?

    var leaseExpiry: Date? {
        guard let leaseStart, let leaseDuration else { return nil }
        return leaseStart.addingTimeInterval(leaseDuration)
    }
}

struct ScanResult: Identifiable {
    let id = UUID()
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var channel: Int
    var bandRaw: Int
    var widthRaw: Int
    var securityRaw: Int
    var isCurrentNetwork: Bool
    var isCurrentAP: Bool

    var band: Band { bandLabel(bandRaw) }
    var quality: SignalQuality { SignalQuality(rssi: rssi) }
    var key: APKey {
        APKey(bssid: bssid, ssid: ssid, channel: channel,
              bandRaw: bandRaw, phyRaw: 0, securityRaw: securityRaw)
    }
}

enum SystemNetwork {
    static func usingPrivateAddress(hardware: String?, active: String?) -> Bool {
        guard let hardware = hardware?.lowercased(), let active = active?.lowercased() else { return false }
        return hardware != active
    }
}

@MainActor
final class GatewayPinger {
    var enabled = false
    var lastRTT: Double?
    var history: [(Date, Double?)] = []
    var completed = 0
    var received = 0
    var lossPercent: Double {
        guard completed > 0 else { return 0 }
        return Double(completed - received) / Double(completed) * 100
    }
}
