import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Manages the local nickname catalogue for every AP this Mac has seen.
struct AccessPointsView: View {
    @EnvironmentObject var registry: APRegistry
    @EnvironmentObject var monitor: WiFiMonitor

    @State private var search = ""
    @State private var editingKey: APKey?
    @State private var confirmForgetAll = false
    @State private var pendingForget: APKey?
    @State private var fileMessage: String?

    private var rows: [APRecord] {
        let all = registry.allRecords
        guard !search.isEmpty else { return all }
        let q = search.lowercased()
        return all.filter {
            $0.nickname.lowercased().contains(q)
            || $0.site.lowercased().contains(q)
            || ($0.lastSSID ?? "").lowercased().contains(q)
            || $0.keyRaw.lowercased().contains(q)
            || $0.notes.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if rows.isEmpty {
                EmptyHint(
                    systemImage: "wifi.router",
                    title: search.isEmpty ? "No access points recorded yet" : "No matches",
                    message: search.isEmpty
                        ? "Every AP this Mac associates with is added here automatically. Give one a nickname and it shows up by that name on the live graph."
                        : "No saved access point matches “\(search)”."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { rec in row(rec) }
                    }
                    .padding(UI.gap)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .confirmationDialog("Forget this access point?", isPresented: Binding(
            get: { pendingForget != nil },
            set: { if !$0 { pendingForget = nil } }
        )) {
            Button("Forget Access Point", role: .destructive) {
                if let key = pendingForget { registry.forget(key: key) }
                pendingForget = nil
            }
            Button("Cancel", role: .cancel) { pendingForget = nil }
        } message: {
            Text("Its nickname, site, notes, and saved signal range will be removed. It will be added again if this Mac reconnects to it.")
        }
        .alert("Access Point File", isPresented: Binding(
            get: { fileMessage != nil },
            set: { if !$0 { fileMessage = nil } }
        )) {
            Button("OK") { fileMessage = nil }
        } message: {
            Text(fileMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Search nicknames, sites, SSIDs, BSSIDs", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            Spacer()
            Text("\(rows.count) access point\(rows.count == 1 ? "" : "s")")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            Button("Export…") { exportMap() }.controlSize(.small)
            Button("Import…") { importMap() }.controlSize(.small)
            Button("Forget All", role: .destructive) { confirmForgetAll = true }
                .controlSize(.small)
                .confirmationDialog("Delete every saved nickname?",
                                    isPresented: $confirmForgetAll) {
                    Button("Delete All", role: .destructive) { registry.forgetAll() }
                } message: {
                    Text("This clears all nicknames, sites and notes stored on this Mac. It cannot be undone.")
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row(_ rec: APRecord) -> some View {
        let key = rec.key
        let isCurrent = monitor.currentKeyValue == key
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(rec.color).frame(width: 12, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rec.hasNickname ? rec.nickname : registry.displayName(for: key,
                            fallbackChannel: rec.lastChannel, fallbackBand: rec.lastBandRaw))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(rec.hasNickname ? .primary : .secondary)
                    if isCurrent { Pill(text: "CONNECTED", tint: .green, filled: true) }
                    if !rec.site.isEmpty { Pill(text: rec.site, tint: .secondary) }
                    if !key.isPreciseIdentity { Pill(text: "FINGERPRINT", tint: .orange) }
                }
                HStack(spacing: 6) {
                    Text(key.bssidValue ?? "no BSSID")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let ssid = rec.lastSSID {
                        Text("·").foregroundStyle(.tertiary)
                        Text(ssid).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let ch = rec.lastChannel {
                        Text("·").foregroundStyle(.tertiary)
                        Text("Ch \(ch) · \(bandLabel(rec.lastBandRaw ?? 0).short)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            if let b = rec.bestRSSI, let w = rec.worstRSSI {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(w) … \(b) dBm")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SignalQuality(rssi: b).color)
                    Text("range seen").font(.system(size: 9)).foregroundStyle(Color.subtle)
                }
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.relativeTime(rec.lastSeen))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .help(Fmt.stamp.string(from: rec.lastSeen))
                Text("last seen").font(.system(size: 9)).foregroundStyle(Color.subtle)
            }

            Button { editingKey = key } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Edit nickname")
            Button { pendingForget = key } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Forget this access point")
        }
        .padding(10)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius)
            .strokeBorder(isCurrent ? Color.green.opacity(0.5) : Color.hairline.opacity(0.6),
                          lineWidth: isCurrent ? 1.5 : 1))
        .popover(isPresented: Binding(
            get: { editingKey == key },
            set: { if !$0 { editingKey = nil } }
        ), arrowEdge: .trailing) {
            NicknameEditor(key: key, sample: isCurrent ? monitor.current : nil)
                .environmentObject(registry)
        }
    }

    // MARK: Import / export

    private func exportMap() {
        guard let data = registry.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wifi-access-points.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Save your access point nicknames. This file stays local unless you move it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            fileMessage = "The file could not be exported: \(error.localizedDescription)"
        }
    }

    private func importMap() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an exported access point file. Existing nicknames are kept on conflict."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let changed = registry.importJSON(data) else {
                fileMessage = "That file is not a valid WifiHigh5 access point export."
                return
            }
            fileMessage = changed == 0
                ? "Nothing new was imported. Your existing names and notes were kept."
                : "Imported details for \(changed) access point\(changed == 1 ? "" : "s"). Existing names and notes were kept."
        } catch {
            fileMessage = "The file could not be opened: \(error.localizedDescription)"
        }
    }
}

// MARK: - Roam log

struct RoamLogView: View {
    @EnvironmentObject var monitor: WiFiMonitor
    @EnvironmentObject var registry: APRegistry
    @State private var confirmClearSession = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                let changes = monitor.roamEvents.filter { $0.reason.countsAsConnectionChange }.count
                Text("\(changes) connection change\(changes == 1 ? "" : "s") this session")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Session…") { confirmClearSession = true }.controlSize(.small)
                    .disabled(monitor.samples.isEmpty && monitor.roamEvents.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if monitor.roamEvents.isEmpty {
                EmptyHint(systemImage: "arrow.left.arrow.right",
                          title: "No transitions recorded",
                          message: "Every association, roam and reconnect gets logged here with the signal on both sides of the change. Walk the site and watch it fill in.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(monitor.roamEvents.reversed()) { ev in eventRow(ev) }
                    }
                    .padding(UI.gap)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .confirmationDialog("Clear this monitoring session?",
                            isPresented: $confirmClearSession) {
            Button("Clear Session", role: .destructive) { monitor.clearSession() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The graph and connection-change history will be discarded. Saved access point names are not affected.")
        }
    }

    private func eventRow(_ ev: RoamEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ev.reason.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(registry.color(for: ev.toKey))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ev.reason.label).font(.system(size: 12, weight: .semibold))
                    Text(Fmt.stamp.string(from: ev.time))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let from = ev.fromKey {
                        APChip(name: registry.displayName(for: from),
                               color: registry.color(for: from),
                               subtitle: ev.fromChannel.map { "Ch \($0)" },
                               isPrecise: from.isPreciseIdentity)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    APChip(name: registry.displayName(for: ev.toKey),
                           color: registry.color(for: ev.toKey),
                           subtitle: "Ch \(ev.toChannel)",
                           isPrecise: ev.toKey.isPreciseIdentity)
                }
            }

            Spacer(minLength: 8)

            if let from = ev.fromRSSI {
                HStack(spacing: 4) {
                    Text("\(from)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SignalQuality(rssi: from).color)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Text("\(ev.toRSSI)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SignalQuality(rssi: ev.toRSSI).color)
                }
            } else {
                Text("\(ev.toRSSI) dBm").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SignalQuality(rssi: ev.toRSSI).color)
            }

            if let d = ev.delta {
                Pill(text: d >= 0 ? "+\(d) dB" : "\(d) dB",
                     tint: d >= 0 ? .green : .orange)
                    .help(d >= 0 ? "Roamed to a stronger radio." : "Roamed to a weaker radio. This can indicate a sticky client.")
            }
        }
        .padding(10)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius)
            .strokeBorder(Color.hairline.opacity(0.6), lineWidth: 1))
    }
}
