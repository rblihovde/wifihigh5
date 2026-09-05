import Foundation
import SwiftUI

/// How much is actually known about a node or a path.
///
/// The map is only worth drawing if it distinguishes what was measured from
/// what was reasoned and from what cannot be seen at all. Anything the app
/// cannot observe is drawn as unobserved rather than quietly omitted, because a
/// diagram that looks complete when it isn't is worse than no diagram.
enum Confidence {
    case observed      // read directly from the system
    case inferred      // derived from observed facts, stated as such
    case unobserved    // genuinely not visible to this app

    var label: String {
        switch self {
        case .observed: return "Measured"
        case .inferred: return "Inferred"
        case .unobserved: return "Not observable"
        }
    }

    var tint: Color {
        switch self {
        case .observed: return Color(red: 0.36, green: 0.72, blue: 0.98)
        case .inferred: return Color(red: 0.95, green: 0.72, blue: 0.25)
        case .unobserved: return Color(white: 0.55)
        }
    }
}

/// Zoom band at which a fact becomes worth showing.
enum Detail: Int, Comparable {
    case primary = 0     // always visible once the node is legible
    case secondary = 1   // mid zoom
    case full = 2        // close inspection

    static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
}

struct Fact: Identifiable {
    let id = UUID()
    var label: String
    var value: String
    var detail: Detail = .secondary
    var tint: Color?
    /// Sentence-length explanations that would overflow a node plate. They are
    /// kept for the inspector, where there is room to read them.
    var inspectorOnly = false
}

enum NodeKind {
    case internet, router, accessPoint, switchFabric, thisMac, neighbours

    var glyphTitle: String {
        switch self {
        case .internet: return "Internet"
        case .router: return "Router"
        case .accessPoint: return "Access point"
        case .switchFabric: return "Unobserved path"
        case .thisMac: return "This Mac"
        case .neighbours: return "Other devices"
        }
    }
}

struct MapNode: Identifiable {
    var id: String
    var kind: NodeKind
    var title: String
    var subtitle: String?
    var facts: [Fact] = []
    var confidence: Confidence = .observed
    /// Grid position: column, row. Layout is on a lattice so connectors stay
    /// orthogonal, the way a schematic is drawn.
    var column: Double
    var row: Double
    var accent: Color?
}

enum EdgeKind {
    case wireless, wired, wan, sameChassis, unobserved

    var label: String {
        switch self {
        case .wireless: return "Wi-Fi"
        case .wired: return "Wired"
        case .wan: return "WAN"
        case .sameChassis: return "Same chassis"
        case .unobserved: return "Unobserved"
        }
    }
}

struct MapEdge: Identifiable {
    var id: String
    var from: String
    var to: String
    var kind: EdgeKind
    var facts: [Fact] = []
    var confidence: Confidence = .observed
    var caption: String?
}

struct NetworkMap {
    var nodes: [MapNode] = []
    var edges: [MapEdge] = []
    var generated = Date()
    var notes: [String] = []

    func node(_ id: String) -> MapNode? { nodes.first { $0.id == id } }
}

// MARK: - Construction

enum TopologyBuilder {

    /// Assembles the map from what the app has actually observed.
    @MainActor
    static func build(sample: WiFiSample?,
                      status: LinkStatus,
                      ip: IPConfig,
                      arp: [ARPEntry],
                      scan: [ScanResult],
                      registry: APRegistry,
                      pinger: GatewayPinger,
                      vendors: VendorDatabase) -> NetworkMap {
        var map = NetworkMap()

        let gatewayIP = ip.router
        let gatewayEntry = gatewayIP.flatMap { g in arp.first { $0.ip == g } }
        let apBSSID = sample?.bssid?.lowercased()

        // Router and access point in one box is the common small-site case, and
        // the MAC layout is what reveals it.
        let sameChassis: Bool = {
            guard let g = gatewayEntry?.mac, let b = apBSSID else { return false }
            return ARPTable.likelySameChassis(g, b)
        }()

        // MARK: Internet

        map.nodes.append(MapNode(
            id: "internet", kind: .internet, title: "Internet",
            subtitle: "Beyond the gateway",
            facts: [
                Fact(label: "Reachability", value: pinger.enabled ? "Gateway only" : "Not tested", detail: .primary),
                Fact(label: "Why", value: "This app only ever talks to your own router, so anything upstream is outside what it can honestly report.", detail: .secondary, inspectorOnly: true)
            ],
            confidence: .unobserved, column: 0, row: 0))

        // MARK: Router

        var routerFacts: [Fact] = []
        if let g = gatewayIP {
            routerFacts.append(Fact(label: "Address", value: g, detail: .primary))
        }
        if let mac = gatewayEntry?.mac {
            routerFacts.append(Fact(label: "MAC", value: mac, detail: .primary))
            let vendor = vendors.lookup(mac)
            if case .known(let name) = vendor {
                routerFacts.insert(Fact(label: "Vendor", value: name, detail: .primary), at: 0)
            } else if let label = vendor.displayName {
                routerFacts.append(Fact(label: "Vendor", value: label, detail: .secondary, tint: .orange))
            }
            routerFacts.append(Fact(label: "Vendor prefix", value: gatewayEntry!.oui, detail: .full))
            if gatewayEntry!.isLocallyAdministered {
                routerFacts.append(Fact(label: "Address type", value: "Locally administered", detail: .full, tint: .orange))
            }
        } else {
            routerFacts.append(Fact(label: "MAC", value: "Not in this Mac's ARP cache", detail: .secondary, tint: .orange))
        }
        if let dhcp = ip.dhcpServer {
            routerFacts.append(Fact(label: "DHCP server",
                                    value: dhcp == gatewayIP ? "\(dhcp) — same device" : dhcp,
                                    detail: .secondary))
        }
        if !ip.dnsServers.isEmpty {
            let dns = ip.dnsServers.joined(separator: ", ")
            routerFacts.append(Fact(label: "DNS", value: dns == gatewayIP ? "\(dns) — same device" : dns, detail: .secondary))
        }
        if let expiry = ip.leaseExpiry {
            routerFacts.append(Fact(label: "Lease expires", value: Fmt.stamp.string(from: expiry), detail: .full))
        }
        if pinger.enabled, pinger.completed > 0 {
            routerFacts.append(Fact(label: "Latency",
                                    value: pinger.lastRTT.map { String(format: "%.1f ms", $0) } ?? "timeout",
                                    detail: .primary,
                                    tint: pinger.lastRTT == nil ? .red : nil))
            routerFacts.append(Fact(label: "Packet loss",
                                    value: String(format: "%.1f%%", pinger.lossPercent),
                                    detail: .primary,
                                    tint: pinger.lossPercent > 2 ? .red : nil))
        }

        map.nodes.append(MapNode(
            id: "router", kind: .router,
            title: sameChassis ? "Router + access point" : "Router",
            subtitle: gatewayIP,
            facts: routerFacts,
            confidence: gatewayEntry != nil ? .observed : .inferred,
            column: 0, row: 1))

        map.edges.append(MapEdge(id: "wan", from: "internet", to: "router",
                                 kind: .wan,
                                 facts: [Fact(label: "Link", value: "Not visible", detail: .primary)],
                                 confidence: .unobserved,
                                 caption: "not tested"))

        // MARK: The path between router and access point

        let apRow: Double = 3
        if !sameChassis, apBSSID != nil {
            // Switches and controllers live here and are invisible at layer 3.
            map.nodes.append(MapNode(
                id: "fabric", kind: .switchFabric,
                title: "Unobserved path",
                subtitle: "Switching between router and AP",
                facts: [
                    Fact(label: "What's here", value: "Any switches, controllers or uplinks between the access point and the router.", detail: .primary, inspectorOnly: true),
                    Fact(label: "Why unknown", value: "These operate below the layer this Mac can see. Revealing them needs LLDP, CDP or switch access — none of which this app does.", detail: .secondary, inspectorOnly: true)
                ],
                confidence: .unobserved, column: 0, row: 2))
            map.edges.append(MapEdge(id: "router-fabric", from: "router", to: "fabric",
                                     kind: .unobserved, confidence: .unobserved))
            map.edges.append(MapEdge(id: "fabric-ap", from: "fabric", to: "ap",
                                     kind: .unobserved, confidence: .unobserved))
        }

        // MARK: Connected access point

        if let s = sample, status == .connected {
            let key = s.apKey
            var apFacts: [Fact] = [
                Fact(label: "Signal", value: "\(s.rssi) dBm", detail: .primary, tint: s.quality.color),
                Fact(label: "Quality", value: s.quality.label, detail: .primary, tint: s.quality.color)
            ]
            if let snr = s.snr {
                apFacts.append(Fact(label: "Clarity (SNR)", value: "\(snr) dB", detail: .primary,
                                    tint: s.snrQuality?.color))
            }
            apFacts.append(Fact(label: "BSSID", value: s.bssid ?? "Withheld",
                                detail: .primary, tint: s.bssid == nil ? .orange : nil))
            if let bssid = s.bssid {
                let vendor = vendors.lookup(bssid)
                if case .known(let name) = vendor {
                    apFacts.append(Fact(label: "Vendor", value: name, detail: .primary))
                } else if let label = vendor.displayName {
                    apFacts.append(Fact(label: "Vendor", value: label, detail: .secondary, tint: .orange))
                }
            }
            apFacts.append(Fact(label: "Network", value: s.ssid ?? "Withheld", detail: .secondary))
            apFacts.append(Fact(label: "Channel", value: "\(s.channel) · \(s.band.label)", detail: .secondary))
            apFacts.append(Fact(label: "Width", value: channelWidthLabel(s.channelWidthRaw), detail: .secondary))
            apFacts.append(Fact(label: "Standard", value: phyModeLabel(s.phyRaw), detail: .secondary))
            apFacts.append(Fact(label: "Security", value: securityLabel(s.securityRaw), detail: .secondary,
                                tint: securityIsOpen(s.securityRaw) ? .red : nil))
            if let noise = s.validNoise {
                apFacts.append(Fact(label: "Noise floor", value: "\(noise) dBm", detail: .full))
            }
            apFacts.append(Fact(label: "Negotiated rate", value: Fmt.rate(s.txRate), detail: .full))
            if let country = s.countryCode {
                apFacts.append(Fact(label: "Regulatory domain", value: country, detail: .full))
            }
            if sameChassis {
                apFacts.append(Fact(label: "Chassis",
                                    value: "MAC sits beside the router's, so this radio is almost certainly inside the same box.",
                                    detail: .secondary, tint: .orange, inspectorOnly: true))
            }

            map.nodes.append(MapNode(
                id: "ap", kind: .accessPoint,
                title: registry.displayName(for: key, fallbackChannel: s.channel, fallbackBand: s.bandRaw),
                subtitle: s.ssid,
                facts: apFacts,
                confidence: .observed,
                column: 0, row: sameChassis ? 2 : apRow,
                accent: registry.color(for: key)))

            if sameChassis {
                map.edges.append(MapEdge(id: "router-ap", from: "router", to: "ap",
                                         kind: .sameChassis,
                                         facts: [Fact(label: "Evidence", value: "Router MAC \(gatewayEntry?.mac ?? "") and BSSID \(s.bssid ?? "") differ only in the final octet.", detail: .secondary, inspectorOnly: true)],
                                         confidence: .inferred,
                                         caption: "one device"))
            }

            // MARK: This Mac

            var macFacts: [Fact] = [
                Fact(label: "Address", value: ip.ipv4 ?? "—", detail: .primary),
                Fact(label: "Interface", value: s.interfaceName, detail: .secondary)
            ]
            if let active = ip.activeMAC {
                macFacts.append(Fact(label: "MAC on the wire", value: active, detail: .secondary))
                if case .randomised = vendors.lookup(active) {
                    macFacts.append(Fact(label: "Wire address", value: "Software-assigned", detail: .full, tint: .blue))
                }
            }
            if let hw = s.hardwareAddress {
                macFacts.append(Fact(label: "Hardware MAC", value: hw, detail: .full))
            }
            if SystemNetwork.usingPrivateAddress(hardware: s.hardwareAddress, active: ip.activeMAC) {
                macFacts.append(Fact(label: "Private address",
                                     value: "On", detail: .secondary, tint: .blue))
            }
            if let mask = ip.subnetMask {
                macFacts.append(Fact(label: "Subnet mask", value: mask, detail: .full))
            }

            map.nodes.append(MapNode(
                id: "mac", kind: .thisMac, title: "This Mac",
                subtitle: ip.ipv4,
                facts: macFacts, confidence: .observed,
                column: 0, row: (sameChassis ? 2 : apRow) + 1))

            var linkFacts: [Fact] = [
                Fact(label: "Signal", value: "\(s.rssi) dBm", detail: .primary, tint: s.quality.color),
                Fact(label: "Rate", value: Fmt.rate(s.txRate), detail: .primary),
                Fact(label: "Band", value: "\(s.band.label) · channel \(s.channel)", detail: .secondary),
                Fact(label: "Width", value: channelWidthLabel(s.channelWidthRaw), detail: .full)
            ]
            if let snr = s.snr {
                linkFacts.insert(Fact(label: "Clarity", value: "\(snr) dB", detail: .primary,
                                      tint: s.snrQuality?.color), at: 1)
            }
            map.edges.append(MapEdge(id: "ap-mac", from: "ap", to: "mac",
                                     kind: .wireless, facts: linkFacts,
                                     confidence: .observed,
                                     caption: "\(s.rssi) dBm · \(Fmt.rate(s.txRate))"))
        }

        // MARK: Peer access points found by a scan

        let peers = scan.filter { r in
            guard let ssid = sample?.ssid, r.ssid == ssid else { return false }
            return r.bssid?.lowercased() != apBSSID
        }.sorted { $0.rssi > $1.rssi }

        for (i, peer) in peers.prefix(4).enumerated() {
            let id = "peer-\(i)"
            map.nodes.append(MapNode(
                id: id, kind: .accessPoint,
                title: registry.nickname(for: peer.key) ?? (peer.bssid.map(Fmt.shortMAC) ?? "Peer AP"),
                subtitle: "Same network, not associated",
                facts: [
                    Fact(label: "Signal here", value: "\(peer.rssi) dBm", detail: .primary, tint: peer.quality.color),
                    Fact(label: "BSSID", value: peer.bssid ?? "—", detail: .primary),
                    Fact(label: "Channel", value: "\(peer.channel) · \(peer.band.label)", detail: .secondary),
                    Fact(label: "Role", value: "A radio you could roam to. Its path back to the router is not visible from here.", detail: .secondary, inspectorOnly: true)
                ],
                confidence: .observed,
                column: Double(i + 1) * 1.15 + 0.35,
                row: sameChassis ? 2 : apRow,
                accent: registry.color(for: peer.key)))

            map.edges.append(MapEdge(id: "peer-link-\(i)",
                                     from: sameChassis ? "router" : "fabric",
                                     to: id, kind: .unobserved,
                                     confidence: .unobserved,
                                     caption: "path unknown"))
        }

        // MARK: Other devices already known to this Mac

        let neighbours = arp.filter { $0.ip != gatewayIP }
        if !neighbours.isEmpty {
            var facts: [Fact] = [
                Fact(label: "Count", value: "\(neighbours.count)", detail: .primary),
                Fact(label: "How", value: "Read from this Mac's own ARP cache. These hosts were learned from traffic that already happened — nothing was scanned or probed.", detail: .secondary, inspectorOnly: true)
            ]
            for n in neighbours.prefix(14) {
                let vendor = vendors.lookup(n.mac)
                facts.append(Fact(label: n.ip,
                                  value: vendor.displayName ?? n.mac,
                                  detail: .full,
                                  tint: vendor == .randomised ? .orange : nil))
            }
            // A count of how many neighbours could actually be identified says
            // something useful on its own: lots of randomised addresses means a
            // guest network or privacy-conscious clients.
            let named = neighbours.filter { if case .known = vendors.lookup($0.mac) { return true } else { return false } }.count
            facts.insert(Fact(label: "Identified", value: "\(named) of \(neighbours.count)", detail: .secondary), at: 1)
            map.nodes.append(MapNode(
                id: "neighbours", kind: .neighbours,
                title: "Other devices",
                subtitle: "\(neighbours.count) seen",
                facts: facts, confidence: .observed,
                column: -1.35, row: sameChassis ? 2 : apRow))
            map.edges.append(MapEdge(id: "router-neighbours", from: "router", to: "neighbours",
                                     kind: .unobserved, confidence: .unobserved,
                                     caption: "paths unknown"))
        }

        if scan.isEmpty {
            map.notes.append("Run a scan from Nearby Networks to add the other access points serving this network.")
        }
        if sample?.bssid == nil, status == .connected {
            map.notes.append("Without Location Services the access point cannot be identified by BSSID, so router-and-AP-in-one-box cannot be confirmed.")
        }
        return map
    }
}
