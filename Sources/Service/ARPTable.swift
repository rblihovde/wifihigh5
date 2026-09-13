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

    /// The first three octets of the address. Vendor resolution requires the
    /// local OUI registry.
    var oui: String {
        mac.split(separator: ":").prefix(3).joined(separator: ":")
    }
}

/// Reads the kernel's ARP cache.
///
/// These entries exist because this Mac has exchanged traffic with the hosts.
/// This read does not send traffic, probe addresses, or sweep the subnet.
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

        return buffer.withUnsafeBytes { raw in
            parse(UnsafeRawBufferPointer(rebasing: raw.prefix(needed)))
        }
        #endif
    }

    /// Decodes a routing-table dump into neighbour entries.
    ///
    /// The buffer comes from the kernel, not the network, so a hostile peer
    /// cannot shape it. It is still read with raw pointers, so every field is
    /// proved to lie inside its own message before it is touched, and a
    /// message that fails any check is skipped rather than trusted. Fields are
    /// read unaligned: the kernel packs messages end to end, and nothing
    /// guarantees a structure starts on its natural boundary.
    static func parse(_ raw: UnsafeRawBufferPointer) -> [ARPEntry] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        let lengthField = MemoryLayout<rt_msghdr>.offset(of: \.rtm_msglen)!
        let indexField = MemoryLayout<rt_msghdr>.offset(of: \.rtm_index)!
        let addressField = MemoryLayout<sockaddr_inarp>.offset(of: \.sin_addr)!
        let nameLengthField = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen)!
        let addressLengthField = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_alen)!
        let dataField = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!

        var entries: [ARPEntry] = []
        var offset = 0
        while offset + headerSize <= raw.count {
            let length = Int(raw.loadUnaligned(fromByteOffset: offset + lengthField, as: UInt16.self))
            // A length that would not advance, or that runs past the buffer,
            // means the rest cannot be framed. Stop rather than guess.
            guard length >= headerSize, offset + length <= raw.count else { break }
            defer { offset += length }
            let messageEnd = offset + length

            // The IPv4 address follows the header.
            let inetStart = offset + headerSize
            guard inetStart + addressField + MemoryLayout<in_addr>.size <= messageEnd else { continue }
            let inetLength = Int(raw[inetStart])

            // Route messages pad each address to a four-byte boundary. arp(8)
            // steps over it the same way, and an empty one still takes four.
            let inetStep = inetLength > 0 ? ((inetLength - 1) | 3) + 1 : 4
            let linkStart = inetStart + inetStep
            guard linkStart + dataField <= messageEnd else { continue }

            let nameLength = Int(raw[linkStart + nameLengthField])
            let addressLength = Int(raw[linkStart + addressLengthField])
            guard addressLength == 6 else { continue }
            let macStart = linkStart + dataField + nameLength
            guard macStart + 6 <= messageEnd else { continue }

            var address = raw.loadUnaligned(fromByteOffset: inetStart + addressField, as: in_addr.self)
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let mac = (0..<6).map { String(format: "%02x", raw[macStart + $0]) }.joined(separator: ":")

            let index = raw.loadUnaligned(fromByteOffset: offset + indexField, as: UInt16.self)
            var interfaceBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let interface = if_indextoname(UInt32(index), &interfaceBuffer).map { String(cString: $0) }
            entries.append(ARPEntry(ip: String(cString: text), mac: mac, interfaceName: interface))
        }
        return entries
    }

    /// Returns passive ARP entries for the active interface and IPv4 subnet.
    /// No network operation occurs here; this only filters entries already in
    /// the kernel cache.
    static func devicesOnActiveSubnet(_ entries: [ARPEntry],
                                      interface: String?,
                                      localAddress: String?,
                                      mask: String?) -> [ARPEntry] {
        guard let interface, let localAddress, let mask else { return [] }
        var byAddress: [String: ARPEntry] = [:]
        for entry in entries {
            guard entry.isUnicast,
                  entry.ip != localAddress,
                  entry.interfaceName == interface,
                  isHostOnSubnet(entry.ip, localAddress: localAddress, mask: mask) else {
                continue
            }
            byAddress[entry.ip] = entry
        }
        return byAddress.values.sorted {
            (ipv4Value($0.ip) ?? UInt32.max) < (ipv4Value($1.ip) ?? UInt32.max)
        }
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
