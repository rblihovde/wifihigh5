import Foundation

/// Assembles the device rows from the passive cache and whatever else is known.
///
/// This lives outside the view because the exported report has to show exactly
/// what the screen shows. Two implementations would drift, and a report that
/// disagrees with the app is worse than no report.
enum ObservedDeviceBuilder {

    @MainActor
    static func rows(arp: [ARPEntry],
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

        var built: [ObservedDevice] = []

        // This Mac first, so the list is read from a known starting point.
        if let ip = config.ipv4, let mac = config.activeMAC {
            built.append(row(mac: mac, ip: ip, role: .thisMac,
                             sighting: nil, isPresent: true,
                             labels: labels, vendors: vendors, discovery: discovery))
        }

        for entry in cached {
            let role = DeviceRoleResolver.role(forMAC: entry.mac, ip: entry.ip,
                                               config: config, bssid: bssid)
            built.append(row(mac: entry.mac, ip: entry.ip, role: role,
                             sighting: presence.sighting(forMAC: entry.mac),
                             isPresent: true,
                             labels: labels, vendors: vendors, discovery: discovery))
        }

        // Devices seen earlier this session that have dropped out of the cache.
        if includeDeparted {
            let present = Set(built.map(\.mac))
            for gone in presence.departed where !present.contains(gone.mac) {
                built.append(row(mac: gone.mac, ip: gone.sighting.lastIP, role: .device,
                                 sighting: gone.sighting, isPresent: false,
                                 labels: labels, vendors: vendors, discovery: discovery))
            }
        }
        return built
    }

    @MainActor
    private static func row(mac: String, ip: String, role: DeviceRole,
                            sighting: DevicePresence.Sighting?, isPresent: Bool,
                            labels: DeviceRegistry, vendors: VendorDatabase,
                            discovery: DeviceDiscovery) -> ObservedDevice {
        let vendor = vendors.lookup(mac)
        let finding = discovery.finding(forIP: ip)
        let locallyAdministered = ARPEntry(ip: ip, mac: mac).isLocallyAdministered
        return ObservedDevice(
            mac: DeviceRegistry.normalise(mac),
            ip: ip,
            role: role,
            record: labels.record(forMAC: mac),
            vendor: vendor,
            sighting: sighting,
            isLocallyAdministered: locallyAdministered,
            isPresent: isPresent,
            guess: DeviceClassifier.guess(vendor: vendor.displayName,
                                          finding: finding,
                                          isLocallyAdministered: locallyAdministered),
            finding: finding)
    }
}
