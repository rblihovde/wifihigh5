import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Passive view of IPv4 devices already present in the Mac's ARP cache.
struct ObservedDevicesView: View {
    @EnvironmentObject private var monitor: WiFiMonitor
    @EnvironmentObject private var netInfo: NetworkInfoModel
    @EnvironmentObject private var vendors: VendorDatabase
    @EnvironmentObject private var devices: DeviceRegistry
    @EnvironmentObject private var presence: DevicePresence
    @EnvironmentObject private var discovery: DeviceDiscovery

    @State private var searchText = ""
    @State private var sort: DeviceSort = .address
    @State private var showDeparted = true
    @State private var editingMAC: String?
    @State private var fileMessage: String?
    @State private var confirmingBonjour = false
    @State private var confirmingDNS = false

    private var activeInterface: String? {
        monitor.current?.interfaceName ?? netInfo.config.primaryInterface
    }

    /// Entries the kernel currently holds for this subnet, before any
    /// presentation decisions are made.
    private var cached: [ARPEntry] {
        ARPTable.devicesOnActiveSubnet(
            netInfo.arpEntries,
            interface: activeInterface,
            localAddress: netInfo.config.ipv4,
            mask: netInfo.config.subnetMask
        )
    }

    private var rows: [ObservedDevice] {
        sorted(ObservedDeviceBuilder.rows(
            arp: netInfo.arpEntries,
            config: netInfo.config,
            interface: activeInterface,
            bssid: monitor.current?.bssid,
            labels: devices,
            vendors: vendors,
            presence: presence,
            discovery: discovery,
            includeDeparted: showDeparted))
    }

    private func sorted(_ list: [ObservedDevice]) -> [ObservedDevice] {
        // Present devices always precede departed ones, whatever the sort.
        func before(_ a: ObservedDevice, _ b: ObservedDevice) -> Bool {
            if a.isPresent != b.isPresent { return a.isPresent }
            switch sort {
            case .address:
                if a.role.sortRank != b.role.sortRank { return a.role.sortRank < b.role.sortRank }
                return ipValue(a.ip) < ipValue(b.ip)
            case .role:
                if a.role.sortRank != b.role.sortRank { return a.role.sortRank < b.role.sortRank }
                return ipValue(a.ip) < ipValue(b.ip)
            case .name:
                let l = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
                return l == .orderedSame ? ipValue(a.ip) < ipValue(b.ip) : l == .orderedAscending
            case .manufacturer:
                let l = a.vendorText.localizedCaseInsensitiveCompare(b.vendorText)
                return l == .orderedSame ? ipValue(a.ip) < ipValue(b.ip) : l == .orderedAscending
            case .firstSeen:
                let x = a.sighting?.firstSeen ?? .distantPast
                let y = b.sighting?.firstSeen ?? .distantPast
                return x == y ? ipValue(a.ip) < ipValue(b.ip) : x > y
            }
        }
        return list.sorted(by: before)
    }

    private func ipValue(_ address: String) -> UInt32 {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return .max }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return .max }
            value = (value << 8) | UInt32(octet)
        }
        return value
    }

    private var visible: [ObservedDevice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.searchHaystack.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            passiveNotice
            if let fileMessage {
                InlineNotice(text: fileMessage) { self.fileMessage = nil }
            }
            if let discoveryMessage = discovery.message {
                InlineNotice(text: discoveryMessage) { discovery.clearMessage() }
            }

            let all = rows
            if all.isEmpty {
                EmptyHint(
                    systemImage: "desktopcomputer.and.macbook",
                    title: "No devices observed",
                    message: emptyMessage,
                    action: (label: "Refresh Cache", run: netInfo.refreshARP)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        summary(all)
                        columnHeader
                        let shown = visible
                        ForEach(shown) { device in
                            deviceRow(device)
                        }
                        if shown.isEmpty {
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
        .alert("Ask the devices on this network to identify themselves?",
               isPresented: $confirmingBonjour) {
            Button("Cancel", role: .cancel) { }
            Button("Send Queries") { discovery.browse() }
        } message: {
            Text(Warning.bonjour)
        }
        .alert("Ask this network's DNS server to name these addresses?",
               isPresented: $confirmingDNS) {
            Button("Cancel", role: .cancel) { }
            Button("Look Up Names") {
                discovery.resolveNames(for: rows.filter(\.isPresent).map(\.ip))
            }
        } message: {
            Text(Warning.reverseDNS)
        }
        .onAppear { netInfo.refreshARP() }
        // These mutate observed state, so they must not run inside the view
        // update that is reading it. Hopping to the next main-actor turn keeps
        // the publish out of the current render pass; doing it inline corrupts
        // the layout of the whole split view, not just this pane.
        // Watching the filtered list rather than the raw cache matters: the
        // filter needs the IP settings, which arrive after the entries do, so
        // keying off the raw cache misses the moment the list first has
        // content and nothing is ever recorded as present.
        .onChange(of: cached) { _, observed in
            Task { @MainActor in presence.note(observed) }
        }
        .onChange(of: activeInterface) { _, _ in
            Task { @MainActor in presence.reset() }
        }
        .onChange(of: netInfo.config.ipv4) { _, _ in
            Task { @MainActor in presence.reset() }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            netInfo.refreshARP()
        }
    }

    // MARK: Chrome

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

            TextField("Filter devices", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, idealWidth: 240, maxWidth: 280)

            Picker("Sort", selection: $sort) {
                ForEach(DeviceSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 150)

            Toggle("Show departed", isOn: $showDeparted)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Keep devices in the list after they drop out of the cache, so you can see what left.")

            Spacer()

            Menu {
                Button("Ask Devices to Identify Themselves…") { confirmingBonjour = true }
                    .disabled(discovery.isBrowsing)
                Button("Look Up Names in DNS…") { confirmingDNS = true }
                    .disabled(discovery.isResolvingNames)
                Divider()
                Button("Discard Discovered Names", role: .destructive) { discovery.clear() }
                    .disabled(!discovery.hasFindings)
            } label: {
                Label("Identify", systemImage: "questionmark.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(width: 92)
            .help("Sends queries to devices. Each option explains what it does before anything is sent.")

            Menu {
                Button("Export Device List as CSV…", action: exportCSV)
                Divider()
                Button("Export Labels…", action: exportLabels)
                Button("Import Labels…", action: importLabels)
                Divider()
                Button("Forget All Labels", role: .destructive) {
                    devices.forgetAll()
                    fileMessage = "All saved device labels were removed from this Mac."
                }
                .disabled(devices.labelledCount == 0)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(width: 90)

            if let lastRefresh = netInfo.lastARPRefresh {
                Text("Updated \(Fmt.relativeTime(lastRefresh))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if discovery.isBrowsing || discovery.isResolvingNames {
                Pill(text: "SENDING", tint: .orange, filled: true)
                    .help("A discovery you approved is running. It stops on its own.")
            } else {
                Pill(text: "PASSIVE", tint: .green)
                    .help("This view reads the existing neighbour cache and sends nothing.")
            }
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
                Text("Reads the neighbour cache macOS already keeps for traffic this Mac has exchanged. It does not probe devices, scan ports, sweep addresses, or send any packet. Quiet, isolated and IPv6-only devices will not appear. Identify can ask devices for their names, and tells you exactly what it sends before it sends anything. Names you assign are stored on this Mac only.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    // Wraps to fit, but never grows without bound. Without a
                    // line limit a narrow proposed width makes this text
                    // thousands of points tall, which pushes the toolbar off
                    // the top of the window and the sidebar off the bottom.
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.08))
    }

    private func summary(_ all: [ObservedDevice]) -> some View {
        let present = all.filter(\.isPresent)
        let arrived = present.filter(\.isNew).count
        let departed = all.filter { !$0.isPresent }.count
        let priv = present.filter(\.isLocallyAdministered).count
        let named = present.filter { $0.nickname != nil }.count

        return HStack(spacing: 8) {
            SummaryChip(value: "\(present.count)", label: "on this subnet", tint: .blue)
            SummaryChip(value: "\(arrived)", label: "arrived while watching",
                        tint: arrived > 0 ? .orange : .secondary)
            SummaryChip(value: "\(departed)", label: "dropped out",
                        tint: departed > 0 ? .secondary : .secondary)
            SummaryChip(value: "\(priv)", label: "private addresses",
                        tint: priv > 0 ? .orange : .secondary)
            SummaryChip(value: "\(named)", label: "named by you", tint: .green)
            if discovery.hasFindings {
                SummaryChip(value: "\(present.filter(\.wasDiscovered).count)",
                            label: "identified by asking", tint: .blue)
            }
            Spacer()
            Text("Watching for \(Fmt.duration(Date().timeIntervalSince(presence.watchingSince)))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 2)
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("DEVICE").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            Text("IP ADDRESS").frame(width: 118, alignment: .leading)
                .explains("IP address", affordance: .highlight)
            Text("MAC ADDRESS").frame(width: 140, alignment: .leading)
                .explains("MAC address", affordance: .highlight)
            Text("MANUFACTURER").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                .explains("Hardware vendors", affordance: .highlight)
            Text("SEEN").frame(width: 96, alignment: .leading)
        }
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: Rows

    private func deviceRow(_ device: ObservedDevice) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(device.tint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(device.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        if device.wasDiscovered {
                            Pill(text: "ASKED", tint: .blue)
                        }
                        if device.isNew { Pill(text: "NEW", tint: .orange) }
                        if !device.isPresent { Pill(text: "GONE", tint: .secondary) }
                        if device.isLocallyAdministered { Pill(text: "PRIVATE", tint: .orange) }
                    }
                    Text(subtitle(device))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            Text(device.ip)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(width: 118, alignment: .leading)

            Text(device.mac)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(width: 140, alignment: .leading)

            Text(device.vendorText)
                .font(.system(size: 11))
                .foregroundStyle(device.isLocallyAdministered ? Color.orange : Color.primary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

            Text(seenText(device))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
        }
        .padding(12)
        .opacity(device.isPresent ? 1 : 0.55)
        .background(Color.cardBG, in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(
            RoundedRectangle(cornerRadius: UI.radius)
                .strokeBorder(device.isNew ? Color.orange.opacity(0.5) : Color.hairline.opacity(0.6),
                              lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editingMAC = device.mac }
        .contextMenu { rowMenu(device) }
        .popover(isPresented: Binding(
            get: { editingMAC == device.mac },
            set: { if !$0 { editingMAC = nil } }
        ), arrowEdge: .trailing) {
            DeviceLabelEditor(device: device)
                .environmentObject(devices)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(device))
    }

    @ViewBuilder
    private func rowMenu(_ device: ObservedDevice) -> some View {
        Button("Name This Device…") { editingMAC = device.mac }
        Divider()
        Button("Copy IP Address") { copy(device.ip) }
        Button("Copy MAC Address") { copy(device.mac) }
        Button("Copy Row") {
            copy("\(device.displayName)\t\(device.ip)\t\(device.mac)\t\(device.vendorText)")
        }
        if device.record != nil {
            Divider()
            Button("Forget This Label", role: .destructive) { devices.forget(mac: device.mac) }
        }
    }

    private func subtitle(_ device: ObservedDevice) -> String {
        var parts: [String] = []

        // The role, unless the row is already named after it.
        if device.role != .device, device.displayName != device.role.label {
            parts.append(device.role.label)
        }
        if let model = device.finding?.model { parts.append(model) }

        // What the user filed it under wins over what the maker suggests, and a
        // guess is dropped when it would only restate something already on the
        // row: "MacBookPro18,3 · MacBook" and "iphone / iPhone" say one thing
        // twice.
        if device.category != .unlabelled {
            parts.append(device.category.label)
        } else if let guess = device.guess, !restatesTheRow(guess, device) {
            parts.append(guess.summary)
        }

        if let services = device.finding?.services, !services.isEmpty {
            parts.append(services.sorted().joined(separator: ", "))
        }
        if let notes = device.record?.notes, !notes.isEmpty { parts.append(notes) }

        if parts.isEmpty {
            if let basis = device.role.basis { return basis }
            return device.isLocallyAdministered
                ? "Software-assigned address; the prefix identifies no manufacturer"
                : "Hardware address"
        }
        return parts.joined(separator: " · ")
    }

    /// True when a guess would only repeat what the row already shows.
    private func restatesTheRow(_ guess: DeviceGuess, _ device: ObservedDevice) -> Bool {
        switch guess.source {
        case .model:
            return device.finding?.model != nil
        case .name:
            // The name is where the guess came from, so if the row is already
            // showing it there is nothing left to add: "Alex's MacBook Air ·
            // MacBook Air" says one thing twice.
            return device.displayName.range(of: guess.summary,
                                            options: .caseInsensitive) != nil
        case .services, .manufacturer:
            return false
        }
    }

    private func seenText(_ device: ObservedDevice) -> String {
        if device.role == .thisMac { return "—" }
        guard let sighting = device.sighting else { return "In cache" }
        if !device.isPresent { return "Left \(Fmt.relativeTime(sighting.lastSeen))" }
        if sighting.arrivedWhileWatching { return "Arrived \(Fmt.relativeTime(sighting.firstSeen))" }
        return "Present"
    }

    private func accessibilityText(_ device: ObservedDevice) -> String {
        var text = "\(device.displayName), IP \(device.ip), MAC \(device.mac), \(device.vendorText)"
        if device.isNew { text += ", arrived while watching" }
        if !device.isPresent { text += ", no longer in the cache" }
        return text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var emptyMessage: String {
        if activeInterface == nil || netInfo.config.ipv4 == nil || netInfo.config.subnetMask == nil {
            return "Waiting for the active Wi-Fi interface and IPv4 settings."
        }
        return "The Mac's neighbour cache does not currently hold another device on this Wi-Fi subnet. Using the network normally will add entries. This view does not generate traffic to find them."
    }

    // MARK: Files

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "observed-devices.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Save the devices currently listed. The file contains only what is on screen."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = ReportBuilder.deviceCSV(visible, networkName: monitor.current?.ssid)
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            fileMessage = "Exported \(visible.count) device\(visible.count == 1 ? "" : "s")."
        } catch {
            fileMessage = "The file could not be exported: \(error.localizedDescription)"
        }
    }

    private func exportLabels() {
        guard let data = devices.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "device-labels.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Save your device names. This file stays local unless you move it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            fileMessage = "Saved \(devices.labelledCount) device label\(devices.labelledCount == 1 ? "" : "s")."
        } catch {
            fileMessage = "The file could not be exported: \(error.localizedDescription)"
        }
    }

    private func importLabels() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an exported device label file. Existing names are kept on conflict."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let added = devices.importJSON(data) else {
                fileMessage = "That file is not a valid WifiHigh5 device label export."
                return
            }
            fileMessage = added == 0
                ? "Nothing new was imported. Your existing names were kept."
                : "Imported \(added) device label\(added == 1 ? "" : "s"). Existing names were kept."
        } catch {
            fileMessage = "The file could not be opened: \(error.localizedDescription)"
        }
    }
}

// MARK: - Pieces

private struct SummaryChip: View {
    var value: String
    var label: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.cardBG, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.hairline.opacity(0.6), lineWidth: 1))
    }
}

private struct InlineNotice: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text(text).font(.system(size: 11))
            Spacer()
            Button("Dismiss", action: dismiss)
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.blue.opacity(0.08))
    }
}

/// Names a device. Everything typed here stays on this Mac.
private struct DeviceLabelEditor: View {
    @EnvironmentObject private var devices: DeviceRegistry
    @Environment(\.dismiss) private var dismiss

    var device: ObservedDevice

    @State private var nickname = ""
    @State private var notes = ""
    @State private var category: DeviceCategory = .unlabelled
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name this device")
                .font(.system(size: 12, weight: .semibold))
            Text("\(device.ip) · \(device.mac)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField("Nickname, e.g. Reception printer", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            Picker("Type", selection: $category) {
                ForEach(DeviceCategory.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.menu)

            TextField("Notes, e.g. server room rack 2", text: $notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            Text("Saved on this Mac only, and only while this device has a name, type or note.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if device.record != nil {
                    Button("Forget", role: .destructive) {
                        devices.forget(mac: device.mac)
                        dismiss()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Done") { commit(); dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            guard !loaded else { return }
            nickname = device.record?.nickname ?? ""
            notes = device.record?.notes ?? ""
            category = device.category
            loaded = true
        }
    }

    private func commit() {
        devices.setNickname(nickname, forMAC: device.mac, currentIP: device.ip)
        devices.setNotes(notes, forMAC: device.mac, currentIP: device.ip)
        devices.setCategory(category, forMAC: device.mac, currentIP: device.ip)
    }
}

/// The text shown before anything is transmitted.
///
/// Each one says what is sent, what comes back, where it will show up
/// afterwards, and what the feature is for. A person about to run this on a
/// client's network should be able to decide from this alone.
enum Warning {

    static let bonjour = """
        This sends Bonjour queries to every device on this subnet and asks any that answer to describe itself. Until now this tab has only read a cache your Mac already had.

        WHAT YOU GET
        The name a device publishes for itself, what it offers — printing, AirPlay, file sharing, screen sharing — and sometimes a model.

        WHAT IT COSTS
        These queries are visible to anything watching the network. Ordinary Macs, iPhones and printers send them constantly, so one is unremarkable; a burst from a single machine can still be logged as network discovery, and some monitoring treats discovery as reconnaissance.

        WHEN TO USE IT
        On a network you have been asked to work on, to put names to devices you are responsible for. Not to survey a network that is not yours.
        """

    static let reverseDNS = """
        This sends one reverse lookup per address to the name servers this network gave your Mac.

        WHAT YOU GET
        Hostnames, on a network that keeps DNS records for its own clients. Home and small-office networks usually keep none and will return nothing at all.

        WHAT IT COSTS
        The DNS server logs every lookup, recording this Mac as the source alongside each internal address you asked about. DNS logs are reviewed far more often than Wi-Fi traffic, and a run of reverse lookups across one subnet reads plainly as someone enumerating the network.

        WHEN TO USE IT
        On a managed network where you have been asked to document what is connected.
        """
}
