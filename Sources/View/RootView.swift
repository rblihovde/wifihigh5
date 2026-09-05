import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case live = "Live Monitor"
    case networkMap = "Network Map"
    case accessPoints = "Access Points"
    case roamLog = "Connection Changes"
    case surveys = "Walkthroughs"
    case nearby = "Nearby Networks"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .live:         return "waveform.path.ecg"
        case .networkMap:   return "point.topleft.down.to.point.bottomright.curvepath"
        case .accessPoints: return "wifi.router"
        case .roamLog:      return "arrow.left.arrow.right"
        case .surveys:      return "figure.walk"
        case .nearby:       return "dot.radiowaves.up.forward"
        case .diagnostics:  return "stethoscope"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var registry: APRegistry
    @EnvironmentObject var netInfo: NetworkInfoModel
    @EnvironmentObject var pinger: GatewayPinger
    @EnvironmentObject var surveyUI: SurveyUI
    @Binding var confirmClearSession: Bool

    // Remembered across launches so the app reopens where you left off.
    @AppStorage("selectedPane") private var paneRaw = Pane.live.rawValue

    private var pane: Binding<Pane> {
        Binding(get: { Pane(rawValue: paneRaw) ?? .live },
                set: { paneRaw = $0.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: pane) { s in
                NavigationLink(value: s) {
                    Label(s.rawValue, systemImage: s.symbol)
                }
            }
            .navigationSplitViewColumnWidth(min: 178, ideal: 194, max: 240)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            Group {
                switch pane.wrappedValue {
                case .live:         LiveView()
                case .networkMap:   NetworkMapView()
                case .accessPoints: AccessPointsView()
                case .roamLog:      RoamLogView()
                case .surveys:      SurveysView()
                case .nearby:       NearbyView()
                case .diagnostics:  DiagnosticsView()
                }
            }
            .navigationTitle(pane.wrappedValue.rawValue)
            .toolbar { toolbarItems }
        }
        .confirmationDialog("Clear this monitoring session?",
                            isPresented: $confirmClearSession) {
            Button("Clear Session", role: .destructive) { monitor.clearSession() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The graph and connection-change history will be discarded. Saved access point names are not affected.")
        }
        .sheet(item: $surveyUI.pendingWaypoint) { pending in
            WaypointCaptureSheet(time: pending.time)
        }
        .onAppear { netInfo.start() }
        .onChange(of: monitor.current?.interfaceName) { _, name in
            if let name { netInfo.bind(interface: name) }
        }
        .onChange(of: netInfo.config.router) { _, router in
            pinger.target = router
        }
    }

    // MARK: Sidebar footer

    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let s = monitor.current, monitor.status == .connected {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(registry.color(for: s.apKey)).frame(width: 9, height: 9)
                    Text(registry.displayName(for: s.apKey,
                                              fallbackChannel: s.channel, fallbackBand: s.bandRaw))
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                }
                HStack(spacing: 6) {
                    SignalBars(quality: s.quality, size: 14)
                    Text("\(s.rssi) dBm")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(s.quality.color)
                    Spacer(minLength: 2)
                    Text("SNR \(s.snr.map(String.init) ?? "—")")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash").font(.system(size: 10)).foregroundStyle(.orange)
                    Text(monitor.status.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(monitor.isRunning ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text(monitor.isRunning ? "Monitoring · passive" : "Paused · \(Fmt.relativeTime(monitor.current?.time ?? Date()))")
                    .font(.system(size: 9)).foregroundStyle(Color.subtle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { surveyUI.captureWaypoint() } label: {
                Label("Mark Spot", systemImage: "mappin")
            }
            .disabled(monitor.current == nil)
            .help("Mark where you are right now (⌘M)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { monitor.toggle() } label: {
                Label(monitor.isRunning ? "Pause" : "Resume",
                      systemImage: monitor.isRunning ? "pause.fill" : "play.fill")
            }
            .help(monitor.isRunning ? "Pause sampling" : "Resume sampling")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { confirmClearSession = true } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(monitor.samples.isEmpty && monitor.roamEvents.isEmpty)
            .help("Discard the current session history")
        }
    }
}
