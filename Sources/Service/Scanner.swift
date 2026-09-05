import Foundation
import CoreWLAN
import Combine

/// One nearby BSS as reported by a scan.
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
    var snr: Int { noise != 0 ? rssi - noise : 0 }

    var key: APKey {
        APKey(bssid: bssid, ssid: ssid, channel: channel, bandRaw: bandRaw, phyRaw: 0, securityRaw: securityRaw)
    }
}

struct ChannelLoad: Identifiable {
    var channel: Int
    var band: Band
    var count: Int
    var id: String { "\(band.rawValue):\(channel)" }
}

/// Runs an explicit, user-initiated scan of nearby access points.
///
/// This is the one part of the app that transmits: a scan sends probe requests,
/// exactly as joining a network does. It never runs on its own — the operator
/// has to ask for it — so the app stays passive by default on a client site.
@MainActor
final class Scanner: ObservableObject {
    @Published private(set) var results: [ScanResult] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var errorMessage: String?

    private let queue = DispatchQueue(label: "wifi.scan", qos: .userInitiated)

    func scan(currentSSID: String?, currentBSSID: String?) {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil

        queue.async { [weak self] in
            var found: [ScanResult] = []
            var failure: String?

            if let iface = CWWiFiClient.shared().interface() {
                do {
                    let networks = try iface.scanForNetworks(withSSID: nil)
                    found = networks.map { n in
                        ScanResult(
                            ssid: n.ssid,
                            bssid: n.bssid,
                            rssi: n.rssiValue,
                            noise: n.noiseMeasurement,
                            channel: n.wlanChannel?.channelNumber ?? 0,
                            bandRaw: n.wlanChannel?.channelBand.rawValue ?? 0,
                            widthRaw: n.wlanChannel?.channelWidth.rawValue ?? 0,
                            securityRaw: Self.securityRaw(of: n),
                            isCurrentNetwork: currentSSID != nil && n.ssid == currentSSID,
                            isCurrentAP: currentBSSID != nil && n.bssid?.lowercased() == currentBSSID?.lowercased()
                        )
                    }
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                failure = "No Wi-Fi interface available."
            }

            let sorted = found.sorted { $0.rssi > $1.rssi }
            Task { @MainActor in
                guard let self else { return }
                self.errorMessage = failure
                self.isScanning = false
                if failure == nil {
                    self.results = sorted
                    self.lastScan = Date()
                }
            }
        }
    }

    /// CWNetwork exposes security only through a predicate, so probe the modes.
    private nonisolated static func securityRaw(of n: CWNetwork) -> Int {
        let candidates: [CWSecurity] = [
            .none, .WEP, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal,
            .dynamicWEP, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise,
            .wpa3Personal, .wpa3Enterprise, .wpa3Transition
        ]
        for c in candidates where n.supportsSecurity(c) { return c.rawValue }
        return Int(Int32.max)
    }

    /// Other radios advertising the SSID we are on — the roam candidates.
    func roamCandidates(for ssid: String?, currentBSSID: String?) -> [ScanResult] {
        guard let ssid else { return [] }
        return results.filter {
            guard $0.ssid == ssid else { return false }
            guard let currentBSSID else { return !$0.isCurrentAP }
            return $0.bssid?.caseInsensitiveCompare(currentBSSID) != .orderedSame
        }
    }

    /// Count of BSSes per channel, to show where the congestion is.
    func channelLoad() -> [ChannelLoad] {
        struct ChannelKey: Hashable { var channel: Int; var bandRaw: Int }
        var buckets: [ChannelKey: Int] = [:]
        for r in results where r.channel > 0 {
            let key = ChannelKey(channel: r.channel, bandRaw: r.band.rawValue)
            buckets[key, default: 0] += 1
        }
        return buckets
            .map { ChannelLoad(channel: $0.key.channel, band: bandLabel($0.key.bandRaw), count: $0.value) }
            .sorted { $0.count == $1.count ? $0.channel < $1.channel : $0.count > $1.count }
    }
}
