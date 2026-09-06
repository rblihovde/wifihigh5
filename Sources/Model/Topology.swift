import Foundation
import SwiftUI

/// The source confidence for a node or path.
///
/// Identifies whether map data is measured, inferred, or unobserved.
/// The map includes unobserved paths so it does not appear complete.
enum Confidence: Equatable {
    case observed      // read directly from the system
    case inferred      // derived from observed facts, stated as such
    case unobserved    // not visible to this app

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

/// Zoom band at which a fact appears.
enum Detail: Int, Comparable {
    case primary = 0     // always visible once the node is legible
    case secondary = 1   // mid zoom
    case full = 2        // close inspection

    static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
}

struct Fact: Identifiable {
    var id: String
    var label: String
    var value: String
    var detail: Detail = .secondary
    var tint: Color?
    /// Sentence-length explanations that would overflow a node plate. They are
    /// kept for the inspector, where there is room to read them.
    var inspectorOnly = false
    /// Optional evidence metadata. It stays out of the canvas and appears only
    /// in the inspector, so operators can audit a claim without cluttering the
    /// normal view.
    var confidence: Confidence?
    var source: String?
    var observedAt: Date?
    var staleAfter: TimeInterval?

    init(id: String? = nil, label: String, value: String,
         detail: Detail = .secondary, tint: Color? = nil,
         inspectorOnly: Bool = false, confidence: Confidence? = nil,
         source: String? = nil, observedAt: Date? = nil,
         staleAfter: TimeInterval? = nil) {
        self.id = id ?? label
        self.label = label
        self.value = value
        self.detail = detail
        self.tint = tint
        self.inspectorOnly = inspectorOnly
        self.confidence = confidence
        self.source = source
        self.observedAt = observedAt
        self.staleAfter = staleAfter
    }

    func isStale(at date: Date = Date()) -> Bool {
        guard let observedAt, let staleAfter else { return false }
        return date.timeIntervalSince(observedAt) > staleAfter
    }
}

enum NodeKind {
    case internet, router, accessPoint, accessPointGroup, switchFabric, thisMac, neighbours

    var glyphTitle: String {
        switch self {
        case .internet: return "Internet"
        case .router: return "Router"
        case .accessPoint: return "Access point"
        case .accessPointGroup: return "Access point group"
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

    /// Assembles the map from observed network data.
    @MainActor
    static func build(sample: WiFiSample?,
                      status: LinkStatus,
                      ip: IPConfig,
                      arp: [ARPEntry],
                      scan: [ScanResult],
                      ipObservedAt: Date? = nil,
                      arpObservedAt: Date? = nil,
                      scanObservedAt: Date? = nil,
                      registry: APRegistry,
                      pinger: GatewayPinger,
                      vendors: VendorDatabase) -> NetworkMap {
        var map = NetworkMap()

        let gatewayIP = ip.router
        let activeInterface = sample?.interfaceName ?? ip.primaryInterface
        let interfaceARP = arp.filter { entry in
            guard let activeInterface, let owner = entry.interfaceName else { return true }
            return owner == activeInterface
        }
        let gatewayEntry = gatewayIP.flatMap { g in interfaceARP.first { $0.ip == g } }
        let apBSSID = sample?.bssid?.lowercased()
        let alternatePrimaryInterface: String? = {
            guard let activeInterface, let primary = ip.primaryInterface,
                  primary != activeInterface else { return nil }
            return primary
        }()

        // Router and access point in one box is the common small-site case, and
        // the MAC layout is what reveals it.
        let sameChassis: Bool = {
            guard let g = gatewayEntry?.mac, let b = apBSSID else { return false }
            return ARPTable.likelySameChassis(g, b)
        }()

        // MARK: Internet

        var internetFacts = [
            Fact(label: "Reachability", value: pinger.enabled ? "Gateway only" : "Not tested", detail: .primary),
            Fact(label: "Why", value: "The app communicates only with the local router. It does not test anything upstream.", detail: .secondary, inspectorOnly: true)
        ]
        if let primary = alternatePrimaryInterface {
            internetFacts.insert(
                Fact(label: "Default route", value: "Uses \(primary), outside this Wi-Fi path",
                     detail: .primary, tint: .orange, confidence: .observed,
                     source: "macOS network configuration",
                     observedAt: ipObservedAt, staleAfter: 15), at: 0)
        }
        map.nodes.append(MapNode(
            id: "internet", kind: .internet, title: "Internet",
            subtitle: "Beyond the Wi-Fi gateway",
            facts: internetFacts,
            confidence: .unobserved, column: 0, row: 0))

        // MARK: Router

        var routerFacts: [Fact] = []
        if let g = gatewayIP {
            routerFacts.append(Fact(label: "Address", value: g, detail: .primary,
                                    confidence: .observed,
                                    source: "macOS network configuration",
                                    observedAt: ipObservedAt, staleAfter: 15))
        }
        if let mac = gatewayEntry?.mac {
            routerFacts.append(Fact(label: "MAC", value: mac, detail: .primary,
                                    confidence: .observed,
                                    source: "Local ARP cache · \(gatewayEntry?.interfaceName ?? activeInterface ?? "active interface")",
                                    observedAt: arpObservedAt, staleAfter: 15))
            let vendor = vendors.lookup(mac)
            if case .known(let name) = vendor {
                routerFacts.insert(Fact(label: "Vendor", value: name, detail: .primary,
                                        confidence: .inferred,
                                        source: "Bundled IEEE assignment database"), at: 0)
            } else if let label = vendor.displayName {
                routerFacts.append(Fact(label: "Vendor", value: label, detail: .secondary,
                                        tint: .orange, confidence: .inferred,
                                        source: "Bundled IEEE assignment database"))
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
                                    tint: pinger.lastRTT == nil ? .red : nil,
                                    confidence: .observed,
                                    source: "Optional gateway ping",
                                    observedAt: pinger.history.last?.0, staleAfter: 3))
            routerFacts.append(Fact(label: "Packet loss",
                                    value: String(format: "%.1f%%", pinger.lossPercent),
                                    detail: .primary,
                                    tint: pinger.lossPercent > 2 ? .red : nil,
                                    confidence: .inferred,
                                    source: "Optional gateway ping history",
                                    observedAt: pinger.history.last?.0, staleAfter: 3))
        }

        map.nodes.append(MapNode(
            id: "router", kind: .router,
            title: "Router",
            subtitle: gatewayIP,
            facts: routerFacts,
            confidence: gatewayIP != nil ? .observed : .inferred,
            column: 0, row: 1))

        map.edges.append(MapEdge(id: "wan", from: "internet", to: "router",
                                 kind: .wan,
                                 facts: [Fact(label: "Link", value: "Not visible", detail: .primary)],
                                 confidence: .unobserved,
                                 caption: "not tested"))

        // MARK: The path between router and access point

        let apRow: Double = 3
        if !sameChassis, sample != nil, status == .connected {
            // Switches and controllers live here and are invisible at layer 3.
            map.nodes.append(MapNode(
                id: "fabric", kind: .switchFabric,
                title: "Unobserved path",
                subtitle: "Switching between router and AP",
                facts: [
                    Fact(label: "What's here", value: "Any switches, controllers or uplinks between the access point and the router.", detail: .primary, inspectorOnly: true),
                    Fact(label: "Why unknown", value: "These operate below the layer this Mac can see. Detection requires LLDP, CDP, or switch access. This app does not use those sources.", detail: .secondary, inspectorOnly: true)
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
                Fact(label: "Signal", value: "\(s.rssi) dBm", detail: .primary,
                     tint: s.quality.color, confidence: .observed,
                     source: "Current Wi-Fi link", observedAt: s.time, staleAfter: 5),
                Fact(label: "Quality", value: s.quality.label, detail: .primary,
                     tint: s.quality.color, confidence: .inferred,
                     source: "Derived from current signal", observedAt: s.time, staleAfter: 5)
            ]
            if let snr = s.snr {
                apFacts.append(Fact(label: "Clarity (SNR)", value: "\(snr) dB", detail: .primary,
                                    tint: s.snrQuality?.color, confidence: .inferred,
                                    source: "Signal minus reported noise",
                                    observedAt: s.time, staleAfter: 5))
            }
            apFacts.append(Fact(label: "BSSID", value: s.bssid ?? "Withheld",
                                detail: .primary, tint: s.bssid == nil ? .orange : nil,
                                confidence: .observed, source: "Current Wi-Fi link",
                                observedAt: s.time, staleAfter: 5))
            if let bssid = s.bssid {
                let vendor = vendors.lookup(bssid)
                if case .known(let name) = vendor {
                    apFacts.append(Fact(label: "Vendor", value: name, detail: .primary,
                                        confidence: .inferred,
                                        source: "Bundled IEEE assignment database"))
                } else if let label = vendor.displayName {
                    apFacts.append(Fact(label: "Vendor", value: label, detail: .secondary,
                                        tint: .orange, confidence: .inferred,
                                        source: "Bundled IEEE assignment database"))
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
                apFacts.append(Fact(label: "Likely shared chassis",
                                    value: "Router \(gatewayEntry?.mac ?? "—") and radio \(s.bssid ?? "—") share their first five octets and are within eight addresses. That often means one physical box, but only equipment inventory can confirm it.",
                                    detail: .secondary, tint: .orange, inspectorOnly: true,
                                    confidence: .inferred,
                                    source: "Compared gateway ARP entry with connected BSSID",
                                    observedAt: arpObservedAt.map { min(s.time, $0) } ?? s.time,
                                    staleAfter: 15))
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
                                         caption: "likely one device"))
            }

            // MARK: This Mac

            var macFacts: [Fact] = [
                Fact(label: "Address", value: ip.ipv4 ?? "—", detail: .primary,
                     confidence: .observed, source: "macOS network configuration",
                     observedAt: ipObservedAt, staleAfter: 15),
                Fact(label: "Interface", value: s.interfaceName, detail: .secondary,
                     confidence: .observed, source: "Current Wi-Fi link",
                     observedAt: s.time, staleAfter: 5)
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

        let matchingPeers = scan.filter { r in
            guard let ssid = sample?.ssid, r.ssid == ssid else { return false }
            return r.bssid?.lowercased() != apBSSID
        }
        // CoreWLAN can occasionally return the same BSSID twice during a roam.
        // Keep the strongest copy so node identity and selection remain stable.
        var bestPeerByKey: [APKey: ScanResult] = [:]
        for peer in matchingPeers where peer.rssi > (bestPeerByKey[peer.key]?.rssi ?? Int.min) {
            bestPeerByKey[peer.key] = peer
        }
        let peers = bestPeerByKey.values.sorted {
            $0.rssi == $1.rssi ? $0.key.raw < $1.key.raw : $0.rssi > $1.rssi
        }
        let branchNode = sameChassis ? "router" : (map.node("fabric") == nil ? "router" : "fabric")
        let peerRow = sameChassis ? 2.0 : apRow
        let scanAge = scanObservedAt.map { Fmt.relativeTime($0, now: map.generated) } ?? "Time unavailable"
        let scanIsStale = scanObservedAt.map { map.generated.timeIntervalSince($0) > 120 } ?? !scan.isEmpty

        if let peer = peers.first {
            let id = "peer-\(peer.key.raw)"
            map.nodes.append(MapNode(
                id: id, kind: .accessPoint,
                title: registry.nickname(for: peer.key) ?? (peer.bssid.map(Fmt.shortMAC) ?? "Peer AP"),
                subtitle: "Same network · not connected",
                facts: [
                    Fact(label: "Scanned signal", value: "\(peer.rssi) dBm", detail: .primary,
                         tint: peer.quality.color, confidence: .observed,
                         source: "User-initiated nearby-network scan",
                         observedAt: scanObservedAt, staleAfter: 120),
                    Fact(label: "Scan age", value: scanAge, detail: .primary,
                         tint: scanIsStale ? .orange : nil,
                         confidence: .observed, source: "Nearby-network scan",
                         observedAt: scanObservedAt, staleAfter: 120),
                    Fact(label: "BSSID", value: peer.bssid ?? "—", detail: .secondary),
                    Fact(label: "Channel", value: "\(peer.channel) · \(peer.band.label)", detail: .secondary),
                    Fact(label: "Role", value: "A radio you could roam to. Its path back to the router is not visible from here.", detail: .secondary, inspectorOnly: true)
                ],
                confidence: .observed,
                column: 1.15,
                row: peerRow,
                accent: registry.color(for: peer.key)))

            map.edges.append(MapEdge(id: "peer-link-\(peer.key.raw)",
                                     from: branchNode,
                                     to: id, kind: .unobserved,
                                     confidence: .unobserved,
                                     caption: "path unknown"))
        }

        let additionalPeers = Array(peers.dropFirst())
        if !additionalPeers.isEmpty {
            let shown = min(additionalPeers.count, 12)
            var facts: [Fact] = [
                Fact(label: "Count", value: "\(additionalPeers.count)", detail: .primary),
                Fact(label: "Scan age", value: scanAge, detail: .primary,
                     tint: scanIsStale ? .orange : nil,
                     confidence: .observed, source: "Nearby-network scan",
                     observedAt: scanObservedAt, staleAfter: 120),
                Fact(label: "Showing", value: "\(shown) of \(additionalPeers.count)", detail: .secondary)
            ]
            for peer in additionalPeers.prefix(shown) {
                let name = registry.nickname(for: peer.key) ?? (peer.bssid.map(Fmt.shortMAC) ?? "Peer AP")
                facts.append(Fact(id: "peer-\(peer.key.raw)", label: name,
                                  value: "\(peer.rssi) dBm · ch \(peer.channel)",
                                  detail: .full, tint: peer.quality.color,
                                  confidence: .observed,
                                  source: "User-initiated nearby-network scan",
                                  observedAt: scanObservedAt, staleAfter: 120))
            }
            if additionalPeers.count > shown {
                facts.append(Fact(label: "Not listed", value: "\(additionalPeers.count - shown)",
                                  detail: .full, tint: .orange))
            }
            map.nodes.append(MapNode(
                id: "peer-group", kind: .accessPointGroup,
                title: "\(additionalPeers.count) more access point\(additionalPeers.count == 1 ? "" : "s")",
                subtitle: "Same network · scan results",
                facts: facts, confidence: .observed,
                column: 2.3, row: peerRow))
            map.edges.append(MapEdge(id: "peer-group-link", from: branchNode,
                                     to: "peer-group", kind: .unobserved,
                                     confidence: .unobserved, caption: "paths unknown"))
        }

        // MARK: Other devices already known to this Mac

        let neighbours = ARPTable.devicesOnActiveSubnet(
            interfaceARP,
            interface: activeInterface,
            localAddress: ip.ipv4,
            mask: ip.subnetMask
        ).filter { $0.ip != gatewayIP }
        if !neighbours.isEmpty {
            let shown = min(neighbours.count, 14)
            var facts: [Fact] = [
                Fact(label: "Cached", value: "\(neighbours.count)", detail: .primary,
                     confidence: .observed, source: "Local ARP cache",
                     observedAt: arpObservedAt, staleAfter: 15),
                Fact(label: "Showing", value: "\(shown) of \(neighbours.count)", detail: .secondary),
                Fact(label: "Scope", value: "IPv4 · \(activeInterface ?? "active interface") · local subnet", detail: .secondary),
                Fact(label: "How", value: "Read from this Mac's own ARP cache on the active Wi-Fi subnet. These entries came from earlier traffic; the app did not sweep or probe the network.", detail: .secondary, inspectorOnly: true)
            ]
            for n in neighbours.prefix(shown) {
                let vendor = vendors.lookup(n.mac)
                facts.append(Fact(label: n.ip,
                                  value: vendor.displayName ?? n.mac,
                                  detail: .full,
                                  tint: vendor == .randomised ? .orange : nil,
                                  confidence: vendor.displayName == nil ? .observed : .inferred,
                                  source: vendor.displayName == nil ? "Local ARP cache" : "Local ARP cache · bundled IEEE lookup",
                                  observedAt: arpObservedAt, staleAfter: 15))
            }
            if neighbours.count > shown {
                facts.append(Fact(label: "Not listed", value: "\(neighbours.count - shown)",
                                  detail: .full, tint: .orange))
            }
            // The identified count helps distinguish hardware from randomized addresses.
            let named = neighbours.filter { if case .known = vendors.lookup($0.mac) { return true } else { return false } }.count
            facts.insert(Fact(label: "Identified", value: "\(named) of \(neighbours.count)", detail: .secondary), at: 1)
            map.nodes.append(MapNode(
                id: "neighbours", kind: .neighbours,
                title: "Other IPv4 devices",
                subtitle: "\(neighbours.count) cached on this subnet",
                facts: facts, confidence: .observed,
                column: -1.15, row: peerRow))
            map.edges.append(MapEdge(id: "router-neighbours", from: branchNode, to: "neighbours",
                                     kind: .unobserved, confidence: .unobserved,
                                     caption: "paths unknown"))
        }

        if status == .connected, sample?.ssid != nil {
            if scan.isEmpty {
                map.notes.append("Use Find access points in this toolbar to add other radios serving the current network.")
            } else if peers.isEmpty {
                map.notes.append("The last nearby-network scan found no other access points advertising the current network name. Refresh after moving to update that result.")
            }
        }
        if sample?.bssid == nil, status == .connected {
            map.notes.append("Without Location Services the access point cannot be identified by BSSID, so router-and-AP-in-one-box cannot be confirmed.")
        }
        if sample?.ssid == nil, status == .connected {
            map.notes.append("macOS is withholding the network name, so a nearby scan cannot safely decide which radios serve this connection.")
        }
        if !ip.ipv6.isEmpty {
            map.notes.append("The device group currently reflects the IPv4 ARP cache only; IPv6 neighbours are not included.")
        }
        if let primary = alternatePrimaryInterface, let activeInterface {
            map.notes.append("macOS reports \(primary) as the default route. This diagram shows the local Wi-Fi path on \(activeInterface); a VPN or another adapter may carry Internet traffic.")
        }
        return map
    }
}
