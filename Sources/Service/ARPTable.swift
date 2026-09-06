import Foundation
import Darwin

/// One neighbour this Mac has already exchanged traffic with.
struct ARPEntry: Hashable {
    var ip: String
    var mac: String
    /// Interface that owned the neighbour-cache entry at the time it was read.
    var interfaceName: String? = nil

    /// Set when the second-least-significant bit of the first octet is on,
    /// which means the address was assigned by software rather than burned in —
    /// a randomised or virtual MAC rather than a real hardware address.
    var isLocallyAdministered: Bool {
        guard let first = mac.split(separator: ":").first,
              let byte = UInt8(first, radix: 16) else { return false }
        return byte & 0x02 != 0
    }

    /// Multicast and broadcast cache rows describe delivery groups rather than
    /// devices and must not appear in a host count.
    var isUnicast: Bool {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return false }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else { return false }
        return bytes[0] & 0x01 == 0
    }

    /// The vendor prefix. Shown as-is rather than resolved to a name: without a
    /// local OUI registry any vendor label would be a guess, and a wrong one in
    /// front of a client is worse than none.
    var oui: String {
        mac.split(separator: ":").prefix(3).joined(separator: ":")
    }
}

/// Reads the kernel's ARP cache.
///
/// Entirely passive: these entries are already present because this Mac has
/// exchanged traffic with those hosts in the normal course of being connected.
/// Nothing is sent, no address is probed, and the subnet is never swept.
enum ARPTable {

    static func read() -> [ARPEntry] {
        // Screenshot builds show an invented subnet rather than the real one.
        #if DEMO_SCREENSHOTS
        return [
            ARPEntry(ip: DemoIdentifiers.router, mac: DemoIdentifiers.routerMAC, interfaceName: "en0"),
            ARPEntry(ip: "10.0.4.23", mac: "00:00:5e:00:53:11", interfaceName: "en0"),
            ARPEntry(ip: "10.0.4.44", mac: "00:00:5e:00:53:2c", interfaceName: "en0"),
            ARPEntry(ip: "10.0.4.87", mac: "9a:1f:00:53:64:d0", interfaceName: "en0"),
            ARPEntry(ip: "10.0.4.101", mac: "00:00:5e:00:53:7e", interfaceName: "en0"),
            ARPEntry(ip: "10.0.4.140", mac: "b2:44:00:53:19:aa", interfaceName: "en0")
        ]
        #else

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, Int32(RTF_LLINFO)]

        // The size is asked for and then filled in two separate calls, and the
        // table can grow in between. Ask for headroom and retry once rather
        // than silently returning nothing when a neighbour appears mid-read.
        var buffer = [UInt8]()
        var needed = 0
        for attempt in 0..<2 {
            var wanted = 0
            guard sysctl(&mib, u_int(mib.count), nil, &wanted, nil, 0) == 0, wanted > 0 else { return [] }
            let capacity = wanted + (wanted / 8) + 1024 * (attempt + 1)
            buffer = [UInt8](repeating: 0, count: capacity)
            needed = capacity
            if sysctl(&mib, u_int(mib.count), &buffer, &needed, nil, 0) == 0 { break }
            guard errno == ENOMEM, attempt == 0 else { return [] }
        }
        guard needed > 0, needed <= buffer.count else { return [] }

        var entries: [ARPEntry] = []
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<rt_msghdr>.size <= needed {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength > 0, offset + messageLength <= needed else { break }
                defer { offset += messageLength }

                let base = raw.baseAddress!.advanced(by: offset)
                let header = base.assumingMemoryBound(to: rt_msghdr.self)
                let sin = base.advanced(by: MemoryLayout<rt_msghdr>.size)
                    .assumingMemoryBound(to: sockaddr_inarp.self)
                let sdl = UnsafeRawPointer(sin)
                    .advanced(by: Int(sin.pointee.sin_len))
                    .assumingMemoryBound(to: sockaddr_dl.self)

                guard sdl.pointee.sdl_alen == 6 else { continue }
                var address = sin.pointee.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    continue
                }

                let dataStart = UnsafeRawPointer(sdl)
                    .advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!)
                let macBytes = dataStart
                    .advanced(by: Int(sdl.pointee.sdl_nlen))
                    .assumingMemoryBound(to: UInt8.self)
                let mac = (0..<6).map { String(format: "%02x", macBytes[$0]) }.joined(separator: ":")

                var interfaceBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                let interface = if_indextoname(UInt32(header.pointee.rtm_index), &interfaceBuffer)
                    .map { String(cString: $0) }
                entries.append(ARPEntry(ip: String(cString: text), mac: mac,
                                        interfaceName: interface))
            }
        }
        return entries
        #endif
    }

    /// True when two MACs sit in the same vendor prefix and within a few
    /// addresses of each other. Manufacturers hand consecutive addresses to the
    /// interfaces of one chassis, so this is strong evidence that a router and
    /// an access point are the same physical box rather than two devices.
    static func likelySameChassis(_ a: String, _ b: String) -> Bool {
        guard let lhs = macBytes(a), let rhs = macBytes(b) else { return false }
        // Locally administered or multicast addresses are software/network
        // constructs; adjacency says nothing reliable about shared hardware.
        guard lhs[0] & 0x03 == 0, rhs[0] & 0x03 == 0 else { return false }
        guard lhs.prefix(5) == rhs.prefix(5) else { return false }
        return abs(Int(lhs[5]) - Int(rhs[5])) <= 8
    }

    /// True when two IPv4 addresses belong to the same subnet. This keeps a
    /// multi-homed Mac's Ethernet, VPN, bridge, and Wi-Fi neighbour caches from
    /// being presented as one network.
    static func isOnSubnet(_ candidate: String, localAddress: String, mask: String) -> Bool {
        guard let candidateValue = ipv4Value(candidate),
              let localValue = ipv4Value(localAddress),
              let maskValue = ipv4Value(mask) else { return false }
        return candidateValue & maskValue == localValue & maskValue
    }

    /// True for a usable host address on the subnet, excluding the network and
    /// directed-broadcast addresses at either end of the range.
    static func isHostOnSubnet(_ candidate: String, localAddress: String, mask: String) -> Bool {
        guard let candidateValue = ipv4Value(candidate),
              let localValue = ipv4Value(localAddress),
              let maskValue = ipv4Value(mask) else { return false }
        let network = localValue & maskValue
        let broadcast = network | ~maskValue
        return candidateValue & maskValue == network &&
               candidateValue != network && candidateValue != broadcast
    }

    private static func ipv4Value(_ address: String) -> UInt32? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(octet)
        }
        return result
    }

    private static func macBytes(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes
    }
}
