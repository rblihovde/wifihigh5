import Foundation
import Darwin

/// One neighbour this Mac has already exchanged traffic with.
struct ARPEntry: Hashable {
    var ip: String
    var mac: String

    /// Set when the second-least-significant bit of the first octet is on,
    /// which means the address was assigned by software rather than burned in —
    /// a randomised or virtual MAC rather than a real hardware address.
    var isLocallyAdministered: Bool {
        guard let first = mac.split(separator: ":").first,
              let byte = UInt8(first, radix: 16) else { return false }
        return byte & 0x02 != 0
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
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, Int32(RTF_LLINFO)]
        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, u_int(mib.count), &buffer, &needed, nil, 0) == 0 else { return [] }

        var entries: [ARPEntry] = []
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<rt_msghdr>.size <= needed {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength > 0, offset + messageLength <= needed else { break }
                defer { offset += messageLength }

                let base = raw.baseAddress!.advanced(by: offset)
                let sin = base.advanced(by: MemoryLayout<rt_msghdr>.size)
                    .assumingMemoryBound(to: sockaddr_inarp.self)
                let sdl = UnsafeRawPointer(sin)
                    .advanced(by: Int(sin.pointee.sin_len))
                    .assumingMemoryBound(to: sockaddr_dl.self)

                guard sdl.pointee.sdl_alen == 6 else { continue }
                guard let cString = inet_ntoa(sin.pointee.sin_addr) else { continue }

                let dataStart = UnsafeRawPointer(sdl)
                    .advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!)
                let macBytes = dataStart
                    .advanced(by: Int(sdl.pointee.sdl_nlen))
                    .assumingMemoryBound(to: UInt8.self)
                let mac = (0..<6).map { String(format: "%02x", macBytes[$0]) }.joined(separator: ":")

                entries.append(ARPEntry(ip: String(cString: cString), mac: mac))
            }
        }
        return entries
    }

    /// True when two MACs sit in the same vendor prefix and within a few
    /// addresses of each other. Manufacturers hand consecutive addresses to the
    /// interfaces of one chassis, so this is strong evidence that a router and
    /// an access point are the same physical box rather than two devices.
    static func likelySameChassis(_ a: String, _ b: String) -> Bool {
        let lhs = a.split(separator: ":"), rhs = b.split(separator: ":")
        guard lhs.count == 6, rhs.count == 6 else { return false }
        guard lhs.prefix(5) == rhs.prefix(5) else { return false }
        guard let l = UInt8(lhs[5], radix: 16), let r = UInt8(rhs[5], radix: 16) else { return false }
        return abs(Int(l) - Int(r)) <= 8
    }
}
