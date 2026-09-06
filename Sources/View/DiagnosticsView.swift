import SwiftUI
import AppKit
import CoreLocation
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var registry: APRegistry
    @EnvironmentObject var gate: LocationGate
    @EnvironmentObject var netInfo: NetworkInfoModel
    @EnvironmentObject var vendors: VendorDatabase
    @State private var confirmClearSession = false
    @State private var exportError: String?

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: UI.gap, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: UI.gap) {
                permissionCard
                safetyCard
                samplingCard
                dataCard
            }
            .padding(UI.gap)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .confirmationDialog("Clear this monitoring session?",
                            isPresented: $confirmClearSession) {
            Button("Clear Session", role: .destructive) { monitor.clearSession() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The graph and connection-change history will be discarded. Saved access point names are not affected.")
        }
        .alert("Couldn’t Export Session", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "The file could not be written.")
        }
    }

    // MARK: Permissions

    private var permissionCard: some View {
        Card("Permissions", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(gate.isAuthorized ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("Location Services — \(statusText)")
                        .font(.system(size: 12, weight: .semibold))
                }

                Text("macOS treats the name of a Wi-Fi network as location data. Without this permission the system withholds the SSID, the BSSID and the country code from every app, including this one. Nothing else is affected: signal strength, noise, channel, width, PHY mode and transmit rate all read normally.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if gate.deniedWithoutPrompt || gate.status == .restricted {
                    calloutRow(
                        "The system denied the request without showing a prompt. That happens when Location Services is switched off for the whole Mac, or when a policy such as Screen Time’s Content & Privacy restrictions blocks changes to it. Check System Settings ▸ Privacy & Security ▸ Location Services, and Screen Time ▸ Content & Privacy ▸ Location Services.",
                        .orange)
                }

                HStack(spacing: 7) {
                    if gate.status == .notDetermined && !gate.deniedWithoutPrompt {
                        Button("Request Access") { gate.request() }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                    }
                    Button("Open Privacy Settings") { gate.openSettings() }.controlSize(.small)
                }

                Divider()
                capabilityRow("Signal, noise, SNR", true)
                capabilityRow("Channel, band, width, PHY mode", true)
                capabilityRow("Transmit rate and power", true)
                capabilityRow("IP, DNS, DHCP, gateway", true)
                capabilityRow("Network name (SSID)", gate.isAuthorized)
                capabilityRow("Access point BSSID", gate.isAuthorized)
                capabilityRow("Regulatory country code", gate.isAuthorized)

                if !gate.isAuthorized {
                    Text("Without a BSSID, access points are told apart by a radio fingerprint of SSID, channel, band and security instead. That is enough to spot most roams, but two APs sharing a channel will look like one.")
                        .font(.system(size: 10.5)).foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusText: String {
        if gate.isAuthorized { return "granted" }
        switch gate.status {
        case .denied: return "denied"
        case .restricted: return "restricted by policy"
        case .notDetermined: return "not granted"
        default: return "unavailable"
        }
    }

    private func capabilityRow(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(ok ? .green : .orange)
            Text(label).font(.system(size: 11))
                .foregroundStyle(ok ? .primary : .secondary)
            Spacer()
        }
    }

    // MARK: Safety

    private var safetyCard: some View {
        Card("What this app does on a client network", systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Written to be defensible if someone onsite asks what you are running.")
                    .font(.system(size: 10.5)).foregroundStyle(Color.subtle)

                group("It reads", [
                    "The state of the link this Mac has already joined, from the OS.",
                    "IP, DNS, DHCP and gateway settings this Mac was assigned.",
                    "Existing ARP cache entries for the passive Observed Devices view."
                ], .green, "checkmark")

                group("It does not", [
                    "Capture, inspect or decode any traffic.",
                    "Probe, port-scan or fingerprint other hosts.",
                    "Attempt to join networks or handle credentials.",
                    "Send telemetry or use cloud services. The app has no accounts."
                ], .secondary, "xmark")

                group("It transmits only when you ask", [
                    "Scan Now sends probe requests, the same frames as joining a network.",
                    "Gateway ping sends ICMP echo to your own default router, and nowhere else."
                ], .orange, "exclamationmark")

                Text("Both transmitting features are off until you switch them on, and each is labelled where it appears.")
                    .font(.system(size: 10.5)).foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func group(_ title: String, _ items: [String], _ tint: Color, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 10)
                        .padding(.top, 2)
                    Text(item).font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func calloutRow(_ text: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(tint)
            Text(text).font(.system(size: 10.5)).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Sampling

    private var samplingCard: some View {
        Card("Sampling", systemImage: "timer") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Interval").font(.system(size: 11)).frame(width: 90, alignment: .leading)
                    Picker("", selection: $monitor.interval) {
                        Text("0.5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 220)
                }
                HStack {
                    Text("Monitoring").font(.system(size: 11)).frame(width: 90, alignment: .leading)
                    Button(monitor.isRunning ? "Pause" : "Resume") { monitor.toggle() }
                        .controlSize(.small)
                    Button("Clear Session…") { confirmClearSession = true }.controlSize(.small)
                        .disabled(monitor.samples.isEmpty && monitor.roamEvents.isEmpty)
                }
                InfoRow(label: "Session length", value: Fmt.duration(monitor.sessionDuration))
                InfoRow(label: "Samples held", value: "\(monitor.samples.count) (rolling 1-hour history)")
                Text("History is kept in memory only and starts fresh each launch. Export before you quit if you need to keep it.")
                    .font(.system(size: 10)).foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Data

    private var dataCard: some View {
        Card("Local data", systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Access point nicknames and saved walkthroughs are written to disk on this Mac only.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(registry.storeLocation)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.hairline.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))

                if let error = registry.persistenceError {
                    calloutRow(error, .red)
                }

                HStack(spacing: 7) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: registry.storeLocation)
                        ])
                    }.controlSize(.small)
                    Button("Export Session CSV…") { exportCSV() }
                        .controlSize(.small)
                        .disabled(monitor.samples.isEmpty)
                }

                Divider()
                InfoRow(label: "Vendor database",
                        value: vendors.isReady
                            ? "\(vendors.recordCount) blocks · IEEE \(vendors.retrieved ?? "unknown date")"
                            : "loading…",
                        help: "Embedded copy of the IEEE MAC registry. Never fetched at runtime; refresh with tools/update-oui.sh.")
                InfoRow(label: "Saved APs", value: "\(registry.records.count)")
                InfoRow(label: "Interface", value: monitor.current?.interfaceName ?? "—", mono: true)
                InfoRow(label: "Primary service", value: netInfo.config.primaryInterface ?? "—", mono: true)
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wifi-session-\(Int(Date().timeIntervalSince1970)).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Every sample in this session, with nicknames resolved."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try monitor.exportCSV().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
