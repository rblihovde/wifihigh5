import Foundation
import Network

/// Active IPv4 discovery with a streaming address plan. There is no artificial
/// host-count ceiling: even a very broad custom range is produced in small
/// batches, stays cancellable, and does not allocate an array for every IP.
enum LANScanner {
    struct TargetPlan: Equatable {
        var first: UInt32
        var last: UInt32
        var excluded: UInt32?
        var label: String

        var targetCount: UInt64 {
            guard last >= first else { return 0 }
            let count = UInt64(last) - UInt64(first) + 1
            if let excluded, excluded >= first, excluded <= last { return count - 1 }
            return count
        }

        func contains(_ address: String) -> Bool {
            guard let value = LANScanner.ipv4Value(address) else { return false }
            return value >= first && value <= last && value != excluded
        }

        /// True when any address in the plan lies outside the private,
        /// carrier-grade NAT and link-local blocks, so probes would leave
        /// the local network for hosts on the public Internet.
        var includesPublicAddresses: Bool {
            guard last >= first else { return false }
            let local: [(UInt32, UInt32)] = [
                (0x0A00_0000, 0x0AFF_FFFF), // 10.0.0.0/8
                (0x6440_0000, 0x647F_FFFF), // 100.64.0.0/10
                (0xA9FE_0000, 0xA9FE_FFFF), // 169.254.0.0/16
                (0xAC10_0000, 0xAC1F_FFFF), // 172.16.0.0/12
                (0xC0A8_0000, 0xC0A8_FFFF)  // 192.168.0.0/16
            ]
            return !local.contains { first >= $0.0 && last <= $0.1 }
        }

        var firstAddress: String? {
            var value = first
            if value == excluded {
                guard value < last else { return nil }
                value += 1
            }
            return targetCount > 0 ? LANScanner.ipv4String(value) : nil
        }

        var lastAddress: String? {
            guard targetCount > 0 else { return nil }
            if last != excluded { return LANScanner.ipv4String(last) }
            guard last > first else { return nil }
            return LANScanner.ipv4String(last - 1)
        }
    }

    enum RangeError: LocalizedError, Equatable {
        case invalid
        case reversed
        case empty

        var errorDescription: String? {
            switch self {
            case .invalid:
                return "Enter one IPv4 address, a range such as 192.168.1.1-192.168.1.254, or CIDR such as 10.0.0.0/24."
            case .reversed:
                return "The first IPv4 address must be lower than or equal to the last."
            case .empty:
                return "That range contains no address other than this Mac."
            }
        }
    }

    struct Result {
        var findings: [String: DeviceFinding]
        var entries: [ARPEntry]
        var liveAddresses: [String]
        var scannedAddresses: Int
        var totalAddresses: UInt64
        var cancelled: Bool
    }

    struct ServicePort: Hashable {
        var port: UInt16
        var name: String
    }

    static let commonPorts: [ServicePort] = [
        ServicePort(port: 21, name: "FTP"),
        ServicePort(port: 22, name: "SSH"),
        ServicePort(port: 23, name: "Telnet"),
        ServicePort(port: 25, name: "SMTP"),
        ServicePort(port: 53, name: "DNS"),
        ServicePort(port: 80, name: "HTTP"),
        ServicePort(port: 110, name: "POP3"),
        ServicePort(port: 139, name: "NetBIOS"),
        ServicePort(port: 143, name: "IMAP"),
        ServicePort(port: 443, name: "HTTPS"),
        ServicePort(port: 445, name: "SMB"),
        ServicePort(port: 515, name: "LPD printing"),
        ServicePort(port: 548, name: "AFP"),
        ServicePort(port: 631, name: "IPP printing"),
        ServicePort(port: 1883, name: "MQTT"),
        ServicePort(port: 3389, name: "Remote Desktop"),
        ServicePort(port: 5000, name: "Web service"),
        ServicePort(port: 5357, name: "Web Services for Devices"),
        ServicePort(port: 5900, name: "Screen sharing"),
        ServicePort(port: 8008, name: "Chromecast"),
        ServicePort(port: 8080, name: "Web service"),
        ServicePort(port: 8443, name: "Secure web service"),
        ServicePort(port: 9100, name: "Printer"),
        ServicePort(port: 32400, name: "Plex")
    ]

    static func serviceName(for port: Int) -> String {
        commonPorts.first(where: { Int($0.port) == port })?.name ?? "TCP"
    }

    static func parsePorts(_ text: String) -> [UInt16]? {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var ports = Set<UInt16>()
        for piece in pieces {
            let cleaned = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = UInt16(cleaned), value > 0 else { return nil }
            ports.insert(value)
        }
        return ports.sorted()
    }

    static func subnetPlan(localAddress: String, mask: String) -> TargetPlan? {
        guard let local = ipv4Value(localAddress),
              let maskValue = ipv4Value(mask),
              isContiguousMask(maskValue) else { return nil }
        let network = local & maskValue
        let broadcast = network | ~maskValue
        guard UInt64(broadcast) > UInt64(network) + 1 else { return nil }
        return TargetPlan(first: network + 1, last: broadcast - 1,
                          excluded: local,
                          label: "\(ipv4String(network))/\(maskValue.nonzeroBitCount)")
    }

    static func targetPlan(localAddress: String, mask: String) -> TargetPlan? {
        subnetPlan(localAddress: localAddress, mask: mask)
    }

    static func customPlan(_ text: String, excluding localAddress: String?) throws -> TargetPlan {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let excluded = localAddress.flatMap(ipv4Value)
        let bounds: (UInt32, UInt32, String)

        if let slash = value.firstIndex(of: "/") {
            let addressText = String(value[..<slash])
            let prefixText = String(value[value.index(after: slash)...])
            guard let address = ipv4Value(addressText), let prefix = Int(prefixText),
                  (0...32).contains(prefix) else { throw RangeError.invalid }
            let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
            let network = address & mask
            let broadcast = network | ~mask
            if prefix <= 30 {
                bounds = (network + 1, broadcast - 1, "\(ipv4String(network))/\(prefix)")
            } else {
                bounds = (network, broadcast, "\(ipv4String(network))/\(prefix)")
            }
        } else if let dash = value.firstIndex(of: "-") {
            guard let first = ipv4Value(String(value[..<dash])),
                  let last = ipv4Value(String(value[value.index(after: dash)...])) else {
                throw RangeError.invalid
            }
            guard first <= last else { throw RangeError.reversed }
            bounds = (first, last, "\(ipv4String(first))–\(ipv4String(last))")
        } else {
            guard let address = ipv4Value(value) else { throw RangeError.invalid }
            bounds = (address, address, ipv4String(address))
        }

        let plan = TargetPlan(first: bounds.0, last: bounds.1,
                              excluded: excluded, label: bounds.2)
        guard plan.targetCount > 0 else { throw RangeError.empty }
        return plan
    }

    static func run(plan: TargetPlan, localAddress: String?, mask: String?,
                    interface: String?, ports: [UInt16], resolveSMB: Bool,
                    cancellation: LANScanCancellation,
                    progress: @escaping @Sendable (Int, Int, String) -> Void) -> Result {
        let lock = NSLock()
        var live = Set<String>()
        var responseTimes: [String: Double] = [:]
        var pingTimes: [String: Double] = [:]
        var openPorts: [String: Set<Int>] = [:]
        var smb: [String: NetBIOSIdentity] = [:]
        var completed = 0
        let total = Int(min(plan.targetCount, UInt64(Int.max)))

        progress(0, total, "Finding devices")
        let queue = OperationQueue()
        queue.name = "WifiHigh5 LAN sweep"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 80

        let batchSize: UInt32 = 2_048
        var cursor = plan.first
        while cursor <= plan.last, !cancellation.isCancelled {
            let remaining = UInt64(plan.last) - UInt64(cursor)
            let end = UInt32(UInt64(cursor) + min(UInt64(batchSize - 1), remaining))
            var value = cursor
            while value <= end {
                if value != plan.excluded {
                    let address = ipv4String(value)
                    let sequence = UInt16(truncatingIfNeeded: value)
                    queue.addOperation {
                        guard !cancellation.isCancelled else { return }
                        let ping = icmpPing(host: address,
                                            sequence: sequence,
                                            timeout: 0.22)
                        let probe = ping == nil
                            ? tcpProbe(address: address, port: 80, timeout: 0.30)
                            : ProbeResult(isOpen: false, reachedHost: true, milliseconds: ping!)
                        lock.lock()
                        if probe.reachedHost {
                            live.insert(address)
                            responseTimes[address] = probe.milliseconds
                            if let ping { pingTimes[address] = ping }
                        }
                        completed += 1
                        let done = completed
                        lock.unlock()
                        if done == total || done.isMultiple(of: 8) {
                            progress(done, total, "Finding devices")
                        }
                    }
                }
                if value == UInt32.max { break }
                value += 1
            }
            queue.waitUntilAllOperationsAreFinished()
            if end == UInt32.max { break }
            cursor = end + 1
        }

        if !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.12) }
        let entries: [ARPEntry]
        if let interface, let localAddress, let mask {
            entries = ARPTable.devicesOnActiveSubnet(
                ARPTable.read(), interface: interface,
                localAddress: localAddress, mask: mask)
            lock.lock()
            live.formUnion(entries.map(\.ip).filter(plan.contains))
            lock.unlock()
        } else {
            entries = []
        }

        let liveAddresses = live.sorted { (ipv4Value($0) ?? .max) < (ipv4Value($1) ?? .max) }

        if !ports.isEmpty, !cancellation.isCancelled, !liveAddresses.isEmpty {
            let serviceTotal = liveAddresses.count * ports.count
            var serviceCompleted = 0
            let services = OperationQueue()
            services.name = "WifiHigh5 service discovery"
            services.qualityOfService = .utility
            services.maxConcurrentOperationCount = 64
            progress(0, serviceTotal, "Checking TCP services")
            for address in liveAddresses {
                for port in ports {
                    services.addOperation {
                        guard !cancellation.isCancelled else { return }
                        let probe = tcpProbe(address: address, port: port, timeout: 0.38)
                        lock.lock()
                        if probe.isOpen { openPorts[address, default: []].insert(Int(port)) }
                        if probe.reachedHost {
                            responseTimes[address] = min(responseTimes[address] ?? probe.milliseconds,
                                                         probe.milliseconds)
                        }
                        serviceCompleted += 1
                        let done = serviceCompleted
                        lock.unlock()
                        if done == serviceTotal || done.isMultiple(of: 8) {
                            progress(done, serviceTotal, "Checking TCP services")
                        }
                    }
                }
            }
            services.waitUntilAllOperationsAreFinished()
        }

        if resolveSMB, !cancellation.isCancelled, !liveAddresses.isEmpty {
            let names = OperationQueue()
            names.name = "WifiHigh5 SMB names"
            names.qualityOfService = .utility
            names.maxConcurrentOperationCount = 32
            var nameCompleted = 0
            progress(0, liveAddresses.count, "Resolving SMB names")
            for address in liveAddresses {
                names.addOperation {
                    guard !cancellation.isCancelled else { return }
                    let identity = NetBIOSResolver.lookup(address, timeout: 0.45)
                    lock.lock()
                    if let identity { smb[address] = identity }
                    nameCompleted += 1
                    let done = nameCompleted
                    lock.unlock()
                    if done == liveAddresses.count || done.isMultiple(of: 4) {
                        progress(done, liveAddresses.count, "Resolving SMB names")
                    }
                }
            }
            names.waitUntilAllOperationsAreFinished()
        }

        let observedAt = Date()
        var findings: [String: DeviceFinding] = [:]
        for address in liveAddresses {
            findings[address] = DeviceFinding(
                smbName: smb[address]?.name,
                smbDomain: smb[address]?.domain,
                openPorts: openPorts[address] ?? [],
                responseTimeMS: responseTimes[address],
                pingTimeMS: pingTimes[address],
                scanObservedAt: observedAt,
                scanOnline: true,
                lastRespondedAt: observedAt)
        }
        return Result(findings: findings, entries: entries,
                      liveAddresses: liveAddresses, scannedAddresses: completed,
                      totalAddresses: plan.targetCount,
                      cancelled: cancellation.isCancelled)
    }

    struct ProbeResult {
        var isOpen: Bool
        var reachedHost: Bool
        var milliseconds: Double
    }

    static func tcpProbe(address: String, port: UInt16,
                                 timeout: TimeInterval) -> ProbeResult {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return ProbeResult(isOpen: false, reachedHost: false, milliseconds: 0)
        }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var answer: (open: Bool, reached: Bool)?
        let started = DispatchTime.now().uptimeNanoseconds
        connection.stateUpdateHandler = { state in
            var result: (Bool, Bool)?
            switch state {
            case .ready: result = (true, true)
            // Network.framework reports a refused connection as .waiting and
            // would retry it, not as .failed. A refusal still proves a host.
            case .waiting(let error), .failed(let error):
                if case .posix(let code) = error, code == .ECONNREFUSED || code == .ECONNRESET {
                    result = (false, true)
                } else { result = (false, false) }
            case .cancelled: result = (false, false)
            default: break
            }
            guard let result else { return }
            stateLock.lock()
            if answer == nil { answer = result; semaphore.signal() }
            stateLock.unlock()
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        _ = semaphore.wait(timeout: .now() + timeout)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        stateLock.lock(); let resolved = answer; stateLock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        return ProbeResult(isOpen: resolved?.open == true,
                           reachedHost: resolved?.reached == true,
                           milliseconds: elapsed)
    }

    private static func icmpPing(host: String, sequence: UInt16,
                                 timeout: TimeInterval) -> Double? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout),
                         tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        packet[4] = 0xAC; packet[5] = 0xED
        packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xFF)
        for index in 8..<16 { packet[index] = UInt8(index) }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xFF)
        let started = Date()
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0 else { return nil }
        var reply = [UInt8](repeating: 0, count: 1_024)
        while Date().timeIntervalSince(started) < timeout {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &reply, reply.count, 0, $0, &sourceLength)
                }
            }
            guard count > 0 else { return nil }
            // Only the probed host's own echo reply counts as proof of life.
            guard source.sin_addr.s_addr == address.sin_addr.s_addr else { continue }
            var offset = 0
            if count >= 20, reply[0] >> 4 == 4 { offset = Int(reply[0] & 0x0F) * 4 }
            guard count >= offset + 8 else { continue }
            let replySequence = (UInt16(reply[offset + 6]) << 8) | UInt16(reply[offset + 7])
            if reply[offset] == 0, replySequence == sequence {
                return Date().timeIntervalSince(started) * 1_000
            }
        }
        return nil
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum &+= (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum &+= UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }

    fileprivate static func ipv4Value(_ address: String) -> UInt32? {
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(octet)
        }
        return result
    }

    fileprivate static func ipv4String(_ value: UInt32) -> String {
        [value >> 24, (value >> 16) & 255, (value >> 8) & 255, value & 255]
            .map(String.init).joined(separator: ".")
    }

    private static func isContiguousMask(_ mask: UInt32) -> Bool {
        guard mask != 0 else { return false }
        let inverted = ~mask
        return inverted & (inverted &+ 1) == 0
    }
}

final class LANScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
