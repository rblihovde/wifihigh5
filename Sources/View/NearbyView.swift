import SwiftUI

/// Explicit, on-demand survey of the RF neighbourhood.
struct NearbyView: View {
    @EnvironmentObject var scanner: Scanner
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var registry: APRegistry

    @State private var sameNetworkOnly = false

    private var visible: [ScanResult] {
        guard sameNetworkOnly else { return scanner.results }
        return scanner.results.filter { $0.isCurrentNetwork }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let err = scanner.errorMessage {
                errorBanner(err)
            }
            if scanner.results.isEmpty {
                EmptyHint(
                    systemImage: "dot.radiowaves.up.forward",
                    title: "No scan run yet",
                    message: "A scan lists nearby access points. Use it to check coverage overlap and channel crowding.\n\nA scan sends standard Wi-Fi probe requests.",
                    action: (label: "Scan Now", run: runScan)
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: UI.gap) {
                        scanSummaryCard
                        congestionCard
                        if visible.isEmpty {
                            Text("No access points from your current network were found in this scan.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(24)
                        } else {
                            LazyVStack(spacing: 6) {
                                ForEach(visible) { r in row(r) }
                            }
                        }
                    }
                    .padding(UI.gap)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: runScan) {
                HStack(spacing: 5) {
                    if scanner.isScanning { ProgressView().controlSize(.small).scaleEffect(0.6) }
                    Text(scanner.isScanning ? "Scanning…" : "Scan Now")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(scanner.isScanning)

            Toggle("Only my network", isOn: $sameNetworkOnly)
                .toggleStyle(.checkbox).controlSize(.small)
                .disabled(monitor.current?.ssid == nil)

            Spacer()

            if let last = scanner.lastScan {
                Text("Updated \(Fmt.relativeTime(last)) · \(scanner.results.count) access points")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Pill(text: "TRANSMITS", tint: .orange)
                .help("Scanning sends probe requests. The rest of the app only listens.")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(msg).font(.system(size: 11))
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var scanSummaryCard: some View {
        Card("What this scan suggests", systemImage: "lightbulb") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    summaryValue("Access points", "\(scanner.results.count)")
                    summaryValue("Network names", "\(Set(scanner.results.compactMap(\.ssid)).count)")
                    summaryValue("Channels in use", "\(scanner.channelLoad().count)")
                }
                Divider()
                roamingSummary
            }
        }
    }

    @ViewBuilder
    private var roamingSummary: some View {
        if let current = monitor.current, let ssid = current.ssid {
            let candidates = scanner.roamCandidates(for: ssid, currentBSSID: current.bssid)
            if let strongest = candidates.max(by: { $0.rssi < $1.rssi }) {
                let baseline = scanner.results.first(where: isCurrentAP)?.rssi ?? current.rssi
                let delta = strongest.rssi - baseline
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: delta >= 6 ? "arrow.up.right.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(delta >= 6 ? .orange : .green)
                    Text(delta >= 6
                         ? "A different radio for \(ssid) is about \(delta) dB stronger here. macOS decides when to roam. Watch Connection Changes to see whether it switches."
                         : "\(candidates.count) alternate radio\(candidates.count == 1 ? " is" : "s are") visible for \(ssid). None is at least 6 dB stronger than the current radio at this spot.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No alternate radios for \(ssid) were visible. That may be expected, or it may indicate limited coverage overlap at this spot.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Network names are hidden, so the app cannot identify roaming options for your current network. General channel crowding is still shown below.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var congestionCard: some View {
        Card("Channel crowding", systemImage: "chart.bar.fill") {
            let load = scanner.channelLoad().prefix(10)
            if load.isEmpty {
                Text("No channel data.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let maxCount = load.map(\.count).max() ?? 1
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(load)) { entry in
                        HStack(spacing: 8) {
                            Text("Ch \(entry.channel)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .frame(width: 52, alignment: .leading)
                            Pill(text: entry.band.short, tint: entry.band.tint)
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(entry.band.tint.opacity(0.75))
                                    .frame(width: g.size.width * CGFloat(entry.count) / CGFloat(maxCount))
                            }
                            .frame(height: 9)
                            Text("\(entry.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                            if entry.channel == monitor.current?.channel,
                               entry.band == monitor.current?.band {
                                Pill(text: "YOU", tint: .green, filled: true)
                            }
                        }
                    }
                    Text("Access point count by channel. This is a crowding clue, not a measurement of traffic, interference, or airtime utilization.")
                        .font(.system(size: 10)).foregroundStyle(Color.subtle)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func row(_ r: ScanResult) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(registry.color(for: r.key)).frame(width: 10, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(registry.nickname(for: r.key) ?? (r.ssid ?? "Hidden network"))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if isCurrentAP(r) { Pill(text: "CONNECTED", tint: .green, filled: true) }
                    else if r.isCurrentNetwork { Pill(text: "SAME SSID", tint: .blue) }
                }
                HStack(spacing: 6) {
                    Text(r.bssid ?? "—")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text("Ch \(r.channel)").font(.system(size: 10)).foregroundStyle(.secondary)
                    Pill(text: r.band.short, tint: r.band.tint)
                    Text(channelWidthLabel(r.widthRaw)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(securityLabel(r.securityRaw))
                        .font(.system(size: 10))
                        .foregroundStyle(securityIsOpen(r.securityRaw) ? .red : .secondary)
                }
            }

            Spacer(minLength: 8)

            Text("\(r.rssi) dBm")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(r.quality.color)
            QualityBadge(quality: r.quality, compact: true)
        }
        .padding(10)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius)
            .strokeBorder(isCurrentAP(r) ? Color.green.opacity(0.5) : Color.hairline.opacity(0.6),
                          lineWidth: isCurrentAP(r) ? 1.5 : 1))
    }

    private func runScan() {
        scanner.scan(currentSSID: monitor.current?.ssid, currentBSSID: monitor.current?.bssid)
    }

    private func isCurrentAP(_ result: ScanResult) -> Bool {
        guard let current = monitor.current?.bssid else { return result.isCurrentAP }
        return result.bssid?.caseInsensitiveCompare(current) == .orderedSame
    }
}
