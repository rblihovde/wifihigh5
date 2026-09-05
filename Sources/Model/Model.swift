import Foundation
import SwiftUI
import CoreWLAN

// MARK: - Signal quality

enum SignalQuality: Int, CaseIterable, Comparable {
    case poor = 0, weak, fair, good, excellent

    static func < (l: SignalQuality, r: SignalQuality) -> Bool { l.rawValue < r.rawValue }

    /// Thresholds follow common Wi-Fi site-survey practice (dBm).
    init(rssi: Int) {
        switch rssi {
        case (-50)...:      self = .excellent
        case (-60)..<(-50): self = .good
        case (-67)..<(-60): self = .fair
        case (-75)..<(-67): self = .weak
        default:            self = .poor
        }
    }

    init(snr: Int) {
        switch snr {
        case 40...:   self = .excellent
        case 25..<40: self = .good
        case 15..<25: self = .fair
        case 10..<15: self = .weak
        default:      self = .poor
        }
    }

    var label: String {
        switch self {
        case .excellent: return "Excellent"
        case .good:      return "Good"
        case .fair:      return "Fair"
        case .weak:      return "Weak"
        case .poor:      return "Poor"
        }
    }

    var color: Color {
        switch self {
        case .excellent: return Color(red: 0.20, green: 0.78, blue: 0.44)
        case .good:      return Color(red: 0.42, green: 0.75, blue: 0.28)
        case .fair:      return Color(red: 0.95, green: 0.72, blue: 0.16)
        case .weak:      return Color(red: 0.95, green: 0.49, blue: 0.15)
        case .poor:      return Color(red: 0.92, green: 0.27, blue: 0.27)
        }
    }

    /// Plain-language guidance shown next to the reading.
    var advice: String {
        switch self {
        case .excellent: return "Full performance. Ideal for any workload."
        case .good:      return "Solid. Video calls and large transfers are fine."
        case .fair:      return "Usable, but throughput is reduced. Watch for retries."
        case .weak:      return "Marginal. Expect stalls, slow transfers, dropped calls."
        case .poor:      return "Unreliable. Likely to disconnect or fail outright."
        }
    }
}

// MARK: - Radio enums (switched on rawValue so newer SDK cases stay safe)

enum Band: Int {
    case unknown = 0, ghz2 = 1, ghz5 = 2, ghz6 = 3

    var label: String {
        switch self {
        case .ghz2: return "2.4 GHz"
        case .ghz5: return "5 GHz"
        case .ghz6: return "6 GHz"
        case .unknown: return "Unknown"
        }
    }

    var short: String {
        switch self {
        case .ghz2: return "2.4G"
        case .ghz5: return "5G"
        case .ghz6: return "6E"
        case .unknown: return "?"
        }
    }

    var tint: Color {
        switch self {
        case .ghz2: return Color(red: 0.95, green: 0.62, blue: 0.20)
        case .ghz5: return Color(red: 0.28, green: 0.60, blue: 0.95)
        case .ghz6: return Color(red: 0.65, green: 0.42, blue: 0.95)
        case .unknown: return .gray
        }
    }
}

func bandLabel(_ raw: Int) -> Band { Band(rawValue: raw) ?? .unknown }

func channelWidthLabel(_ raw: Int) -> String {
    switch raw {
    case 1: return "20 MHz"
    case 2: return "40 MHz"
    case 3: return "80 MHz"
    case 4: return "160 MHz"
    case 5: return "320 MHz"
    default: return "Unknown"
    }
}

func phyModeLabel(_ raw: Int) -> String {
    switch raw {
    case 1: return "802.11a"
    case 2: return "802.11b"
    case 3: return "802.11g"
    case 4: return "802.11n (Wi-Fi 4)"
    case 5: return "802.11ac (Wi-Fi 5)"
    case 6: return "802.11ax (Wi-Fi 6/6E)"
    case 7: return "802.11be (Wi-Fi 7)"
    default: return "None"
    }
}

func securityLabel(_ raw: Int) -> String {
    switch raw {
    case 0:  return "Open (no encryption)"
    case 1:  return "WEP"
    case 2:  return "WPA Personal"
    case 3:  return "WPA/WPA2 Personal"
    case 4:  return "WPA2 Personal"
    case 5:  return "Personal"
    case 6:  return "Dynamic WEP"
    case 7:  return "WPA Enterprise"
    case 8:  return "WPA/WPA2 Enterprise"
    case 9:  return "WPA2 Enterprise"
    case 10: return "Enterprise"
    case 11: return "WPA3 Personal"
    case 12: return "WPA3 Enterprise"
    case 13: return "WPA2/WPA3 Transition"
    case 14: return "Enhanced Open (OWE)"
    case 15: return "OWE Transition"
    default: return "Unknown"
    }
}

/// True for security modes that carry no link-layer encryption.
func securityIsOpen(_ raw: Int) -> Bool { raw == 0 }

// MARK: - A single poll of the interface

struct WiFiSample: Identifiable, Codable {
    let id = UUID()
    let time: Date

    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var txRate: Double
    var txPower: Int
    var channel: Int
    var channelWidthRaw: Int
    var bandRaw: Int
    var phyRaw: Int
    var securityRaw: Int
    var countryCode: String?
    var interfaceName: String
    var hardwareAddress: String?

    /// `id` is view identity only and is regenerated on load, so it is left out
    /// of the encoding — at one sample per second it would be pure overhead.
    private enum CodingKeys: String, CodingKey {
        case time, ssid, bssid, rssi, noise, txRate, txPower, channel
        case channelWidthRaw, bandRaw, phyRaw, securityRaw, countryCode
        case interfaceName, hardwareAddress, apKey
    }

    /// Stable key identifying the AP this sample came from.
    ///
    /// Resolved once at capture rather than on demand: the chart regroups every
    /// sample into per-AP runs on each frame, and building this key's string
    /// thousands of times per redraw showed up as real cost.
    let apKey: APKey

    /// CoreWLAN reports zero when the noise floor is unavailable. Treat that as
    /// missing instead of turning it into a convincing but impossible SNR.
    var validNoise: Int? {
        guard noise < 0, noise >= -120 else { return nil }
        return noise
    }

    /// Signal-to-noise ratio in dB. Nil means the driver did not report noise.
    var snr: Int? { validNoise.map { rssi - $0 } }
    var quality: SignalQuality { SignalQuality(rssi: rssi) }
    var snrQuality: SignalQuality? { snr.map { SignalQuality(snr: $0) } }
    var band: Band { bandLabel(bandRaw) }

    init(time: Date, ssid: String?, bssid: String?, rssi: Int, noise: Int,
         txRate: Double, txPower: Int, channel: Int, channelWidthRaw: Int,
         bandRaw: Int, phyRaw: Int, securityRaw: Int, countryCode: String?,
         interfaceName: String, hardwareAddress: String?) {
        self.time = time
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.txRate = txRate
        self.txPower = txPower
        self.channel = channel
        self.channelWidthRaw = channelWidthRaw
        self.bandRaw = bandRaw
        self.phyRaw = phyRaw
        self.securityRaw = securityRaw
        self.countryCode = countryCode
        self.interfaceName = interfaceName
        self.hardwareAddress = hardwareAddress
        self.apKey = APKey(bssid: bssid, ssid: ssid, channel: channel,
                           bandRaw: bandRaw, phyRaw: phyRaw, securityRaw: securityRaw)
    }
}

// MARK: - Access point identity

/// Identifies an access point across the session and across app launches.
///
/// BSSID is the correct identifier and is used whenever macOS grants it. Without
/// Location Services the OS withholds BSSID, so we fall back to a radio
/// fingerprint. The fingerprint cannot tell apart two APs broadcasting the same
/// SSID on the same channel, which is called out in the UI wherever it is used.
struct APKey: Hashable, Codable {
    let raw: String
    let isPreciseIdentity: Bool

    init(bssid: String?, ssid: String?, channel: Int, bandRaw: Int, phyRaw: Int, securityRaw: Int) {
        if let b = bssid, !b.isEmpty {
            raw = "bssid:" + b.lowercased()
            isPreciseIdentity = true
        } else {
            let s = ssid ?? "?"
            raw = "fp:\(s)|ch\(channel)|b\(bandRaw)|p\(phyRaw)|s\(securityRaw)"
            isPreciseIdentity = false
        }
    }

    init(raw: String) {
        self.raw = raw
        self.isPreciseIdentity = raw.hasPrefix("bssid:")
    }

    var bssidValue: String? {
        guard raw.hasPrefix("bssid:") else { return nil }
        return String(raw.dropFirst("bssid:".count))
    }

    /// Deterministic palette slot, so an AP keeps its colour between launches.
    var colorIndex: Int {
        var h: UInt64 = 5381
        for byte in raw.utf8 { h = (h &* 33) &+ UInt64(byte) }
        return Int(h % UInt64(APPalette.colors.count))
    }

    var color: Color { APPalette.colors[colorIndex] }
}

enum APPalette {
    static let colors: [Color] = [
        Color(red: 0.30, green: 0.62, blue: 0.95), Color(red: 0.95, green: 0.45, blue: 0.35),
        Color(red: 0.35, green: 0.80, blue: 0.55), Color(red: 0.85, green: 0.55, blue: 0.95),
        Color(red: 0.98, green: 0.75, blue: 0.25), Color(red: 0.35, green: 0.82, blue: 0.85),
        Color(red: 0.95, green: 0.55, blue: 0.70), Color(red: 0.60, green: 0.75, blue: 0.30),
        Color(red: 0.55, green: 0.55, blue: 0.95), Color(red: 0.90, green: 0.65, blue: 0.40),
        Color(red: 0.40, green: 0.70, blue: 0.75), Color(red: 0.80, green: 0.40, blue: 0.55)
    ]
}

// MARK: - Roam events

struct RoamEvent: Identifiable, Codable {
    let id = UUID()
    let time: Date
    let fromKey: APKey?
    let toKey: APKey
    let fromRSSI: Int?
    let toRSSI: Int
    let fromChannel: Int?
    let toChannel: Int
    let reason: Reason

    private enum CodingKeys: String, CodingKey {
        case time, fromKey, toKey, fromRSSI, toRSSI, fromChannel, toChannel, reason
    }

    enum Reason: String, Codable {
        case initialAssociation
        case bssidChange
        case channelChange
        case reconnect
        case identityResolved

        var label: String {
            switch self {
            case .initialAssociation: return "Connected"
            case .bssidChange:        return "Roamed"
            case .channelChange:      return "Channel change"
            case .reconnect:          return "Reconnected"
            case .identityResolved:   return "Access point identified"
            }
        }

        var symbol: String {
            switch self {
            case .initialAssociation: return "link"
            case .bssidChange:        return "arrow.left.arrow.right"
            case .channelChange:      return "dial.medium"
            case .reconnect:          return "arrow.clockwise"
            case .identityResolved:   return "location.fill"
            }
        }

        var countsAsConnectionChange: Bool {
            switch self {
            case .initialAssociation, .identityResolved: return false
            default: return true
            }
        }
    }

    /// Signal delta across the transition; positive means the new AP is stronger.
    var delta: Int? { fromRSSI.map { toRSSI - $0 } }
}

// MARK: - Formatting helpers

enum Fmt {
    static func rate(_ mbps: Double) -> String {
        guard mbps > 0 else { return "—" }
        if mbps >= 1000 { return String(format: "%.1f Gbps", mbps / 1000) }
        return String(format: "%.0f Mbps", mbps)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = Swift.max(0, now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    static let clockShort: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    /// Shortened BSSID for dense UI, e.g. "…:9f:2a".
    static func shortMAC(_ mac: String) -> String {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return mac }
        return "…:\(parts[4]):\(parts[5])"
    }
}


// MARK: - Waypoints

/// A place the operator marked while walking a site.
///
/// The timestamp is taken the instant the shortcut is pressed, not when the
/// name is typed, so the label lands on the reading it describes rather than on
/// wherever the operator had walked to by the time they finished typing.
struct Waypoint: Identifiable, Codable, Hashable {
    var id = UUID()
    var time: Date
    var label: String
    var note: String = ""

    /// Signal at the moment the waypoint was dropped, filled in at capture.
    var rssi: Int?
    var snr: Int?
    var apKeyRaw: String?

    var apKey: APKey? { apKeyRaw.map(APKey.init(raw:)) }
}
