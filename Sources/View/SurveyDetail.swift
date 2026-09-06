import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Reads a saved walkthrough back place by place, which is how it was walked.
struct SurveyDetailView: View {
    @EnvironmentObject private var registry: APRegistry
    @Environment(\.dismiss) private var dismiss

    let session: SurveySession
    @State private var exportMessage: String?

    private var legs: [(waypoint: Waypoint, samples: [WiFiSample])] {
        session.waypoints.sorted { $0.time < $1.time }.map { ($0, session.leg(for: $0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: UI.gap) {
                    summaryCard
                    if legs.isEmpty {
                        Card("Marked spots", systemImage: "mappin") {
                            Text("No spots were marked during this walk. Press ⌘M while recording to label each room. The report groups readings by room.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        legsCard
                    }
                    apCard
                }
                .padding(UI.gap)
            }
        }
        .frame(width: 780, height: 620)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name.isEmpty ? "Untitled walkthrough" : session.name)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(session.site.isEmpty ? "" : session.site + " · ")\(Fmt.stamp.string(from: session.started)) · \(Fmt.duration(session.duration))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if let msg = exportMessage {
                Text(msg).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button("Export Report…") { exportReport() }
                .controlSize(.small).buttonStyle(.borderedProminent)
            Button("Export CSV…") { exportCSV() }
                .controlSize(.small)
            Button("Done") { dismiss() }
                .controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var summaryCard: some View {
        Card("Summary", systemImage: "chart.bar") {
            let values = session.samples.map(\.rssi)
            HStack(alignment: .top, spacing: 0) {
                StatTile(label: "Readings", value: "\(session.samples.count)")
                StatTile(label: "Duration", value: Fmt.duration(session.duration))
                if let mn = values.min() {
                    StatTile(label: "Worst", value: "\(mn)", unit: "dBm",
                             tint: SignalQuality(rssi: mn).color)
                }
                if !values.isEmpty {
                    let avg = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
                    StatTile(label: "Average", value: "\(avg)", unit: "dBm",
                             tint: SignalQuality(rssi: avg).color)
                }
                StatTile(label: "Spots", value: "\(session.waypoints.count)")
                StatTile(label: "Access points", value: "\(session.apKeys.count)")
                StatTile(label: "Changes", value: "\(max(0, session.roamEvents.count - 1))")
            }
        }
    }

    private var legsCard: some View {
        Card("By marked spot", systemImage: "mappin.and.ellipse") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("SPOT").frame(width: 150, alignment: .leading)
                    Text("TIME").frame(width: 62, alignment: .leading)
                    Text("HELD").frame(width: 54, alignment: .leading)
                    Text("AVG").frame(width: 58, alignment: .trailing)
                    Text("WORST").frame(width: 58, alignment: .trailing)
                    Text("ACCESS POINT").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.4)
                .foregroundStyle(.secondary)
                .padding(.bottom, 5)

                ForEach(legs, id: \.waypoint.id) { leg in
                    let values = leg.samples.map(\.rssi)
                    let avg = values.isEmpty ? leg.waypoint.rssi
                        : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
                    let worst = values.min() ?? leg.waypoint.rssi
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(leg.waypoint.label)
                                .font(.system(size: 11.5, weight: .medium))
                            if !leg.waypoint.note.isEmpty {
                                Text(leg.waypoint.note)
                                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 150, alignment: .leading)

                        Text(Fmt.clock.string(from: leg.waypoint.time))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).frame(width: 62, alignment: .leading)

                        Text(leg.samples.isEmpty ? "—"
                             : Fmt.duration(Double(leg.samples.count) * session.sampleInterval))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).frame(width: 54, alignment: .leading)

                        Text(avg.map { "\($0)" } ?? "—")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(avg.map { SignalQuality(rssi: $0).color } ?? .secondary)
                            .frame(width: 58, alignment: .trailing)

                        Text(worst.map { "\($0)" } ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(worst.map { SignalQuality(rssi: $0).color } ?? .secondary)
                            .frame(width: 58, alignment: .trailing)

                        if let key = leg.samples.last?.apKey ?? leg.waypoint.apKey {
                            APChip(name: registry.displayName(for: key),
                                   color: registry.color(for: key),
                                   isPrecise: key.isPreciseIdentity)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("—").font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 5)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private var apCard: some View {
        Card("Access points seen", systemImage: "wifi.router") {
            VStack(spacing: 5) {
                ForEach(session.apKeys, id: \.raw) { key in
                    let forThis = session.samples.filter { $0.apKey == key }
                    let values = forThis.map(\.rssi)
                    HStack(spacing: 9) {
                        APChip(name: registry.displayName(for: key),
                               color: registry.color(for: key),
                               subtitle: key.bssidValue,
                               isPrecise: key.isPreciseIdentity)
                        Spacer()
                        Text("\(forThis.count) readings")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if let mn = values.min(), let mx = values.max() {
                            Text("\(mn) … \(mx) dBm")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(SignalQuality(rssi: mx).color)
                        }
                    }
                }
            }
        }
    }

    // MARK: Export

    private func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeName()).html"
        panel.allowedContentTypes = [.html]
        panel.message = "A self-contained report you can open in any browser or print to PDF."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = ReportBuilder.html(for: session, registry: registry)
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Report saved."
        } catch {
            exportMessage = "Could not write the report."
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeName()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = ReportBuilder.csv(for: session, registry: registry)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "CSV saved."
        } catch {
            exportMessage = "Could not write the CSV."
        }
    }

    private func safeName() -> String {
        let base = session.name.isEmpty ? "walkthrough" : session.name
        return base.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ":", with: "-")
    }
}
