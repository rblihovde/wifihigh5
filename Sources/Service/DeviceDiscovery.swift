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

    var isEmpty: Bool {
        advertisedName == nil && model == nil && services.isEmpty && hostname == nil
    }

    /// The best single name to show, or nil when nothing was learned.
    var bestName: String? {
        advertisedName ?? hostname
    }
}

@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published private(set) var findings: [String: DeviceFinding] = [:]
    @Published private(set) var isBrowsing = false
    @Published private(set) var isResolvingNames = false
    @Published private(set) var lastBonjourRun: Date?
    @Published private(set) var lastDNSRun: Date?
    @Published private(set) var message: String?

    private var scan: BonjourScan?

    var hasFindings: Bool { !findings.isEmpty }

    func finding(forIP ip: String) -> DeviceFinding? { findings[ip] }

    // MARK: Bonjour

    /// Browses the local network for advertised services. Callers must have
    /// obtained the user's agreement first; this method does not ask.
    func browse(duration: TimeInterval = 6) {
        guard !isBrowsing else { return }
        isBrowsing = true
        message = nil

        let scan = BonjourScan()
        self.scan = scan
        scan.start(duration: duration) { [weak self] found in
            Task { @MainActor in
                guard let self else { return }
                self.merge(found)
                self.isBrowsing = false
                self.lastBonjourRun = Date()
                self.scan = nil
                let named = found.values.filter { $0.advertisedName != nil }.count
                self.message = named == 0
                    ? "No device on this network answered. Many networks separate clients from each other, which blocks this."
                    : "\(named) device\(named == 1 ? "" : "s") answered with a name."
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
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard address.withCString({ inet_pton(AF_INET, $0, &sin.sin_addr) }) == 1 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &sin) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        let name = String(cString: host)
        return name == address ? nil : name
    }

    // MARK: Housekeeping

    private func merge(_ found: [String: DeviceFinding]) {
        for (ip, incoming) in found {
            var existing = findings[ip] ?? DeviceFinding()
            existing.advertisedName = incoming.advertisedName ?? existing.advertisedName
            existing.model = incoming.model ?? existing.model
            existing.services.formUnion(incoming.services)
            findings[ip] = existing
        }
    }

    func clearMessage() { message = nil }

    /// Discards everything learned by asking, leaving only what was observed.
    func clear() {
        findings.removeAll()
        lastBonjourRun = nil
        lastDNSRun = nil
        message = "Discovered names were discarded."
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
        ("_afpovertcp._tcp.",      "File sharing"),
        ("_ssh._tcp.",             "Remote shell"),
        ("_rfb._tcp.",             "Screen sharing"),
        ("_http._tcp.",            "Web interface"),
        ("_axis-video._tcp.",      "Camera"),
        ("_spotify-connect._tcp.", "Speaker")
    ]

    private var browsers: [NetServiceBrowser] = []
    private var pending: [NetService] = []
    private var labels: [ObjectIdentifier: String] = [:]
    private var results: [String: DeviceFinding] = [:]
    private var completion: (([String: DeviceFinding]) -> Void)?
    private var finished = false

    func start(duration: TimeInterval, completion: @escaping ([String: DeviceFinding]) -> Void) {
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
        completion?(results)
        completion = nil
    }

    private func label(for type: String) -> String {
        Self.types.first { type.hasPrefix($0.type.dropLast()) }?.label ?? "Network service"
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        guard !finished else { return }
        labels[ObjectIdentifier(service)] = label(for: service.type)
        service.delegate = self
        pending.append(service)
        service.resolve(withTimeout: 4)
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ service: NetService) {
        guard !finished, let addresses = service.addresses else { return }
        let label = labels[ObjectIdentifier(service)] ?? "Network service"

        var model: String?
        if let data = service.txtRecordData() {
            let txt = NetService.dictionary(fromTXTRecord: data)
            if let raw = txt["model"], let text = String(data: raw, encoding: .utf8) {
                model = text
            }
        }

        for data in addresses {
            guard let ip = Self.ipv4(from: data) else { continue }
            var finding = results[ip] ?? DeviceFinding()
            // _device-info._tcp carries the model but a machine-generated
            // instance name, so it must not supply the display name.
            if !service.type.hasPrefix("_device-info") {
                finding.advertisedName = finding.advertisedName ?? service.name
                finding.services.insert(label)
            }
            finding.model = model ?? finding.model
            results[ip] = finding
        }
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // A device that will not resolve is simply not described. There is
        // nothing to retry and nothing worth telling the user.
    }

    private static func ipv4(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= MemoryLayout<sockaddr>.size else { return nil }
            let sa = raw.bindMemory(to: sockaddr.self).baseAddress!
            guard sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var address = raw.bindMemory(to: sockaddr_in.self).baseAddress!.pointee.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: text)
        }
    }
}
