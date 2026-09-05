import SwiftUI
import AppKit

/// Keeps the app alive in the menu bar when the window is closed, and flushes
/// the nickname store on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { onTerminate?() }
    }
}

@main
@MainActor
struct WiFiSignalTesterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var registry: APRegistry
    @StateObject private var monitor: WiFiMonitor
    @StateObject private var netInfo = NetworkInfoModel()
    @StateObject private var pinger = GatewayPinger()
    @StateObject private var scanner = Scanner()
    @StateObject private var gate = LocationGate()
    @StateObject private var store = SurveyStore()
    @StateObject private var surveyUI = SurveyUI()
    @StateObject private var vendors = VendorDatabase()
    @State private var confirmClearSession = false

    init() {
        let reg = APRegistry()
        _registry = StateObject(wrappedValue: reg)
        _monitor = StateObject(wrappedValue: WiFiMonitor(registry: reg))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(confirmClearSession: $confirmClearSession)
                .environmentObject(registry)
                .environmentObject(monitor)
                .environmentObject(netInfo)
                .environmentObject(pinger)
                .environmentObject(scanner)
                .environmentObject(gate)
                .environmentObject(store)
                .environmentObject(surveyUI)
                .environmentObject(vendors)
                .frame(minWidth: 940, minHeight: 620)
                .task {
                    appDelegate.onTerminate = { registry.saveNow() }
                }
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            HelpCommands()
            CommandMenu("Survey") {
                Button("Mark This Spot") { surveyUI.captureWaypoint() }
                    .keyboardShortcut("m", modifiers: .command)
                    .disabled(monitor.current == nil)
                Divider()
                Button(monitor.isRecording ? "Stop Recording" : "Start Recording…") {
                    if monitor.isRecording {
                        if let session = monitor.finishRecording() { store.save(session) }
                    } else {
                        monitor.startRecording(name: "", site: "")
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Monitor") {
                Button(monitor.isRunning ? "Pause Sampling" : "Resume Sampling") { monitor.toggle() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Clear Session…") { confirmClearSession = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(monitor.samples.isEmpty && monitor.roamEvents.isEmpty)
                Divider()
                Button("Scan Nearby Networks") {
                    scanner.scan(currentSSID: monitor.current?.ssid,
                                 currentBSSID: monitor.current?.bssid)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(scanner.isScanning)
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(registry)
                .environmentObject(monitor)
                .environmentObject(gate)
        } label: {
            MenuBarLabel()
                .environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)

        Window("WiFi Signal Tester Help", id: Self.helpWindowID) {
            HelpView()
        }
        .defaultSize(width: 900, height: 620)
    }

    static let helpWindowID = "help"
}

/// Compact live readout that sits in the menu bar while you walk a site.
struct MenuBarLabel: View {
    @EnvironmentObject var monitor: WiFiMonitor

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: monitor.isRunning ? "wifi" : "pause.circle.fill")
            if let s = monitor.current, monitor.status == .connected {
                Text("\(s.rssi)").font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
        }
        .accessibilityLabel(menuBarAccessibilityLabel)
    }

    private var menuBarAccessibilityLabel: String {
        guard let s = monitor.current, monitor.status == .connected else {
            return "Wi-Fi Signal Tester, \(monitor.status.label)"
        }
        return "Wi-Fi signal \(s.rssi) decibels milliwatt, \(monitor.isRunning ? "monitoring" : "paused")"
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var registry: APRegistry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let s = monitor.current, monitor.status == .connected {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(registry.color(for: s.apKey)).frame(width: 12, height: 12)
                    Text(registry.displayName(for: s.apKey,
                                              fallbackChannel: s.channel, fallbackBand: s.bandRaw))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    QualityBadge(quality: s.quality, compact: true)
                }
                Divider()
                HStack(spacing: 14) {
                    menuStat("Signal", "\(s.rssi)", "dBm", s.quality.color)
                    menuStat("SNR", s.snr.map(String.init) ?? "—", "dB", s.snrQuality?.color ?? .secondary)
                    menuStat("Rate", Fmt.rate(s.txRate), "", .primary)
                }
                HStack(spacing: 6) {
                    Text(s.ssid ?? "Network name hidden")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text("Ch \(s.channel) · \(s.band.short)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                    Text(monitor.status.label).font(.system(size: 12, weight: .medium))
                }
            }
            Divider()
            HStack(spacing: 7) {
                Button("Open Window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
                Button(monitor.isRunning ? "Pause" : "Resume") { monitor.toggle() }
                    .controlSize(.small)
                Text(monitor.isRunning ? "Live" : "Paused")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(monitor.isRunning ? Color.green : Color.orange)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 288)
    }

    private func menuStat(_ label: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.4)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(tint)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }
}


/// Help lives in its own scene, so the menu item needs the window-opening
/// action from the environment — available to a `Commands` type but not to
/// `App` itself.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("WiFi Signal Tester Help") {
                openWindow(id: WiFiSignalTesterApp.helpWindowID)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
