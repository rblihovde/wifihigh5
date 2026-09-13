import SwiftUI

struct LiveView: View {
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var registry: APRegistry
    @EnvironmentObject var netInfo: NetworkInfoModel
    @EnvironmentObject var pinger: GatewayPinger
    @EnvironmentObject var gate: LocationGate

    @AppStorage("chartWindow") private var windowSeconds: Double = 300
    @AppStorage("showNoise") private var showNoise = true
    @AppStorage("showRate") private var showRate = false
    @AppStorage("chartScale") private var scaleRaw = ChartScale.full.rawValue
    @AppStorage("chartHeight") private var chartHeight: Double = 250
    @State private var dragStartHeight: Double?
    @State private var renaming = false

    private var window: TimeInterval? { windowSeconds <= 0 ? nil : windowSeconds }
    private var scale: ChartScale { ChartScale(rawValue: scaleRaw) ?? .full }

    /// Continuous redraws only help while sampling runs and the window is short
    /// enough for the movement to be visible.
    private var animatesChart: Bool {
        guard monitor.isRunning, let window else { return false }
        return window <= 900
    }

    private static let defaultChartHeight: Double = 250
    private static let chartHeightLimits: ClosedRange<Double> = 180...720

    var body: some View {
        ScrollView {
            VStack(spacing: UI.gap) {
                ConnectionHeader(renaming: $renaming)
                if monitor.status == .connected, monitor.current != nil {
                    // A screenshot build always shows names, so the prompt would be wrong.
                    if !gate.isAuthorized, !DemoBuild.isActive { PermissionBanner() }
                    ConnectionGuide()
                    chartPanel
                    StatsStrip(window: window)
                    DetailsGrid()
                } else {
                    ConnectionSetupHint()
                }
            }
            .padding(UI.gap)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Chart

    private var chartPanel: some View {
        Card {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Label("Signal over time", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 8)
                    Picker("", selection: $scaleRaw) {
                        ForEach(ChartScale.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 230)
                    .help("Vertical zoom. Tighter scales make small changes easy to see; read the values on the axis. \(scale.help)")

                    Picker("", selection: $windowSeconds) {
                        Text("1 min").tag(60.0)
                        Text("5 min").tag(300.0)
                        Text("15 min").tag(900.0)
                        Text("1 hour").tag(3600.0)
                        Text("Session").tag(0.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 290)
                }

                HStack(spacing: 10) {
                    legend
                    Spacer(minLength: 8)
                    Toggle("Noise floor", isOn: $showNoise)
                        .toggleStyle(.checkbox).controlSize(.mini)
                        .help("Overlay the noise floor. The gap between signal and noise is your SNR.")
                    Toggle("TX rate", isOn: $showRate)
                        .toggleStyle(.checkbox).controlSize(.mini)
                        .help("Overlay negotiated transmit rate on a relative scale.")
                }

                // Redrawn continuously rather than once per reading, so the trace
                // glides instead of stepping. The readings themselves are
                // unchanged; only the time axis moves between them. Long windows
                // skip this, because at an hour across the width the movement
                // is a fraction of a pixel a second and the redraws buy nothing.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animatesChart)) { context in
                    SignalChart(
                        // One reading either side of the window, so the line
                        // runs off the edge rather than stopping short of it.
                        samples: monitor.samples(inLast: window.map { $0 + monitor.interval * 2 }),
                        roamEvents: monitor.roamEvents,
                        waypoints: monitor.waypoints,
                        registry: registry,
                        window: window,
                        referenceDate: animatesChart ? context.date : monitor.historyReferenceDate,
                        showNoise: showNoise,
                        showRate: showRate,
                        sampleInterval: monitor.interval,
                        scale: scale
                    )
                }
                .frame(height: chartHeight)

                resizeHandle
            }
        }
    }

    /// Drag to make the chart taller or shorter. The height is remembered.
    private var resizeHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 38, height: 4)
            .frame(maxWidth: .infinity, minHeight: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? chartHeight
                        if dragStartHeight == nil { dragStartHeight = chartHeight }
                        chartHeight = clampedHeight(start + value.translation.height)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .onTapGesture(count: 2) { chartHeight = Self.defaultChartHeight }
            .help("Drag to resize the chart. Double-click to restore its height.")
            .accessibilityElement()
            .accessibilityLabel("Chart height")
            .accessibilityValue("\(Int(chartHeight)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: chartHeight = clampedHeight(chartHeight + 40)
                case .decrement: chartHeight = clampedHeight(chartHeight - 40)
                @unknown default: break
                }
            }
    }

    private func clampedHeight(_ value: Double) -> Double {
        Swift.min(Swift.max(value, Self.chartHeightLimits.lowerBound),
                  Self.chartHeightLimits.upperBound)
    }

    /// Colour key for every AP seen this session, so the trace is readable.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(monitor.sessionAPKeys.prefix(5), id: \.raw) { key in
                let rec = registry.record(for: key)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(registry.color(for: key)).frame(width: 8, height: 8)
                    Text(registry.displayName(for: key,
                                              fallbackChannel: rec?.lastChannel,
                                              fallbackBand: rec?.lastBandRaw))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct ConnectionSetupHint: View {
    var body: some View {
        Card("To start a walkthrough", systemImage: "figure.walk") {
            HStack(alignment: .top, spacing: 24) {
                step("1", "Turn on Wi-Fi", "Use the Wi-Fi menu in the macOS menu bar.")
                step("2", "Join the network", "Connect this Mac to the network you want to test.")
                step("3", "Start walking", "Readings and guidance appear automatically—no scan required.")
            }
            .padding(.vertical, 4)
        }
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permission banner

struct PermissionBanner: View {
    @EnvironmentObject var gate: LocationGate

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("Network names are hidden")
                    .font(.system(size: 12, weight: .semibold))
                Text(permissionMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 5) {
                if gate.status == .notDetermined && !gate.deniedWithoutPrompt {
                    Button("Show Network Names") { gate.request() }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                }
                Button(gate.status == .notDetermined ? "Open Settings" : "Review in Settings") {
                    gate.openSettings()
                }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius)
            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private var permissionMessage: String {
        if gate.status == .denied {
            return "Access was declined. Signal testing still works, but macOS hides the network and access point names. You can change this in Privacy Settings."
        }
        if gate.status == .restricted || gate.deniedWithoutPrompt {
            return "Location Services is off or locked by a policy such as Screen Time. Signal testing still works, but macOS hides network and access point names."
        }
        return "To identify which network and access point you are testing, allow access when you’re ready. The app never records your location."
    }
}

// MARK: - Header

struct ConnectionHeader: View {
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var registry: APRegistry
    @Binding var renaming: Bool

    var body: some View {
        Card {
            if let s = monitor.current, monitor.status == .connected {
                connected(s)
            } else {
                disconnected
            }
        }
    }

    @ViewBuilder
    private func connected(_ s: WiFiSample) -> some View {
        let key = s.apKey
        let name = registry.displayName(for: key, fallbackChannel: s.channel, fallbackBand: s.bandRaw)

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(registry.color(for: key))
                        .frame(width: 16, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.white.opacity(0.3), lineWidth: 1))

                    Text(name)
                        .font(.system(size: 21, weight: .bold))
                        .lineLimit(1)
                        .layoutPriority(1)

                    Button { renaming = true } label: {
                        Image(systemName: registry.nickname(for: key) == nil
                              ? "plus.circle" : "pencil.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(registry.nickname(for: key) == nil ? "Name this access point" : "Edit this access point")
                    .popover(isPresented: $renaming, arrowEdge: .bottom) {
                        NicknameEditor(key: key, sample: s)
                            .environmentObject(registry)
                    }

                    if !key.isPreciseIdentity {
                        Pill(text: "FINGERPRINT", tint: .orange)
                            .help("No BSSID available, so this AP is identified by its radio fingerprint.")
                    }
                }

                Spacer(minLength: 8)

                HStack(alignment: .center, spacing: 16) {
                    readout("\(s.rssi)", "dBm", s.quality.color, "Signal")
                    readout(s.snr.map(String.init) ?? "—", "dB", s.snrQuality?.color ?? .secondary, "SNR")
                    readout(Fmt.rate(s.txRate).components(separatedBy: " ").first ?? "—",
                            Fmt.rate(s.txRate).components(separatedBy: " ").last ?? "", .primary, "TX rate")
                    VStack(spacing: 5) {
                        SignalBars(quality: s.quality, size: 24)
                        QualityBadge(quality: s.quality, compact: true)
                    }
                }
            }

            HStack(spacing: 8) {
                label("Network", s.ssid ?? "Hidden")
                dot
                label("BSSID", s.bssid ?? "Unavailable", mono: true)
                dot
                label("Channel", "\(s.channel)")
                Pill(text: s.band.short, tint: s.band.tint)
                Text(channelWidthLabel(s.channelWidthRaw))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if let t = monitor.timeOnCurrentAP {
                    Text("On this AP for \(Fmt.duration(t))")
                        .font(.system(size: 10.5)).foregroundStyle(Color.subtle).lineLimit(1)
                }
                if let rec = registry.record(for: key), !rec.site.isEmpty {
                    Pill(text: rec.site, tint: .secondary)
                }
            }
        }
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func label(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(v)
                .font(.system(size: 11.5, weight: .medium, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func readout(_ value: String, _ unit: String, _ tint: Color, _ caption: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(caption.uppercased())
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(Color.subtle)
                .explains(caption)
        }
    }

    private var disconnected: some View {
        HStack(spacing: 12) {
            Image(systemName: monitor.status == .poweredOff ? "wifi.slash" : "wifi.exclamationmark")
                .font(.system(size: 24)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.status.label).font(.system(size: 16, weight: .semibold))
                Text(disconnectedMessage)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: 52)
    }

    private var disconnectedMessage: String {
        switch monitor.status {
        case .poweredOff: return "Turn Wi-Fi on to begin monitoring."
        case .noInterface: return "No Wi-Fi adapter is available on this Mac."
        case .disconnected: return "Join a Wi-Fi network to begin monitoring."
        case .connected: return "Waiting for the first reading."
        }
    }
}

// MARK: - Stats strip

struct StatsStrip: View {
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var pinger: GatewayPinger
    var window: TimeInterval?

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 0) {
                if let st = monitor.stats(inLast: window) {
                    StatTile(label: "Current", value: monitor.current.map { "\($0.rssi)" } ?? "—",
                             unit: "dBm", tint: monitor.current?.quality.color ?? .primary)
                    divider
                    StatTile(label: "Average", value: "\(st.avg)", unit: "dBm",
                             tint: SignalQuality(rssi: st.avg).color)
                    divider
                    StatTile(label: "Best", value: "\(st.max)", unit: "dBm",
                             tint: SignalQuality(rssi: st.max).color)
                    divider
                    StatTile(label: "Worst", value: "\(st.min)", unit: "dBm",
                             tint: SignalQuality(rssi: st.min).color)
                    divider
                    StatTile(label: "Variation", value: "±\(st.jitter)", unit: "dB",
                             tint: st.jitter > 6 ? .orange : .primary,
                             caption: st.jitter > 6 ? "Unstable" : "Steady")
                    divider
                    StatTile(label: "Changes", value: "\(monitor.roamEvents.filter { $0.reason.countsAsConnectionChange }.count)",
                             tint: .primary, caption: "\(monitor.sessionAPKeys.count) AP(s) seen")
                    divider
                    StatTile(label: "Samples", value: "\(st.count)",
                             caption: Fmt.duration(monitor.sessionDuration))
                    if pinger.enabled {
                        divider
                        StatTile(label: "Gateway",
                                 value: pinger.lastRTT.map { String(format: "%.0f", $0) } ?? "—",
                                 unit: "ms",
                                 tint: (pinger.lastRTT ?? 0) > 50 ? .orange : .primary,
                                 caption: pinger.completed == 0
                                    ? "Testing…"
                                    : String(format: "%.0f%% loss", pinger.lossPercent))
                    }
                } else {
                    Text("Collecting samples…")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.hairline).frame(width: 1, height: 32).padding(.horizontal, 2)
    }
}
