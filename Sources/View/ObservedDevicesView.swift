import SwiftUI

/// Passive view of IPv4 devices already present in the Mac's ARP cache.
struct ObservedDevicesView: View {
    @EnvironmentObject private var monitor: WiFiMonitor
    @EnvironmentObject private var netInfo: NetworkInfoModel
    @EnvironmentObject private var vendors: VendorDatabase

    @State private var searchText = ""

    private var activeInterface: String? {
        monitor.current?.interfaceName ?? netInfo.config.primaryInterface
    }

    private var devices: [ARPEntry] {
        ARPTable.devicesOnActiveSubnet(
            netInfo.arpEntries,
            interface: activeInterface,
            localAddress: netInfo.config.ipv4,
            mask: netInfo.config.subnetMask
        )
    }

    private var visibleDevices: [ARPEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return devices }
        return devices.filter { entry in
            [entry.ip, entry.mac, role(for: entry), vendorName(for: entry)]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            passiveNotice

            if devices.isEmpty {
                EmptyHint(
                    systemImage: "desktopcomputer.and.macbook",
                    title: "No devices observed",
                    message: emptyMessage,
                    action: (label: "Refresh Cache", run: netInfo.refreshARP)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        columnHeader
                        ForEach(visibleDevices, id: \.ip) { entry in
                            deviceRow(entry)
                        }
                        if visibleDevices.isEmpty {
                            Text("No observed device matches this filter.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(28)
                        }
                    }
                    .padding(UI.gap)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { netInfo.refreshARP() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            netInfo.refreshARP()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: netInfo.refreshARP) {
                HStack(spacing: 5) {
                    if netInfo.isRefreshingARP {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                    Text(netInfo.isRefreshingARP ? "Refreshing…" : "Refresh Cache")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(netInfo.isRefreshingARP)

            TextField("Filter by IP, MAC, role, or manufacturer", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 290)

            Spacer()

            if let lastRefresh = netInfo.lastARPRefresh {
                Text("Updated \(Fmt.relativeTime(lastRefresh)) · \(devices.count) observed")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Pill(text: "PASSIVE", tint: .green)
                .help("This view reads the existing ARP cache and sends no packets.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var passiveNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "shield.checkered")
                .foregroundStyle(.green)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Passive device view")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Reads the Mac's existing ARP cache. It does not probe devices, scan ports, or send network traffic. Quiet, isolated, and IPv6-only devices may be absent.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.08))
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("DEVICE").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            Text("IP ADDRESS").frame(width: 128, alignment: .leading)
            Text("MAC ADDRESS").frame(width: 150, alignment: .leading)
            Text("MANUFACTURER").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func deviceRow(_ entry: ARPEntry) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: entry.ip == netInfo.config.router ? "wifi.router" : "desktopcomputer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(entry.ip == netInfo.config.router ? Color.blue : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role(for: entry))
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(entry.isLocallyAdministered ? "Private or virtual address" : "Hardware address")
                        .font(.system(size: 9.5))
                        .foregroundStyle(entry.isLocallyAdministered ? Color.orange : Color.secondary)
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            Text(entry.ip)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(width: 128, alignment: .leading)

            Text(entry.mac)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(width: 150, alignment: .leading)

            Text(vendorName(for: entry))
                .font(.system(size: 11))
                .foregroundStyle(entry.isLocallyAdministered ? Color.orange : Color.primary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(
            RoundedRectangle(cornerRadius: UI.radius)
                .strokeBorder(Color.hairline.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(role(for: entry)), IP \(entry.ip), MAC \(entry.mac), \(vendorName(for: entry))")
    }

    private var emptyMessage: String {
        if activeInterface == nil || netInfo.config.ipv4 == nil || netInfo.config.subnetMask == nil {
            return "Waiting for the active Wi-Fi interface and IPv4 settings."
        }
        return "The Mac's ARP cache does not currently contain another device on this Wi-Fi subnet. Using the network normally may add entries. This view does not generate traffic to find them."
    }

    private func role(for entry: ARPEntry) -> String {
        entry.ip == netInfo.config.router ? "Router" : "Observed device"
    }

    private func vendorName(for entry: ARPEntry) -> String {
        switch vendors.lookup(entry.mac) {
        case .known(let name): return name
        case .randomised: return "Not available for private addresses"
        case .unregistered: return "Not identified"
        case .loading: return "Loading…"
        }
    }
}
