import Foundation

/// Assembles the device rows from the passive cache and whatever else is known.
///
/// This lives outside the view because the exported report has to show exactly
/// what the screen shows. Two implementations would drift, and a report that
/// disagrees with the app is worse than no report.
enum ObservedDeviceBuilder {

    @MainActor
    static func rows(arp: [ARPEntry],
                     ipv6: [IPv6Neighbor] = [],
                     config: IPConfig,
                     interface: String?,
                     bssid: String?,
                     labels: DeviceRegistry,
                     vendors: VendorDatabase,
                     presence: DevicePresence,
                     discovery: DeviceDiscovery,
                     includeDeparted: Bool) -> [ObservedDevice] {
        let cached = ARPTable.devicesOnActiveSubnet(
            arp, interface: interface,
            localAddress: config.ipv4, mask: config.subnetMask)

        let v6 = IPv6NeighborTable.onInterface(ipv6, interface: interface)
        let v6ByMAC = Dictionary(grouping: v6, by: { DeviceRegistry.normalise($0.mac) })
        var usedV6MACs = Set<String>()
        var built: [ObservedDevice] = []

        // This Mac first, so the list is read from a known starting point.
        if let mac = config.activeMAC, let primary = config.ipv4 ?? config.ipv6.first {
            built.append(row(mac: mac, ip: primary, role: .thisMac,
                             sighting: nil, isPresent: true,
                             ipv6: config.ipv6.filter { $0 != primary },
                             labels: labels, vendors: vendors, discovery: discovery))
            usedV6MACs.insert(DeviceRegistry.normalise(mac))
        }

        for entry in cached {
            let role = DeviceRoleResolver.role(forMAC: entry.mac, ip: entry.ip,
                                               config: config, bssid: bssid)
            let macKey = DeviceRegistry.normalise(entry.mac)
            let ipv6Addresses = (v6ByMAC[macKey] ?? []).map(\.ip)
            built.append(row(mac: entry.mac, ip: entry.ip, role: role,
                             sighting: presence.sighting(forMAC: entry.mac),
                             isPresent: true,
                             ipv6: ipv6Addresses,
                             labels: labels, vendors: vendors, discovery: discovery))
            usedV6MACs.insert(macKey)
        }

        // IPv6-only neighbours have a real hardware identity but no IPv4 row.
        for (macKey, entries) in v6ByMAC where !usedV6MACs.contains(macKey) {
            guard let first = entries.first else { continue }
            built.append(row(mac: first.mac, ip: first.ip, role: .device,
                             sighting: nil, isPresent: true,
                             ipv6: Array(entries.dropFirst().map(\.ip)),
                             labels: labels, vendors: vendors, discovery: discovery))
        }

        // Hosts in an explicit routed range may answer ping or TCP without a
        // local MAC address. Keep them in the inventory keyed by IP.
        var represented = Set(built.flatMap { [$0.ip] + $0.ipv6Addresses })
        for (address, finding) in discovery.allFindings
            where finding.scanObservedAt != nil && !represented.contains(address) {
            if !includeDeparted, finding.scanOnline == false { continue }
            built.append(row(mac: "", ip: address, role: .device,
                             sighting: nil, isPresent: finding.scanOnline != false, ipv6: [],
                             identityKey: "ip:\(address)",
                             labels: labels, vendors: vendors, discovery: discovery))
            represented.insert(address)
        }

        // Devices seen earlier this session that have dropped out of the cache.
        if includeDeparted {
            let present = Set(built.map(\.mac))
            for gone in presence.departed where !present.contains(gone.mac) {
                built.append(row(mac: gone.mac, ip: gone.sighting.lastIP, role: .device,
                                 sighting: gone.sighting, isPresent: false,
                                 ipv6: [],
                                 labels: labels, vendors: vendors, discovery: discovery))
            }
        }
        return built
    }

    @MainActor
    private static func row(mac: String, ip: String, role: DeviceRole,
                            sighting: DevicePresence.Sighting?, isPresent: Bool,
                            ipv6: [String], identityKey: String? = nil,
                            labels: DeviceRegistry, vendors: VendorDatabase,
                            discovery: DeviceDiscovery) -> ObservedDevice {
        let hasMAC = DeviceRegistry.isValidMAC(mac)
        let vendor = hasMAC ? vendors.lookup(mac) : .unregistered
        let finding = discovery.finding(forAddresses: [ip] + ipv6)
        let locallyAdministered = ARPEntry(ip: ip, mac: mac).isLocallyAdministered
        return ObservedDevice(
            mac: DeviceRegistry.normalise(mac),
            ip: ip,
            role: role,
            record: hasMAC ? labels.record(forMAC: mac) : nil,
            vendor: vendor,
            vendorBlock: hasMAC ? vendors.block(for: mac) : nil,
            sighting: sighting,
            isLocallyAdministered: locallyAdministered,
            isPresent: isPresent,
            guess: DeviceClassifier.guess(vendor: vendor.displayName,
                                          finding: finding,
                                          isLocallyAdministered: locallyAdministered),
            finding: finding,
            ipv6Addresses: ipv6,
            identityKey: identityKey)
    }
}
