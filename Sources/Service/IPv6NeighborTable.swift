import Foundation
import Darwin

struct IPv6Neighbor: Hashable {
    var ip: String
    var mac: String
    var interfaceName: String?

    var scopedAddress: String {
        guard ip.lowercased().hasPrefix("fe80:"), let interfaceName else { return ip }
        return "\(ip)%\(interfaceName)"
    }
}

/// Reads IPv6 neighbours learned by macOS's Neighbor Discovery Protocol.
/// Like the ARP reader, this is passive and sends no packet.
enum IPv6NeighborTable {
    /// Sends one link-local all-nodes ICMPv6 echo. Replies cause macOS to learn
    /// active IPv6 neighbours; the normal table read collects them afterward.
    /// Failure is harmless because the passive table remains available.
    @discardableResult
    static func solicit(interface: String, settleTime: TimeInterval = 0.35) -> Bool {
        let index = if_nametoindex(interface)
        guard index != 0 else { return false }
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var multicastInterface = index
        setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF,
                   &multicastInterface, socklen_t(MemoryLayout<UInt32>.size))
        var hops: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS,
                   &hops, socklen_t(MemoryLayout<Int32>.size))

        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_scope_id = index
        guard "ff02::1".withCString({ inet_pton(AF_INET6, $0, &destination.sin6_addr) }) == 1 else {
            return false
        }
        let identifier = UInt16.random(in: 1...UInt16.max)
        let packet: [UInt8] = [
            128, 0, 0, 0, // ICMPv6 echo request; kernel supplies checksum
            UInt8(identifier >> 8), UInt8(identifier & 0xFF), 0, 1,
            0x57, 0x69, 0x66, 0x69, 0x48, 0x69, 0x67, 0x68
        ]
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard sent == packet.count else { return false }
        Thread.sleep(forTimeInterval: settleTime)
        return true
    }

    static func read() -> [IPv6Neighbor] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET6, NET_RT_FLAGS, Int32(RTF_LLINFO)]
        var wanted = 0
        guard sysctl(&mib, u_int(mib.count), nil, &wanted, nil, 0) == 0, wanted > 0 else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: wanted + wanted / 8 + 1024)
        var length = buffer.count
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0,
              length <= buffer.count else { return [] }
        return buffer.withUnsafeBytes {
            parse(UnsafeRawBufferPointer(rebasing: $0.prefix(length)))
        }
    }

    static func parse(_ raw: UnsafeRawBufferPointer) -> [IPv6Neighbor] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        let messageLengthField = MemoryLayout<rt_msghdr>.offset(of: \.rtm_msglen)!
        let indexField = MemoryLayout<rt_msghdr>.offset(of: \.rtm_index)!
        let addressField = MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!
        let nameLengthField = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen)!
        let addressLengthField = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_alen)!
        let dataField = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!

        var result: [IPv6Neighbor] = []
        var offset = 0
        while offset + headerSize <= raw.count {
            let length = Int(raw.loadUnaligned(fromByteOffset: offset + messageLengthField,
                                               as: UInt16.self))
            guard length >= headerSize, offset + length <= raw.count else { break }
            defer { offset += length }
            let messageEnd = offset + length
            let inetStart = offset + headerSize
            guard inetStart < messageEnd, raw[inetStart] >= UInt8(addressField + 16),
                  inetStart + addressField + 16 <= messageEnd else { continue }
            let inetLength = Int(raw[inetStart])
            let inetStep = inetLength > 0 ? ((inetLength - 1) | 3) + 1 : 4
            let linkStart = inetStart + inetStep
            guard linkStart + dataField <= messageEnd else { continue }

            let nameLength = Int(raw[linkStart + nameLengthField])
            let macLength = Int(raw[linkStart + addressLengthField])
            guard macLength == 6 else { continue }
            let macStart = linkStart + dataField + nameLength
            guard macStart + 6 <= messageEnd else { continue }

            var address = raw.loadUnaligned(fromByteOffset: inetStart + addressField,
                                            as: in6_addr.self)
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                continue
            }
            let ip = String(cString: text).lowercased()
            guard ip != "::", ip != "::1", !ip.lowercased().hasPrefix("ff") else { continue }
            let mac = (0..<6).map { String(format: "%02x", raw[macStart + $0]) }
                .joined(separator: ":")

            let index = raw.loadUnaligned(fromByteOffset: offset + indexField, as: UInt16.self)
            var interfaceBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let interface = if_indextoname(UInt32(index), &interfaceBuffer)
                .map { String(cString: $0) }
            result.append(IPv6Neighbor(ip: ip, mac: mac, interfaceName: interface))
        }

        var unique: [String: IPv6Neighbor] = [:]
        for entry in result { unique["\(entry.interfaceName ?? "")|\(entry.ip)"] = entry }
        return unique.values.sorted { $0.ip.localizedStandardCompare($1.ip) == .orderedAscending }
    }

    static func onInterface(_ entries: [IPv6Neighbor], interface: String?) -> [IPv6Neighbor] {
        guard let interface else { return [] }
        return entries.filter { $0.interfaceName == interface }
    }
}
