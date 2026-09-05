import SwiftUI

struct DetailsGrid: View {
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var registry: APRegistry
    @EnvironmentObject var netInfo: NetworkInfoModel
    @EnvironmentObject var pinger: GatewayPinger

    private let columns = [GridItem(.adaptive(minimum: 272, maximum: 420), spacing: UI.gap, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: UI.gap) {
            signalCard
            radioCard
            accessPointCard
            networkCard
            interfaceCard
            gatewayCard
        }
    }

    // MARK: Signal

    private var signalCard: some View {
        Card("Signal quality", systemImage: "antenna.radiowaves.left.and.right") {
            if let s = monitor.current {
                VStack(alignment: .leading, spacing: 7) {
                    InfoRow(label: "Signal (RSSI)", value: "\(s.rssi) dBm", mono: true, tint: s.quality.color,
                            help: "Received signal strength. Closer to 0 is stronger.")
                    InfoRow(label: "Noise floor", value: s.validNoise.map { "\($0) dBm" } ?? "Not reported", mono: true,
                            help: "Background RF energy on this channel. Lower is better.")
                    InfoRow(label: "SNR", value: s.snr.map { "\($0) dB" } ?? "Not available", mono: true, tint: s.snrQuality?.color,
                            help: "Signal minus noise. The best single predictor of throughput.")
                    Divider()
                    HStack(spacing: 8) {
                        QualityBadge(quality: s.quality)
                        Text(s.quality.advice)
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let snr = s.snr, snr < 20 {
                        noteRow("Low SNR — noise is close to your signal. Expect retries even if RSSI looks acceptable.", .orange)
                    }
                }
            } else { unavailable }
        }
    }

    // MARK: Radio

    private var radioCard: some View {
        Card("Radio", systemImage: "dot.radiowaves.left.and.right") {
            if let s = monitor.current {
                VStack(alignment: .leading, spacing: 7) {
                    InfoRow(label: "Channel", value: "\(s.channel)", mono: true)
                    InfoRow(label: "Band", value: s.band.label, tint: s.band.tint)
                    InfoRow(label: "Channel width", value: channelWidthLabel(s.channelWidthRaw))
                    InfoRow(label: "PHY mode", value: phyModeLabel(s.phyRaw))
                    InfoRow(label: "TX rate", value: Fmt.rate(s.txRate), mono: true,
                            help: "Last negotiated PHY rate, not measured throughput.")
                    InfoRow(label: "TX power", value: s.txPower > 0 ? "\(s.txPower) mW" : "—", mono: true)
                    InfoRow(label: "Security", value: securityLabel(s.securityRaw),
                            tint: securityIsOpen(s.securityRaw) ? .red : .primary)
                    InfoRow(label: "Country", value: s.countryCode ?? "Unavailable")
                    if securityIsOpen(s.securityRaw) {
                        noteRow("Open network — traffic is unencrypted at the link layer. Use a VPN.", .red)
                    }
                    if s.band == .ghz2 {
                        noteRow("2.4 GHz has only three non-overlapping channels and is usually the congested band.", .orange)
                    }
                }
            } else { unavailable }
        }
    }

    // MARK: Access point

    private var accessPointCard: some View {
        Card("Access point", systemImage: "wifi.router") {
            if let s = monitor.current {
                let key = s.apKey
                let rec = registry.record(for: key)
                VStack(alignment: .leading, spacing: 7) {
                    InfoRow(label: "Nickname", value: registry.nickname(for: key) ?? "Not named yet",
                            tint: registry.nickname(for: key) == nil ? .secondary : .primary)
                    InfoRow(label: "Site", value: rec?.site.isEmpty == false ? rec!.site : "—")
                    InfoRow(label: "SSID", value: s.ssid ?? "Unavailable")
                    InfoRow(label: "BSSID", value: s.bssid ?? "Unavailable", mono: true,
                            help: "MAC address of the specific radio you are associated with.")
                    if let r = rec {
                        InfoRow(label: "First seen", value: Fmt.stamp.string(from: r.firstSeen))
                        if let b = r.bestRSSI, let w = r.worstRSSI {
                            InfoRow(label: "Range seen", value: "\(w) to \(b) dBm", mono: true)
                        }
                    }
                    if let t = monitor.timeOnCurrentAP {
                        InfoRow(label: "Associated", value: Fmt.duration(t))
                    }
                    if let n = rec?.notes, !n.isEmpty {
                        Divider()
                        Text(n).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !key.isPreciseIdentity {
                        noteRow("Without a BSSID this AP is matched on channel and SSID, so two APs on the same channel would share one nickname.", .orange)
                    }
                }
            } else { unavailable }
        }
    }

    // MARK: IP

    private var networkCard: some View {
        Card("Network (IP)", systemImage: "network") {
            let c = netInfo.config
            VStack(alignment: .leading, spacing: 7) {
                InfoRow(label: "IPv4 address", value: c.ipv4 ?? "—", mono: true)
                InfoRow(label: "Subnet mask", value: c.subnetMask ?? "—", mono: true)
                InfoRow(label: "Router", value: c.router ?? "—", mono: true)
                InfoRow(label: "DNS servers", value: c.dnsServers.isEmpty ? "—" : c.dnsServers.joined(separator: ", "), mono: true)
                InfoRow(label: "Search domains", value: c.searchDomains.isEmpty ? "—" : c.searchDomains.joined(separator: ", "))
                InfoRow(label: "DHCP server", value: c.dhcpServer ?? "—", mono: true)
                if let exp = c.leaseExpiry {
                    InfoRow(label: "Lease expires", value: Fmt.stamp.string(from: exp))
                }
                if !c.ipv6.isEmpty {
                    InfoRow(label: "IPv6", value: c.ipv6.first!, mono: true)
                }
            }
        }
    }

    // MARK: Interface

    private var interfaceCard: some View {
        Card("Interface", systemImage: "laptopcomputer") {
            let c = netInfo.config
            VStack(alignment: .leading, spacing: 7) {
                InfoRow(label: "Interface", value: monitor.current?.interfaceName ?? "—", mono: true)
                InfoRow(label: "Status", value: monitor.status.label,
                        tint: monitor.status == .connected ? .green : .orange)
                InfoRow(label: "Hardware MAC", value: monitor.current?.hardwareAddress ?? "—", mono: true)
                InfoRow(label: "Active MAC", value: c.activeMAC ?? "—", mono: true)
                let priv = SystemNetwork.usingPrivateAddress(
                    hardware: monitor.current?.hardwareAddress, active: c.activeMAC)
                InfoRow(label: "Private address", value: priv ? "On" : "Off",
                        tint: priv ? .blue : .secondary,
                        help: "macOS rotates a private MAC per network unless disabled.")
                InfoRow(label: "Sample rate", value: String(format: "%.1f s", monitor.interval))
                if priv {
                    noteRow("This Mac presents a private MAC on this network. Ask the site admin to match on the active MAC, not the hardware one.", .blue)
                }
            }
        }
    }

    // MARK: Gateway

    private var gatewayCard: some View {
        Card("Gateway reachability", systemImage: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: 7) {
                Toggle(isOn: $pinger.enabled) {
                    Text("Ping the default gateway").font(.system(size: 11.5))
                }
                .toggleStyle(.switch).controlSize(.mini)
                .disabled(netInfo.config.router == nil)

                Text("Sends one ICMP echo per second to \(netInfo.config.router ?? "the router") and nowhere else. Off by default.")
                    .font(.system(size: 10)).foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)

                if pinger.enabled {
                    Divider()
                    InfoRow(label: "Target", value: pinger.target ?? "—", mono: true)
                    InfoRow(label: "Latency", value: pinger.lastRTT.map { String(format: "%.1f ms", $0) } ?? "timeout",
                            mono: true, tint: pinger.lastRTT == nil ? .red : ((pinger.lastRTT ?? 0) > 50 ? .orange : .green))
                    InfoRow(label: "Average", value: pinger.averageRTT.map { String(format: "%.1f ms", $0) } ?? "—", mono: true)
                    InfoRow(label: "Jitter", value: pinger.jitter.map { String(format: "%.1f ms", $0) } ?? "—", mono: true)
                    InfoRow(label: "Packet loss", value: String(format: "%.1f%% (%d/%d)", pinger.lossPercent, pinger.completed - pinger.received, pinger.completed),
                            mono: true, tint: pinger.lossPercent > 2 ? .red : .primary)
                    Button("Reset counters") { pinger.reset() }
                        .controlSize(.small).padding(.top, 2)
                }
                if netInfo.config.router == nil {
                    noteRow("No default router is available to test on the current connection.", .orange)
                }
            }
        }
    }

    // MARK: Helpers

    private func noteRow(_ text: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9)).foregroundStyle(tint)
            Text(text).font(.system(size: 10)).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 1)
    }

    private var unavailable: some View {
        Text("No active connection.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

// MARK: - Nickname editor

/// Popover for naming an access point. Everything typed here stays on this Mac.
struct NicknameEditor: View {
    @EnvironmentObject var registry: APRegistry
    var key: APKey
    var sample: WiFiSample?

    @State private var nickname = ""
    @State private var site = ""
    @State private var notes = ""
    @State private var colorIndex: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Name this access point")
                .font(.system(size: 13, weight: .semibold))

            if let s = sample {
                Text("\(s.bssid ?? "No BSSID") · Ch \(s.channel) · \(s.band.label)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Nickname")
                TextField("e.g. Reception ceiling AP", text: $nickname)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Site or floor")
                TextField("e.g. Acme HQ · 2nd floor", text: $site)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Notes")
                TextEditor(text: $notes)
                    .font(.system(size: 11))
                    .frame(height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.hairline, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Colour on the graph")
                HStack(spacing: 5) {
                    ForEach(APPalette.colors.indices, id: \.self) { i in
                        Circle()
                            .fill(APPalette.colors[i])
                            .frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(.primary,
                                lineWidth: colorIndex == i ? 2 : 0))
                            .onTapGesture { colorIndex = i }
                    }
                    Button {
                        colorIndex = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to the automatic colour")
                }
            }

            Divider()

            HStack {
                if registry.record(for: key)?.hasNickname == true {
                    Button("Remove Name", role: .destructive) {
                        registry.setNickname("", for: key)
                        dismiss()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }.controlSize(.small)
                Button("Save", action: save)
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            let r = registry.record(for: key)
            nickname = r?.nickname ?? ""
            site = r?.site ?? ""
            notes = r?.notes ?? ""
            colorIndex = r?.colorOverride
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9, weight: .semibold)).tracking(0.5)
            .foregroundStyle(.secondary)
    }

    private func save() {
        registry.setNickname(nickname, for: key)
        registry.setSite(site, for: key)
        registry.setNotes(notes, for: key)
        registry.setColor(colorIndex, for: key)
        registry.saveNow()
        dismiss()
    }
}
