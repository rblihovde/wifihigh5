import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SurveysView: View {
    @EnvironmentObject private var monitor: WiFiMonitor
    @EnvironmentObject private var registry: APRegistry
    @EnvironmentObject private var store: SurveyStore
    @EnvironmentObject private var surveyUI: SurveyUI

    @State private var name = ""
    @State private var site = ""
    @State private var selected: SurveySession?
    @State private var saveError: String?
    @State private var opening: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UI.gap) {
                recordingCard
                alertCard
                if let err = saveError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.red)
                }
                if monitor.isRecording || !monitor.waypoints.isEmpty {
                    waypointsCard
                }
                savedCard
            }
            .padding(UI.gap)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(item: $selected) { session in
            SurveyDetailView(session: session)
                .environmentObject(registry)
        }
    }

    // MARK: Recording

    private var recordingCard: some View {
        Card("Walkthrough", systemImage: "figure.walk") {
            if let r = monitor.recording {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle().fill(.red).frame(width: 9, height: 9)
                            .opacity(0.9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name.isEmpty ? "Untitled walkthrough" : r.name)
                                .font(.system(size: 14, weight: .semibold))
                            if !r.site.isEmpty {
                                Text(r.site).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        stat("Elapsed", Fmt.duration(Date().timeIntervalSince(r.started)))
                        stat("Readings", "\(r.samples.count)")
                        stat("Waypoints", "\(monitor.waypoints.filter { $0.time >= r.started }.count)")
                    }

                    HStack(spacing: 8) {
                        Button {
                            surveyUI.captureWaypoint()
                        } label: {
                            Label("Mark Spot", systemImage: "mappin")
                        }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                        .help("Mark where you are right now (⌘M)")

                        Button("Stop & Save") { stopAndSave() }
                            .controlSize(.small)
                        Button("Discard", role: .destructive) { monitor.cancelRecording() }
                            .controlSize(.small)
                        Spacer()
                        Text("⌘M marks a spot without reaching for the mouse")
                            .font(.system(size: 10)).foregroundStyle(Color.subtle)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Record a walk through the building and every reading is kept, not just the last hour. Mark rooms as you go and the report reads back place by place.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField("Name, e.g. 2nd floor sweep", text: $name)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        TextField("Site or client", text: $site)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                        Button {
                            monitor.startRecording(name: name, site: site)
                        } label: {
                            Label("Start Recording", systemImage: "record.circle")
                        }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: Walking alert

    private var alertCard: some View {
        Card("While you walk", systemImage: "bell") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Toggle(isOn: $monitor.alertEnabled) {
                        Text("Sound an alert on weak signal").font(.system(size: 11.5))
                    }
                    .toggleStyle(.switch).controlSize(.mini)

                    Spacer()

                    if monitor.alertEnabled {
                        Text("Below").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Picker("", selection: $monitor.alertThreshold) {
                            Text("−60 dBm").tag(-60)
                            Text("−67 dBm").tag(-67)
                            Text("−70 dBm").tag(-70)
                            Text("−75 dBm").tag(-75)
                        }
                        .labelsHidden().pickerStyle(.segmented)
                        .controlSize(.small).frame(width: 300)
                    }
                }
                Text("Lets you watch the building instead of the screen. It sounds once when the signal drops through the threshold and re-arms after it recovers, so a reading sitting on the line will not chirp continuously.")
                    .font(.system(size: 10)).foregroundStyle(Color.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.4)
                .foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private func stopAndSave() {
        guard let session = monitor.finishRecording() else {
            saveError = "Nothing was recorded. The app captured no readings during the walk."
            return
        }
        if store.save(session) {
            saveError = nil
            name = ""; site = ""
        } else {
            saveError = "Could not write the walkthrough to disk. Check free space in \(store.storeLocation)."
        }
    }

    // MARK: Waypoints in progress

    private var waypointsCard: some View {
        Card("Marked spots", systemImage: "mappin.and.ellipse") {
            if monitor.waypoints.isEmpty {
                Text("No spots marked yet. Press ⌘M as you reach each room.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 5) {
                    ForEach(monitor.waypoints) { w in
                        HStack(spacing: 9) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.blue).font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.label).font(.system(size: 12, weight: .medium))
                                if !w.note.isEmpty {
                                    Text(w.note).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let r = w.rssi {
                                Text("\(r) dBm")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(SignalQuality(rssi: r).color)
                            }
                            Text(Fmt.clock.string(from: w.time))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button { monitor.removeWaypoint(id: w.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: Saved

    private var savedCard: some View {
        Card("Saved walkthroughs", systemImage: "tray.full") {
            if store.entries.isEmpty {
                Text("Nothing saved yet. Recorded walkthroughs are kept on this Mac and never leave it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.entries) { e in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(e.name.isEmpty ? "Untitled" : e.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                    if !e.site.isEmpty { Pill(text: e.site, tint: .secondary) }
                                }
                                Text("\(Fmt.stamp.string(from: e.started)) · \(Fmt.duration(e.duration)) · \(e.sampleCount) readings · \(e.waypointCount) spots · \(e.apCount) AP(s)")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let avg = e.averageRSSI {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("\(avg) dBm").font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(SignalQuality(rssi: avg).color)
                                    Text("average").font(.system(size: 9)).foregroundStyle(Color.subtle)
                                }
                            }
                            Button(opening == e.id ? "Opening…" : "Open") {
                                opening = e.id
                                Task {
                                    selected = await store.load(id: e.id)
                                    opening = nil
                                }
                            }
                            .controlSize(.small)
                            .disabled(opening != nil)
                            Button { store.delete(id: e.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete this walkthrough")
                        }
                        .padding(9)
                        .background(Color.hairline.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}
