import Foundation
import SystemConfiguration
import SystemConfiguration.SCDynamicStoreCopyDHCPInfo
import Darwin
import Combine

/// IP-layer facts about the active interface, read from the system
/// configuration database. Purely a local read; nothing is sent.
struct IPConfig {
    var ipv4: String?
    var subnetMask: String?
    var router: String?
    var ipv6: [String] = []
    var dnsServers: [String] = []
    var searchDomains: [String] = []
    var dhcpServer: String?
    var leaseStart: Date?
    var leaseDuration: TimeInterval?
    var primaryInterface: String?
    /// MAC currently presented on the wire, which differs from the hardware
    /// address when macOS private Wi-Fi addressing is on.
    var activeMAC: String?

    var leaseExpiry: Date? {
        guard let leaseStart, let leaseDuration else { return nil }
        return leaseStart.addingTimeInterval(leaseDuration)
    }
}

enum SystemNetwork {

    static func read(interface: String) -> IPConfig {
        var cfg = IPConfig()
        guard let store = SCDynamicStoreCreate(nil, "WifiHigh5" as CFString, nil, nil) else {
            cfg.activeMAC = macAddress(for: interface)
            return cfg
        }

        let globalV4 = SCDynamicStoreCopyValue(
            store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        cfg.primaryInterface = globalV4?["PrimaryInterface"] as? String
        let primaryService = globalV4?["PrimaryService"] as? String
        let serviceID: String? = {
            if cfg.primaryInterface == interface, let primaryService { return primaryService }
            return activeServiceID(for: interface, store: store)
        }()

        let serviceV4 = serviceID.flatMap {
            SCDynamicStoreCopyValue(store, "State:/Network/Service/\($0)/IPv4" as CFString)
                as? [String: Any]
        }

        let ifKey = "State:/Network/Interface/\(interface)/IPv4" as CFString
        let interfaceV4 = SCDynamicStoreCopyValue(store, ifKey) as? [String: Any]
        if let v4 = serviceV4 ?? interfaceV4 {
            cfg.ipv4 = (v4["Addresses"] as? [String])?.first
            cfg.subnetMask = (v4["SubnetMasks"] as? [String])?.first
        }
        cfg.router = serviceV4?["Router"] as? String
        if cfg.router == nil, cfg.primaryInterface == interface {
            cfg.router = globalV4?["Router"] as? String
        }

        let ifKey6 = "State:/Network/Interface/\(interface)/IPv6" as CFString
        if let v6 = SCDynamicStoreCopyValue(store, ifKey6) as? [String: Any] {
            cfg.ipv6 = (v6["Addresses"] as? [String]) ?? []
        }

        let serviceDNS = serviceID.flatMap {
            SCDynamicStoreCopyValue(store, "State:/Network/Service/\($0)/DNS" as CFString)
                as? [String: Any]
        }
        let globalDNS = cfg.primaryInterface == interface
            ? SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
            : nil
        if let dns = serviceDNS ?? globalDNS {
            cfg.dnsServers = (dns["ServerAddresses"] as? [String]) ?? []
            cfg.searchDomains = (dns["SearchDomains"] as? [String]) ?? []
        }

        let dhcp: CFDictionary? = {
            if let serviceID {
                return SCDynamicStoreCopyDHCPInfo(store, serviceID as CFString)
            }
            if cfg.primaryInterface == interface {
                return SCDynamicStoreCopyDHCPInfo(store, nil)
            }
            return nil
        }()
        if let dhcp {
            cfg.leaseStart = DHCPInfoGetLeaseStartTime(dhcp) as Date?
            if cfg.router == nil,
               let routerData = DHCPInfoGetOptionData(dhcp, 3) as Data?, routerData.count >= 4 {
                cfg.router = routerData.prefix(4).map(String.init).joined(separator: ".")
            }
            if let serverData = DHCPInfoGetOptionData(dhcp, 54) as Data?, serverData.count == 4 {
                cfg.dhcpServer = serverData.map(String.init).joined(separator: ".")
            }
            if let leaseData = DHCPInfoGetOptionData(dhcp, 51) as Data?, leaseData.count == 4 {
                let secs = leaseData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                cfg.leaseDuration = TimeInterval(secs)
            }
        }

        cfg.activeMAC = macAddress(for: interface)
        return cfg
    }

    /// Finds the active network service backed by a BSD interface. This avoids
    /// combining en0's address with a VPN or Ethernet service's global router.
    private static func activeServiceID(for interface: String,
                                        store: SCDynamicStore) -> String? {
        let pattern = "Setup:/Network/Service/.*/Interface" as CFString
        guard let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else { return nil }

        var fallback: String?
        for key in keys {
            guard let settings = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  settings["DeviceName"] as? String == interface else { continue }
            let parts = key.split(separator: "/")
            guard parts.count >= 5 else { continue }
            let serviceID = String(parts[3])
            fallback = fallback ?? serviceID
            let stateKey = "State:/Network/Service/\(serviceID)/IPv4" as CFString
            if let state = SCDynamicStoreCopyValue(store, stateKey) as? [String: Any],
               !(state["Addresses"] as? [String] ?? []).isEmpty {
                return serviceID
            }
        }
        return fallback
    }

    /// Link-layer address of the named interface, via getifaddrs.
    static func macAddress(for interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard String(cString: cur.pointee.ifa_name) == interface,
                  let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let dl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self)
            let len = Int(dl.pointee.sdl_alen)
            guard len == 6 else { continue }
            // The address sits after the interface name inside sdl_data.
            let base = UnsafeRawPointer(dl).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!)
            let bytes = base.advanced(by: Int(dl.pointee.sdl_nlen)).assumingMemoryBound(to: UInt8.self)
            return (0..<6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
        }
        return nil
    }

    /// True when the active MAC differs from the adapter's burned-in address,
    /// which means macOS is rotating a private address for this network.
    static func usingPrivateAddress(hardware: String?, active: String?) -> Bool {
        guard let h = hardware?.lowercased(), let a = active?.lowercased() else { return false }
        return h != a
    }
}

// MARK: - Gateway reachability

/// Measures round-trip time to the default gateway using ICMP echo.
///
/// Off by default. When enabled it talks only to the local router — the same
/// traffic any connected client produces — so it stays appropriate on a client
/// network. No hosts beyond the gateway are contacted.
@MainActor
final class GatewayPinger: ObservableObject {
    @Published var enabled = false { didSet { enabled ? start() : stop() } }
    @Published private(set) var lastRTT: Double?
    @Published private(set) var history: [(Date, Double?)] = []
    @Published private(set) var sent = 0
    @Published private(set) var completed = 0
    @Published private(set) var received = 0
    @Published var target: String? {
        didSet {
            guard target != oldValue else { return }
            reset()
            if enabled { fire() }
        }
    }

    private var timer: Timer?
    private var seq: UInt16 = 0
    private var generation: UInt = 0
    private let queue = DispatchQueue(label: "gateway.ping", qos: .utility)

    var lossPercent: Double {
        guard completed > 0 else { return 0 }
        return Double(completed - received) / Double(completed) * 100
    }

    var averageRTT: Double? {
        let vals = history.compactMap { $0.1 }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Spread of recent round-trips; high jitter shows up as choppy calls.
    var jitter: Double? {
        let vals = history.compactMap { $0.1 }
        guard vals.count > 1, let avg = averageRTT else { return nil }
        return vals.map { abs($0 - avg) }.reduce(0, +) / Double(vals.count)
    }

    func reset() {
        generation &+= 1
        history.removeAll(); sent = 0; completed = 0; received = 0; lastRTT = nil
    }

    private func start() {
        stop()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        fire()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        generation &+= 1
    }

    private func fire() {
        guard let host = target else { return }
        seq &+= 1
        let s = seq
        let requestGeneration = generation
        sent += 1
        queue.async { [weak self] in
            let rtt = ICMPEcho.ping(host: host, sequence: s, timeout: 1.0)
            Task { @MainActor in
                guard let self, self.enabled, self.target == host,
                      self.generation == requestGeneration else { return }
                self.lastRTT = rtt
                self.completed += 1
                if rtt != nil { self.received += 1 }
                self.history.append((Date(), rtt))
                if self.history.count > 300 { self.history.removeFirst(self.history.count - 300) }
            }
        }
    }
}

/// Minimal ICMP echo over a datagram socket, which macOS permits without root.
enum ICMPEcho {

    static func ping(host: String, sequence: UInt16, timeout: TimeInterval) -> Double? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let packet = makeEchoRequest(identifier: 0xACED, sequence: sequence)
        let start = Date()

        let sendResult = packet.withUnsafeBytes { buf -> Int in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sendResult >= 0 else { return nil }

        var reply = [UInt8](repeating: 0, count: 1024)
        // Retry briefly so an unrelated ICMP message does not count as a loss.
        while Date().timeIntervalSince(start) < timeout {
            let n = recvfrom(fd, &reply, reply.count, 0, nil, nil)
            guard n > 0 else { return nil }
            var offset = 0
            // Darwin may hand back the IP header; skip it when present.
            if n >= 20, (reply[0] >> 4) == 4 { offset = Int(reply[0] & 0x0F) * 4 }
            guard n >= offset + 8 else { continue }
            let type = reply[offset]
            let replySeq = (UInt16(reply[offset + 6]) << 8) | UInt16(reply[offset + 7])
            if type == 0, replySeq == sequence {
                return Date().timeIntervalSince(start) * 1000
            }
        }
        return nil
    }

    private static func makeEchoRequest(identifier: UInt16, sequence: UInt16) -> Data {
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = 8                                  // echo request
        p[1] = 0                                  // code
        p[4] = UInt8(identifier >> 8); p[5] = UInt8(identifier & 0xFF)
        p[6] = UInt8(sequence >> 8);   p[7] = UInt8(sequence & 0xFF)
        for i in 8..<16 { p[i] = UInt8(i) }       // payload
        let ck = checksum(p)
        p[2] = UInt8(ck >> 8); p[3] = UInt8(ck & 0xFF)
        return Data(p)
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum &+= (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum &+= UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }
}
