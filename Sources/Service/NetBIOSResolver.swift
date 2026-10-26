import Foundation
import Darwin

struct NetBIOSIdentity: Equatable {
    var name: String?
    var domain: String?
}

/// Resolves the legacy Windows computer and workgroup names published over
/// NetBIOS Name Service. This sends one NBSTAT request to UDP port 137 and
/// never attempts SMB authentication.
enum NetBIOSResolver {
    static func lookup(_ address: String, timeout: TimeInterval) -> NetBIOSIdentity? {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(137).bigEndian
        guard address.withCString({ inet_pton(AF_INET, $0, &target.sin_addr) }) == 1 else {
            return nil
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout),
                         tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let id = UInt16.random(in: 1...UInt16.max)
        let packet = request(id: id)
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        var reply = [UInt8](repeating: 0, count: 1_024)
        let received = recvfrom(fd, &reply, reply.count, 0, nil, nil)
        guard received > 0 else { return nil }
        return parse(Data(reply.prefix(received)), expectedID: id)
    }

    static func parse(_ data: Data, expectedID: UInt16? = nil) -> NetBIOSIdentity? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }
        let id = word(bytes, 0)
        if let expectedID, id != expectedID { return nil }
        let questionCount = Int(word(bytes, 4))
        guard bytes[2] & 0x80 != 0, word(bytes, 6) > 0 else { return nil }

        var offset = 12
        for _ in 0..<questionCount {
            guard skipName(bytes, offset: &offset), offset + 4 <= bytes.count else { return nil }
            offset += 4
        }

        guard skipName(bytes, offset: &offset), offset + 10 <= bytes.count else { return nil }
        let type = word(bytes, offset)
        let length = Int(word(bytes, offset + 8))
        offset += 10
        guard type == 0x0021, length > 0, offset + length <= bytes.count else { return nil }

        let count = Int(bytes[offset])
        offset += 1
        guard count <= 100, offset + count * 18 <= bytes.count else { return nil }
        var host: String?
        var domain: String?
        for _ in 0..<count {
            let rawName = String(bytes: bytes[offset..<(offset + 15)], encoding: .ascii) ?? ""
            let name = UntrustedText.clean(rawName.trimmingCharacters(in: .whitespacesAndNewlines),
                                           limit: 15)
            let suffix = bytes[offset + 15]
            let flags = word(bytes, offset + 16)
            let isGroup = flags & 0x8000 != 0
            if !name.isEmpty {
                if isGroup, suffix == 0x00, domain == nil { domain = name }
                if !isGroup, (suffix == 0x00 || suffix == 0x20), host == nil { host = name }
            }
            offset += 18
        }
        guard host != nil || domain != nil else { return nil }
        return NetBIOSIdentity(name: host, domain: domain)
    }

    private static func request(id: UInt16) -> Data {
        var packet: [UInt8] = [
            UInt8(id >> 8), UInt8(id & 0xFF),
            0x00, 0x00, // flags
            0x00, 0x01, // one question
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        var name = [UInt8](repeating: 0x20, count: 16)
        name[0] = 0x2A // wildcard '*'
        packet.append(32)
        for byte in name {
            packet.append(0x41 + (byte >> 4))
            packet.append(0x41 + (byte & 0x0F))
        }
        packet.append(0)
        packet += [0x00, 0x21, 0x00, 0x01] // NBSTAT, IN
        return Data(packet)
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func skipName(_ bytes: [UInt8], offset: inout Int) -> Bool {
        guard offset < bytes.count else { return false }
        if bytes[offset] & 0xC0 == 0xC0 {
            guard offset + 2 <= bytes.count else { return false }
            offset += 2
            return true
        }
        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            if length == 0 { return true }
            guard length <= 63, offset + length <= bytes.count else { return false }
            offset += length
        }
        return false
    }
}
