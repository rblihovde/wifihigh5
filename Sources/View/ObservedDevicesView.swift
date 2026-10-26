import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Passive IPv4/IPv6 neighbours plus explicitly requested active scans.
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
    @State private var inspectingMAC: String?
    @State private var fileMessage: String?
    @State private var confirmingBonjour = false
    @State private var confirmingDNS = false
    @State private var confirmingLANScan = false
    @AppStorage("deviceColumns.addresses") private var showAddresses = true
    @AppStorage("deviceColumns.mac") private var showMAC = true
    @AppStorage("deviceColumns.vendor") private var showVendor = true
    @AppStorage("deviceColumns.services") private var showServices = false
    @AppStorage("deviceColumns.seen") private var showSeen = true

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
            ipv6: netInfo.ipv6Neighbors,
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
                discovery.resolveNames(for: rows.filter(\.isPresent)
                    .flatMap { [$0.ip] + $0.ipv6Addresses })
            }
        } message: {
            Text(Warning.reverseDNS)
        }
        .sheet(isPresented: $confirmingLANScan) {
            LANScanOptionsSheet(localAddress: netInfo.config.ipv4,
                                subnetMask: netInfo.config.subnetMask) { options in
                startLANScan(options)
            }
        }
        .onAppear {
            netInfo.beginARPPolling()
            // onChange fires on changes only. When the cache is already
            // populated as this pane opens — which it is whenever the map has
            // been visited — nothing changes, so without seeding here the
            // baseline is never taken and every row reads "In cache" forever.
            let observed = cached
            if !observed.isEmpty {
                Task { @MainActor in presence.note(observed) }
            }
        }
        // Two things matter here. The mutation must not run inside the view
        // update that reads it, so it hops to the next main-actor turn;
        // publishing inline corrupts the layout of the whole split view rather
        // than just this pane. And it watches the filtered list rather than the
        // raw cache, because the filter needs IP settings that arrive after the
        // entries do: keyed off the raw cache it misses the moment the list
        // first has content, and nothing is ever recorded as present.
        .onChange(of: cached) { _, observed in
            Task { @MainActor in presence.note(observed) }
        }
        // Only a genuine move counts. Both of these read nil until the first
        // configuration read lands, and treating that nil-to-value step as a
        // network change wipes the baseline that was just taken on appear.
        .onChange(of: activeInterface) { old, new in
            guard let old, let new, old != new else { return }
            let observed = cached
            Task { @MainActor in presence.rebaseline(observed) }
        }
        .onChange(of: netInfo.config.ipv4) { old, new in
            guard let old, let new, old != new else { return }
            let observed = cached
            Task { @MainActor in presence.rebaseline(observed) }
        }
        .onDisappear { netInfo.endARPPolling() }
    }

    // MARK: Chrome

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                if discovery.isScanningLAN {
                    discovery.cancelLANScan()
                } else {
                    confirmingLANScan = true
                }
            } label: {
                HStack(spacing: 5) {
                    if discovery.isScanningLAN {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                    Text(discovery.isScanningLAN ? "Stop Scan" : "Scan LAN…")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)

            Button(action: netInfo.refreshARP) {
                if netInfo.isRefreshingARP {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .controlSize(.small)
            .disabled(netInfo.isRefreshingARP || discovery.isScanningLAN)
            .help(netInfo.isRefreshingARP ? "Refreshing the passive neighbour cache" : "Refresh the passive neighbour cache")

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
                Toggle("IP addresses", isOn: $showAddresses)
                Toggle("MAC address", isOn: $showMAC)
                Toggle("Manufacturer", isOn: $showVendor)
                Toggle("Services", isOn: $showServices)
                Toggle("Seen", isOn: $showSeen)
            } label: {
                Label("Columns", systemImage: "rectangle.split.3x1")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

            Menu {
                Button("Ask Devices to Identify Themselves…") { confirmingBonjour = true }
                    .disabled(discovery.isBrowsing)
                Button("Look Up Names in DNS…") { confirmingDNS = true }
                    .disabled(discovery.isResolvingNames)
                Divider()
                Button("Discard Active Findings", role: .destructive) { discovery.clear() }
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
            if discovery.isScanningLAN {
                Pill(text: "SCANNING", tint: .orange, filled: true)
                    .help("An active subnet scan you approved is running. Stop Scan cancels remaining work.")
            } else if discovery.isBrowsing || discovery.isResolvingNames {
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
                Text(discovery.isScanningLAN ? discovery.lanScanPhase : "Passive until you choose Scan LAN or Identify")
                    .font(.system(size: 11.5, weight: .semibold))
                if discovery.isScanningLAN {
                    ProgressView(value: Double(discovery.lanScanCompleted),
                                 total: Double(max(discovery.lanScanTotal, 1))) {
                        Text("\(discovery.lanScanCompleted) of \(discovery.lanScanTotal)")
                            .font(.system(size: 9.5, design: .monospaced))
                    }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 460)
                }
                Text("The normal view passively reads IPv4 and IPv6 neighbour caches. Scan LAN can find IPv4 hosts in the detected subnet or a custom range, check selected ports, and request DNS, Bonjour and Windows names. Every active option shows its traffic first; nothing is uploaded.")
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
        let ipv6 = present.filter { $0.ip.contains(":") || !$0.ipv6Addresses.isEmpty }.count

        return HStack(spacing: 8) {
            SummaryChip(value: "\(present.count)", label: "devices shown", tint: .blue)
            SummaryChip(value: "\(arrived)", label: "arrived while watching",
                        tint: arrived > 0 ? .orange : .secondary)
            SummaryChip(value: "\(departed)", label: "dropped out",
                        tint: departed > 0 ? .secondary : .secondary)
            SummaryChip(value: "\(priv)", label: "private addresses",
                        tint: priv > 0 ? .orange : .secondary)
            SummaryChip(value: "\(named)", label: "named by you", tint: .green)
            if ipv6 > 0 { SummaryChip(value: "\(ipv6)", label: "with IPv6", tint: .teal) }
            if discovery.hasFindings {
                SummaryChip(value: "\(present.filter(\.wasDiscovered).count)",
                            label: "active findings", tint: .blue)
            }
            let ports = present.reduce(0) { $0 + ($1.finding?.openPorts.count ?? 0) }
            if ports > 0 {
                SummaryChip(value: "\(ports)", label: "open services", tint: .indigo)
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
            if showAddresses {
                Text("IP ADDRESSES").frame(width: 174, alignment: .leading)
                    .explains("IP address", affordance: .highlight)
            }
            if showMAC {
                Text("MAC ADDRESS").frame(width: 140, alignment: .leading)
                    .explains("MAC address", affordance: .highlight)
            }
            if showVendor {
                Text("MANUFACTURER").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    .explains("Hardware vendors", affordance: .highlight)
            }
            if showServices { Text("SERVICES").frame(width: 160, alignment: .leading) }
            if showSeen { Text("SEEN").frame(width: 86, alignment: .leading) }
            Text("").frame(width: 22)
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
                        if device.wasActivelyScanned {
                            Pill(text: "SCANNED", tint: .indigo)
                        } else if device.wasDiscovered {
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

            if showAddresses {
                Text(device.addressSummary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(width: 174, alignment: .leading)
            }
            if showMAC {
                Text(device.hasHardwareAddress ? device.mac : "—")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(width: 140, alignment: .leading)
            }
            if showVendor {
                Text(device.vendorText)
                    .font(.system(size: 11))
                    .foregroundStyle(device.isLocallyAdministered ? Color.orange : Color.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            }
            if showServices {
                Text(device.openPortSummary ?? device.finding?.services.sorted().joined(separator: ", ") ?? "—")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(width: 160, alignment: .leading)
            }
            if showSeen {
                Text(seenText(device))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .leading)
            }

            Button {
                inspectingMAC = device.id
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .frame(width: 22)
            .help("Show every detail collected for this device")
            .popover(isPresented: Binding(
                get: { inspectingMAC == device.id },
                set: { if !$0 { inspectingMAC = nil } }
            ), arrowEdge: .trailing) {
                DeviceDetailsView(device: device)
            }
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
        .onTapGesture(count: 2) { if device.hasHardwareAddress { editingMAC = device.mac } }
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
        Button("Show Details") { inspectingMAC = device.id }
        if device.hasHardwareAddress {
            Button("Name This Device…") { editingMAC = device.mac }
        }
        Divider()
        Button("Copy IP Addresses") { copy(device.addressSummary.replacingOccurrences(of: "\n", with: "\t")) }
        if device.hasHardwareAddress { Button("Copy MAC Address") { copy(device.mac) } }
        if let ports = device.openPortSummary {
            Button("Copy Open Services") { copy(ports) }
        }
        Button("Copy Row") {
            copy("\(device.displayName)\t\(device.addressSummary.replacingOccurrences(of: "\n", with: " "))\t\(device.hasHardwareAddress ? device.mac : "")\t\(device.vendorText)")
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
        if let smb = device.finding?.smbName, smb != device.displayName { parts.append("SMB: \(smb)") }
        if let domain = device.finding?.smbDomain { parts.append("Domain: \(domain)") }

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
        if let ports = device.openPortSummary { parts.append(ports) }
        if let ping = device.finding?.pingTimeMS {
            parts.append(String(format: "%.1f ms ping", ping))
        } else if let latency = device.finding?.responseTimeMS {
            parts.append(String(format: "%.1f ms response", latency))
        }
        if let notes = device.record?.notes, !notes.isEmpty { parts.append(notes) }

        if parts.isEmpty {
            if let basis = device.role.basis { return basis }
            if !device.hasHardwareAddress { return "Reachable host; hardware address unavailable outside the local link" }
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
        if !device.isPresent, let last = device.finding?.lastRespondedAt {
            return "Offline \(Fmt.relativeTime(last))"
        }
        guard let sighting = device.sighting else {
            return device.wasActivelyScanned ? "Online" : "In cache"
        }
        if !device.isPresent { return "Left \(Fmt.relativeTime(sighting.lastSeen))" }
        if sighting.arrivedWhileWatching { return "Arrived \(Fmt.relativeTime(sighting.firstSeen))" }
        return "Present"
    }

    private func accessibilityText(_ device: ObservedDevice) -> String {
        var text = "\(device.displayName), addresses \(device.addressSummary.replacingOccurrences(of: "\n", with: ", "))"
        if device.hasHardwareAddress { text += ", MAC \(device.mac), \(device.vendorText)" }
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
        return "The Mac's neighbour cache does not currently hold another device on this Wi-Fi subnet. Use Scan LAN to actively find quiet IPv4 devices, or use the network normally and refresh the cache."
    }

    private func startLANScan(_ options: LANScanOptions) {
        if options.discoverIPv6 { netInfo.discoverIPv6Neighbors() }
        if options.browseBonjour { discovery.browse(duration: 7) }
        discovery.scanLAN(plan: options.plan,
                          localAddress: netInfo.config.ipv4,
                          mask: netInfo.config.subnetMask,
                          interface: activeInterface,
                          ports: options.ports,
                          resolveSMB: options.resolveSMB) { addresses, entries in
            if !entries.isEmpty {
                presence.note(entries)
            }
            netInfo.refreshARP()
            if options.resolveDNS, !addresses.isEmpty {
                discovery.resolveNames(for: addresses)
            }
        }
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
        Task {
            do {
                let records = try await Task.detached(priority: .userInitiated) {
                    try DeviceRegistry.decodeImport(ImportGuard.read(url))
                }.value
                let added = devices.merge(records)
                fileMessage = added == 0
                    ? "Nothing new was imported. Your existing names were kept."
                    : "Imported \(added) device label\(added == 1 ? "" : "s"). Existing names were kept."
            } catch {
                fileMessage = (error as? LocalizedError)?.errorDescription
                    ?? "The file could not be opened. Nothing was imported."
            }
        }
    }
}

// MARK: - Pieces

private struct LANScanOptions {
    var plan: LANScanner.TargetPlan
    var ports: [UInt16]
    var browseBonjour: Bool
    var resolveDNS: Bool
    var resolveSMB: Bool
    var discoverIPv6: Bool
}

private struct LANScanOptionsSheet: View {
    enum Scope: String, CaseIterable, Identifiable {
        case subnet = "Current subnet"
        case custom = "Custom range"
        var id: String { rawValue }
    }

    enum Depth: String, CaseIterable, Identifiable {
        case discover = "Find devices"
        case full = "Full scan"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    var localAddress: String?
    var subnetMask: String?
    var onStart: (LANScanOptions) -> Void

    @State private var scope: Scope
    @State private var depth: Depth = .full
    @State private var customRange: String
    @State private var portText: String
    @State private var browseBonjour = true
    @State private var resolveDNS = true
    @State private var resolveSMB = true
    @State private var discoverIPv6 = true

    init(localAddress: String?, subnetMask: String?,
         onStart: @escaping (LANScanOptions) -> Void) {
        self.localAddress = localAddress
        self.subnetMask = subnetMask
        self.onStart = onStart
        let subnet = localAddress.flatMap { local in
            subnetMask.flatMap { LANScanner.subnetPlan(localAddress: local, mask: $0) }
        }
        _scope = State(initialValue: subnet == nil ? .custom : .subnet)
        _customRange = State(initialValue: subnet?.label ?? "192.168.1.0/24")
        _portText = State(initialValue: LANScanner.commonPorts.map { String($0.port) }.joined(separator: ","))
    }

    private var subnetPlan: LANScanner.TargetPlan? {
        guard let localAddress, let subnetMask else { return nil }
        return LANScanner.subnetPlan(localAddress: localAddress, mask: subnetMask)
    }

    private var customPlanResult: Result<LANScanner.TargetPlan, Error> {
        Result { try LANScanner.customPlan(customRange, excluding: localAddress) }
    }

    private var selectedPlan: LANScanner.TargetPlan? {
        switch scope {
        case .subnet: return subnetPlan
        case .custom: return try? customPlanResult.get()
        }
    }

    private var selectedPorts: [UInt16]? {
        depth == .discover ? [] : LANScanner.parsePorts(portText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan network").font(.title2.weight(.semibold))
                    Text("Choose exactly what this Mac will contact.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "network")
                    .font(.system(size: 28)).foregroundStyle(.blue)
            }

            GroupBox("Addresses") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                    .pickerStyle(.segmented)
                    if scope == .custom {
                        TextField("192.168.1.1-192.168.1.254 or 10.0.0.0/24",
                                  text: $customRange)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let plan = selectedPlan {
                        Text("\(plan.label) · \(plan.targetCount.formatted()) address\(plan.targetCount == 1 ? "" : "es")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(plan.targetCount > 4_094 ? .orange : .secondary)
                        if plan.targetCount > 4_094 {
                            Text("This is a very large scan. It has no fixed size limit, but can run for hours or days. You can stop it at any time.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if plan.includesPublicAddresses {
                            Text("This range includes public Internet addresses. Probes to them leave this network and reach hosts you may not be authorized to scan.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text(validationMessage)
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(6)
            }

            GroupBox("Depth") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Depth", selection: $depth) {
                        ForEach(Depth.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if depth == .full {
                        TextField("TCP ports, comma separated", text: $portText)
                            .textFieldStyle(.roundedBorder)
                        if selectedPorts == nil {
                            Text("Ports must be comma-separated numbers from 1 to 65535.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        Toggle("Browse Bonjour and mDNS services", isOn: $browseBonjour)
                        Toggle("Discover active IPv6 neighbors on this link", isOn: $discoverIPv6)
                        Toggle("Look up DNS hostnames", isOn: $resolveDNS)
                        Toggle("Resolve Windows/SMB names and domains", isOn: $resolveSMB)
                    } else {
                        Text("Uses ICMP ping and one fallback TCP connection to identify reachable hosts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            Text("These attempts may be logged as discovery or port scanning. No credentials, web requests, or vulnerability tests are sent. Scan only ranges you own or are authorized to assess.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Scan") {
                    guard let plan = selectedPlan, let ports = selectedPorts else { return }
                    onStart(LANScanOptions(
                        plan: plan, ports: ports,
                        browseBonjour: depth == .full && browseBonjour,
                        resolveDNS: depth == .full && resolveDNS,
                        resolveSMB: depth == .full && resolveSMB,
                        discoverIPv6: depth == .full && discoverIPv6))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPlan == nil || selectedPorts == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var validationMessage: String {
        if scope == .subnet { return "The current IPv4 subnet is not available." }
        do { _ = try customPlanResult.get(); return "" }
        catch { return (error as? LocalizedError)?.errorDescription ?? "Invalid IPv4 range." }
    }
}

private struct DeviceDetailsView: View {
    var device: ObservedDevice

    private var details: [(String, String)] {
        var values: [(String, String)] = [
            ("Name", device.displayName),
            ("Role", device.role.label),
            ("IP addresses", device.addressSummary),
            ("MAC address", device.hasHardwareAddress ? device.mac : "Not available"),
            ("Address type", device.hasHardwareAddress
                ? (device.isLocallyAdministered ? "Private or virtual" : "Hardware")
                : "Routed or unresolved"),
            ("Manufacturer", device.vendorText),
            ("Status", device.isPresent ? "Present" : "No longer in cache")
        ]
        if let block = device.vendorBlock {
            if let country = block.countryName {
                values.insert(("Registrant country", country), at: values.count - 1)
            }
            values.insert(("Registered block", block.summary), at: values.count - 1)
        }
        if device.category != .unlabelled { values.append(("Your type", device.category.label)) }
        if let guess = device.guess {
            values.append(("Suggested type", guess.summary))
            values.append(("Suggestion basis", guess.basis))
        }
        if let name = device.finding?.advertisedName { values.append(("Published name", name)) }
        if let model = device.finding?.model { values.append(("Published model", model)) }
        if let hostname = device.finding?.hostname { values.append(("DNS name", hostname)) }
        if let name = device.finding?.smbName { values.append(("SMB name", name)) }
        if let domain = device.finding?.smbDomain { values.append(("SMB domain", domain)) }
        if let ports = device.openPortSummary { values.append(("Open TCP services", ports)) }
        if let services = device.finding?.services, !services.isEmpty {
            values.append(("Detected services", services.sorted().joined(separator: ", ")))
        }
        if let latency = device.finding?.responseTimeMS {
            values.append(("Fastest response", String(format: "%.1f ms", latency)))
        }
        if let ping = device.finding?.pingTimeMS {
            values.append(("ICMP ping", String(format: "%.1f ms", ping)))
        }
        if let scanned = device.finding?.scanObservedAt {
            values.append(("Last active scan", Fmt.stamp.string(from: scanned)))
        }
        if let responded = device.finding?.lastRespondedAt {
            values.append(("Last responded", Fmt.stamp.string(from: responded)))
        }
        if let sighting = device.sighting {
            values.append(("First seen", Fmt.stamp.string(from: sighting.firstSeen)))
            values.append(("Last seen", Fmt.stamp.string(from: sighting.lastSeen)))
        }
        if let notes = device.record?.notes, !notes.isEmpty { values.append(("Your notes", notes)) }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: device.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(device.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.headline)
                    Text(device.wasActivelyScanned ? "Active and passive evidence" :
                         (device.wasDiscovered ? "Device-supplied and passive evidence" : "Passive evidence"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        GridRow {
                            Text(detail.0)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 118, alignment: .trailing)
                            Text(detail.1)
                                .font(.system(size: 11,
                                              design: detail.0.contains("address") ? .monospaced : .default))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("Open services show that a TCP listener answered; they do not assess whether it is secure.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 520, height: min(CGFloat(520), CGFloat(150 + details.count * 28)))
    }
}

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
