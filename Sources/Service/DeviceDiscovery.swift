import Foundation
import Combine
import Darwin

/// Names and services gathered by asking, rather than by watching.
///
/// Everything in this file transmits. It is the only part of the app that does,
/// besides the optional gateway ping, and nothing here runs until the person
/// using the app has read what it does and agreed to it. The rest of the
/// Observed Devices view stays a passive read of a cache the system already
/// keeps, whether or not any of this is ever used.
struct DeviceFinding: Equatable {
    /// The name a device publishes for itself over Bonjour.
    var advertisedName: String?
    /// A model string, when the device publishes one.
    var model: String?
    /// Plain-language descriptions of what the device offers.
    var services: Set<String> = []
    /// A name held by this network's DNS, from a reverse lookup.
    var hostname: String?
    /// Windows/SMB identity returned by an optional NetBIOS node-status query.
    var smbName: String?
    var smbDomain: String?
    /// TCP services found by the optional selected-port scan.
    var openPorts: Set<Int> = []
    /// Fastest TCP response observed during the scan. This is a rough local
    /// round-trip indicator, not an ICMP ping measurement.
    var responseTimeMS: Double?
    /// ICMP round trip when the host answered echo specifically.
    var pingTimeMS: Double?
    /// When this address last took part in an active LAN scan.
    var scanObservedAt: Date?
    /// Whether it answered the most recent scan that included its address.
    var scanOnline: Bool?
    /// Most recent successful active response, retained when a later scan finds
    /// the host offline.
    var lastRespondedAt: Date?

    var isEmpty: Bool {
        advertisedName == nil && model == nil && services.isEmpty && hostname == nil &&
        smbName == nil && smbDomain == nil &&
        openPorts.isEmpty && scanObservedAt == nil && scanOnline == nil
    }

    /// The best single name to show, or nil when nothing was learned.
    var bestName: String? {
        advertisedName ?? hostname ?? smbName
    }
}

@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published private(set) var findings: [String: DeviceFinding] = [:]
    @Published private(set) var isBrowsing = false
    @Published private(set) var isResolvingNames = false
    @Published private(set) var isScanningLAN = false
    @Published private(set) var lanScanCompleted = 0
    @Published private(set) var lanScanTotal = 0
    @Published private(set) var lanScanPhase = ""
    @Published private(set) var lastBonjourRun: Date?
    @Published private(set) var lastDNSRun: Date?
    @Published private(set) var lastLANRun: Date?
    @Published private(set) var message: String?

    private var scan: BonjourScan?
    private var lanCancellation: LANScanCancellation?

    var hasFindings: Bool { !findings.isEmpty }
    var isSending: Bool { isBrowsing || isResolvingNames || isScanningLAN }

    func finding(forIP ip: String) -> DeviceFinding? { findings[ip] }

    func finding(forAddresses addresses: [String]) -> DeviceFinding? {
        var combined: DeviceFinding?
        for address in addresses {
            guard let incoming = findings[address] else { continue }
            var value = combined ?? DeviceFinding()
            value.advertisedName = value.advertisedName ?? incoming.advertisedName
            value.model = value.model ?? incoming.model
            value.services.formUnion(incoming.services)
            value.hostname = value.hostname ?? incoming.hostname
            value.smbName = value.smbName ?? incoming.smbName
            value.smbDomain = value.smbDomain ?? incoming.smbDomain
            value.openPorts.formUnion(incoming.openPorts)
            value.responseTimeMS = [value.responseTimeMS, incoming.responseTimeMS]
                .compactMap { $0 }.min()
            value.pingTimeMS = [value.pingTimeMS, incoming.pingTimeMS]
                .compactMap { $0 }.min()
            value.scanObservedAt = max(value.scanObservedAt ?? .distantPast,
                                       incoming.scanObservedAt ?? .distantPast)
            if value.scanObservedAt == .distantPast { value.scanObservedAt = nil }
            value.scanOnline = incoming.scanOnline ?? value.scanOnline
            value.lastRespondedAt = max(value.lastRespondedAt ?? .distantPast,
                                        incoming.lastRespondedAt ?? .distantPast)
            if value.lastRespondedAt == .distantPast { value.lastRespondedAt = nil }
            combined = value
        }
        return combined
    }

    var allFindings: [String: DeviceFinding] { findings }

    // MARK: LAN scan

    /// Actively scans a validated IPv4 plan. The caller chooses whether the
    /// plan is the current subnet or an explicit range, and shows consent UI.
    func scanLAN(plan: LANScanner.TargetPlan,
                 localAddress: String?, mask: String?, interface: String?,
                 ports: [UInt16], resolveSMB: Bool,
                 completion: @escaping ([String], [ARPEntry]) -> Void) {
        guard !isScanningLAN else { return }
        guard plan.targetCount > 0 else { message = "The selected range is empty."; return }

        let cancellation = LANScanCancellation()
        lanCancellation = cancellation
        isScanningLAN = true
        lanScanCompleted = 0
        lanScanTotal = Int(min(plan.targetCount, UInt64(Int.max)))
        lanScanPhase = "Finding devices"
        message = nil

        DispatchQueue.global(qos: .utility).async {
            let result = LANScanner.run(
                plan: plan, localAddress: localAddress, mask: mask, interface: interface,
                ports: ports, resolveSMB: resolveSMB, cancellation: cancellation
            ) { completed, total, phase in
                Task { @MainActor in
                    guard self.lanCancellation === cancellation else { return }
                    self.lanScanCompleted = completed
                    self.lanScanTotal = total
                    self.lanScanPhase = phase
                }
            }

            Task { @MainActor in
                guard self.lanCancellation === cancellation else { return }
                self.isScanningLAN = false
                self.lanCancellation = nil
                self.lastLANRun = Date()
                let checkedAt = Date()
                // A stopped scan never reached some addresses, so only a scan
                // that finished may call a previously found host offline.
                let checkedAddresses = result.cancelled ? [] : self.findings.keys.filter(plan.contains)
                for address in checkedAddresses {
                    guard var finding = self.findings[address] else { continue }
                    guard finding.scanObservedAt != nil else { continue }
                    finding.scanObservedAt = checkedAt
                    finding.scanOnline = false
                    self.findings[address] = finding
                }
                self.merge(result.findings, replacingScan: true)
                let count = result.liveAddresses.count
                var summary = result.cancelled
                    ? "LAN scan stopped. \(count) device\(count == 1 ? "" : "s") found before it stopped."
                    : "LAN scan found \(count) device\(count == 1 ? "" : "s")."
                if !ports.isEmpty && !result.cancelled {
                    let open = result.findings.values.reduce(0) { $0 + $1.openPorts.count }
                    summary += " \(open) open TCP service\(open == 1 ? "" : "s") identified."
                }
                summary += " Range: \(plan.label)."
                self.message = summary
                completion(result.liveAddresses, result.entries)
            }
        }
    }

    func cancelLANScan() { lanCancellation?.cancel() }

    // MARK: Bonjour

    /// Browses the local network for advertised services. Callers must have
    /// obtained the user's agreement first; this method does not ask.
    func browse(duration: TimeInterval = 6) {
        guard !isBrowsing else { return }
        isBrowsing = true
        message = nil

        let scan = BonjourScan()
        self.scan = scan
        scan.start(duration: duration) { [weak self] found, truncated in
            Task { @MainActor in
                guard let self else { return }
                self.merge(found)
                self.isBrowsing = false
                self.lastBonjourRun = Date()
                self.scan = nil
                let named = found.values.filter { $0.advertisedName != nil }.count
                var message = named == 0
                    ? "No device on this network answered. Many networks separate clients from each other, which blocks this."
                    : "\(named) device\(named == 1 ? "" : "s") answered with a name."
                if truncated {
                    message += " The network advertised more services than one scan accepts, so the rest were ignored."
                }
                self.message = message
            }
        }
    }

    // MARK: Reverse DNS

    /// Asks this network's name servers what each address is called. Callers
    /// must have obtained the user's agreement first.
    func resolveNames(for addresses: [String]) {
        guard !isResolvingNames, !addresses.isEmpty else { return }
        isResolvingNames = true
        message = nil

        DispatchQueue.global(qos: .utility).async {
            var found: [String: String] = [:]
            for address in addresses {
                if let name = Self.reverseLookup(address) { found[address] = name }
            }
            Task { @MainActor in
                for (address, name) in found {
                    var finding = self.findings[address] ?? DeviceFinding()
                    finding.hostname = name
                    self.findings[address] = finding
                }
                self.isResolvingNames = false
                self.lastDNSRun = Date()
                self.message = found.isEmpty
                    ? "This network's DNS holds no names for these addresses, which is normal on home and small-office networks."
                    : "\(found.count) address\(found.count == 1 ? "" : "es") resolved to a name."
            }
        }
    }

    /// One reverse lookup. Returns nil when the resolver has no name, rather
    /// than echoing the address back as its own name.
    nonisolated private static func reverseLookup(_ address: String) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        if address.withCString({ inet_pton(AF_INET, $0, &sin.sin_addr) }) == 1 {
            let result = withUnsafePointer(to: &sin) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
                }
            }
            guard result == 0 else { return nil }
        } else {
            var sin6 = sockaddr_in6()
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            guard address.withCString({ inet_pton(AF_INET6, $0, &sin6.sin6_addr) }) == 1 else {
                return nil
            }
            let result = withUnsafePointer(to: &sin6) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
                }
            }
            guard result == 0 else { return nil }
        }
        let name = UntrustedText.clean(String(cString: host), limit: 253)
        return name.isEmpty || name == address ? nil : name
    }

    // MARK: Housekeeping

    private func merge(_ found: [String: DeviceFinding], replacingScan: Bool = false) {
        for (ip, incoming) in found {
            var existing = findings[ip] ?? DeviceFinding()
            existing.advertisedName = incoming.advertisedName ?? existing.advertisedName
            existing.model = incoming.model ?? existing.model
            existing.services.formUnion(incoming.services)
            existing.smbName = incoming.smbName ?? existing.smbName
            existing.smbDomain = incoming.smbDomain ?? existing.smbDomain
            if replacingScan {
                existing.openPorts = incoming.openPorts
                existing.responseTimeMS = incoming.responseTimeMS
                existing.pingTimeMS = incoming.pingTimeMS
                existing.scanObservedAt = incoming.scanObservedAt
                existing.scanOnline = incoming.scanOnline
                existing.lastRespondedAt = incoming.lastRespondedAt ?? existing.lastRespondedAt
            }
            findings[ip] = existing
        }
    }

    func clearMessage() { message = nil }

    /// Discards everything learned by asking, leaving only what was observed.
    func clear() {
        lanCancellation?.cancel()
        lanCancellation = nil
        isScanningLAN = false
        lanScanCompleted = 0
        lanScanTotal = 0
        lanScanPhase = ""
        findings.removeAll()
        lastBonjourRun = nil
        lastDNSRun = nil
        lastLANRun = nil
        message = "Actively discovered names, services and scan results were discarded."
    }
}

// MARK: - Bonjour browsing

/// Browses a fixed set of service types and resolves whatever answers.
///
/// The set is deliberately a list rather than the wildcard meta-query: these
/// are the services that say something useful about what a device is, and
/// asking for a known handful is a smaller thing to do on someone else's
/// network than enumerating everything it offers.
///
/// Confined to the main runloop: it is created from the main actor, its
/// browsers and services are scheduled on the main runloop and so call back on
/// it, and the timeout is posted to the main queue. Nothing here is touched
/// from another thread, which is what the Sendable claim below rests on.
private final class BonjourScan: NSObject, NetServiceBrowserDelegate,
                                 NetServiceDelegate, @unchecked Sendable {

    private static let types: [(type: String, label: String)] = [
        ("_device-info._tcp.",     "Device information"),
        ("_workstation._tcp.",     "Computer"),
        ("_ipp._tcp.",             "Printing"),
        ("_ipps._tcp.",            "Printing"),
        ("_printer._tcp.",         "Printing"),
        ("_pdl-datastream._tcp.",  "Printing"),
        ("_scanner._tcp.",         "Scanning"),
        ("_airplay._tcp.",         "AirPlay"),
        ("_raop._tcp.",            "AirPlay audio"),
        ("_googlecast._tcp.",      "Chromecast"),
        ("_hap._tcp.",             "HomeKit accessory"),
        ("_smb._tcp.",             "File sharing"),
        ("_nfs._tcp.",             "File sharing"),
        ("_afpovertcp._tcp.",      "File sharing"),
        ("_ssh._tcp.",             "Remote shell"),
        ("_rfb._tcp.",             "Screen sharing"),
        ("_http._tcp.",            "Web interface"),
        ("_axis-video._tcp.",      "Camera"),
        ("_spotify-connect._tcp.", "Speaker"),
        ("_mqtt._tcp.",            "MQTT"),
        ("_home-assistant._tcp.",  "Home Assistant"),
        ("_matter._tcp.",          "Matter accessory"),
        ("_ndi._tcp.",             "NDI video")
    ]

    /// A device chooses what it advertises, and a hostile one could advertise
    /// without end. These bound the work one scan will do on its behalf.
    static let maximumServices = 500
    static let maximumConcurrentResolves = 16
    static let maximumAddresses = 1_024

    private var browsers: [NetServiceBrowser] = []
    private var pending: [NetService] = []
    private var waiting: [NetService] = []
    private var resolving = 0
    private var settled = Set<ObjectIdentifier>()
    private var seen = Set<String>()
    private var truncated = false
    private var labels: [ObjectIdentifier: String] = [:]
    private var results: [String: DeviceFinding] = [:]
    private var completion: (([String: DeviceFinding], Bool) -> Void)?
    private var finished = false

    func start(duration: TimeInterval,
               completion: @escaping ([String: DeviceFinding], Bool) -> Void) {
        self.completion = completion
        for entry in Self.types {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: entry.type, inDomain: "local.")
            browsers.append(browser)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        pending.forEach { $0.stop() }
        pending.removeAll()
        waiting.removeAll()
        completion?(results, truncated)
        completion = nil
    }

    /// Frees a resolve slot and starts the next waiting service. Safe to call
    /// more than once for a service, because a service can report back twice.
    private func resolveSettled(_ service: NetService) {
        guard settled.insert(ObjectIdentifier(service)).inserted else { return }
        resolving = Swift.max(0, resolving - 1)
        guard !finished, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        resolving += 1
        next.resolve(withTimeout: 4)
    }

    private func label(for type: String) -> String {
        Self.types.first { type.hasPrefix($0.type.dropLast()) }?.label ?? "Network service"
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        guard !finished else { return }
        let identity = "\(service.name)|\(service.type)|\(service.domain)"
        guard !seen.contains(identity) else { return }
        guard seen.count < Self.maximumServices else {
            truncated = true
            return
        }
        seen.insert(identity)
        labels[ObjectIdentifier(service)] = label(for: service.type)
        service.delegate = self
        pending.append(service)
        if resolving < Self.maximumConcurrentResolves {
            resolving += 1
            service.resolve(withTimeout: 4)
        } else {
            waiting.append(service)
        }
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ service: NetService) {
        defer { resolveSettled(service) }
        guard !finished, let addresses = service.addresses else { return }
        let label = labels[ObjectIdentifier(service)] ?? "Network service"

        // Everything below was chosen by the device. It is cleaned and capped
        // before it can reach the screen, an export or a report.
        var model: String?
        if let data = service.txtRecordData() {
            let txt = NetService.dictionary(fromTXTRecord: data)
            if let raw = txt["model"], let text = String(data: raw, encoding: .utf8) {
                let cleaned = UntrustedText.clean(text, limit: 128)
                if !cleaned.isEmpty { model = cleaned }
            }
        }
        let name = UntrustedText.clean(service.name, limit: 256)

        for data in addresses {
            guard let ip = Self.ipAddress(from: data) else { continue }
            guard results[ip] != nil || results.count < Self.maximumAddresses else {
                truncated = true
                continue
            }
            var finding = results[ip] ?? DeviceFinding()
            // _device-info._tcp carries the model but a machine-generated
            // instance name, so it must not supply the display name.
            if !service.type.hasPrefix("_device-info") {
                if finding.advertisedName == nil, !name.isEmpty { finding.advertisedName = name }
                finding.services.insert(label)
            }
            finding.model = model ?? finding.model
            results[ip] = finding
        }
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // A device that will not resolve is simply not described. Its slot is
        // handed to the next service waiting.
        resolveSettled(service)
    }

    private static func ipAddress(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= MemoryLayout<sockaddr>.size else { return nil }
            let sa = raw.bindMemory(to: sockaddr.self).baseAddress!
            if sa.pointee.sa_family == UInt8(AF_INET) {
                guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var address = raw.bindMemory(to: sockaddr_in.self).baseAddress!.pointee.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: text)
            }
            if sa.pointee.sa_family == UInt8(AF_INET6) {
                guard raw.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
                var address = raw.bindMemory(to: sockaddr_in6.self).baseAddress!.pointee.sin6_addr
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &address, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: text).lowercased()
            }
            return nil
        }
    }
}
