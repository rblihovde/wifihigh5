import Foundation
import AppKit
import SwiftUI

extension PDFReport {

    struct Column {
        var title: String
        var width: CGFloat
        var mono = false
        var align: Pen.Align = .left
    }

    /// Rows per schedule sheet, so a long device list continues onto further
    /// sheets rather than being silently cut.
    static var rowsPerSheet: Int { 36 }

    @discardableResult
    static func table(_ pen: Pen, columns: [Column], rows: [[String]],
                      top: CGFloat, rowHeight: CGFloat = 15) -> CGFloat {
        var x = contentLeft
        pen.fill(rect: CGRect(x: contentLeft, y: top, width: contentRight - contentLeft,
                              height: rowHeight), color: NSColor(white: 0.94, alpha: 1).cgColor)
        for column in columns {
            let anchorX: CGFloat
            switch column.align {
            case .left:   anchorX = x + 5
            case .center: anchorX = x + column.width / 2
            case .right:  anchorX = x + column.width - 5
            }
            pen.text(column.title.uppercased(),
                     at: CGPoint(x: anchorX, y: top + rowHeight - 5),
                     font: Type.tableHead, color: Ink.muted,
                     align: column.align, tracking: 0.7)
            x += column.width
        }

        var y = top + rowHeight
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 2) {
                pen.fill(rect: CGRect(x: contentLeft, y: y,
                                      width: contentRight - contentLeft, height: rowHeight),
                         color: NSColor(white: 0.975, alpha: 1).cgColor)
            }
            var cx = contentLeft
            for (columnIndex, column) in columns.enumerated() {
                let value = columnIndex < row.count ? row[columnIndex] : ""
                let font = column.mono ? Type.tableMono : Type.tableCell
                let anchorX: CGFloat
                switch column.align {
                case .left:   anchorX = cx + 5
                case .center: anchorX = cx + column.width / 2
                case .right:  anchorX = cx + column.width - 5
                }
                pen.text(pen.elide(value, font: font, maxWidth: column.width - 10),
                         at: CGPoint(x: anchorX, y: y + rowHeight - 4.5),
                         font: font, color: Ink.text, align: column.align)
                cx += column.width
            }
            y += rowHeight
        }

        pen.stroke(rect: CGRect(x: contentLeft, y: top,
                                width: contentRight - contentLeft, height: y - top),
                   color: Ink.faint, width: 0.5)
        var vx = contentLeft
        for column in columns.dropLast() {
            vx += column.width
            pen.stroke(line: CGPoint(x: vx, y: top), to: CGPoint(x: vx, y: y),
                       color: Ink.faint, width: 0.4)
        }
        pen.stroke(line: CGPoint(x: contentLeft, y: top + rowHeight),
                   to: CGPoint(x: contentRight, y: top + rowHeight),
                   color: Ink.rule, width: 0.6)
        return y
    }

    // MARK: - Sheet 2: device schedule

    static func deviceSheet(_ pen: Pen, _ input: NetworkReportInput,
                            page: Int, pages: Int) {
        let continuation = pages > 1 ? "  (\(page) of \(pages))" : ""
        sheetHeading(pen, "Device Schedule" + continuation,
                     "Devices already in this Mac's neighbour cache on the Wi-Fi subnet. A device that is absent from this list is not necessarily absent from the network.")

        let columns = [
            Column(title: "Name", width: 240),
            Column(title: "Role", width: 140),
            Column(title: "Type", width: 140),
            Column(title: "IP address", width: 120, mono: true),
            Column(title: "MAC address", width: 150, mono: true),
            Column(title: "Manufacturer", width: 190),
            Column(title: "Evidence", width: 90),
            Column(title: "Status", width: 66)
        ]

        let start = (page - 1) * rowsPerSheet
        let slice = Array(input.devices.dropFirst(start).prefix(rowsPerSheet))
        let rows: [[String]] = slice.map { device in
            let type: String = {
                if device.category != .unlabelled { return device.category.label }
                if let guess = device.guess { return guess.summary }
                return "—"
            }()
            return [
                device.displayName,
                device.role.label,
                type,
                device.ip,
                device.mac,
                device.vendorText,
                device.wasDiscovered ? "Asked" : "Observed",
                device.isPresent ? (device.isNew ? "Arrived" : "Present") : "Gone"
            ]
        }
        let bottom = table(pen, columns: columns, rows: rows, top: contentTop + 8)

        if page == pages {
            pen.text("A type shown without a label from you is an inference. Where the Evidence column reads Asked, the device or this network's DNS supplied the name; everything else was read from a cache this Mac already held.",
                     at: CGPoint(x: contentLeft, y: min(bottom + 16, contentBottom + 40)),
                     font: Type.caption, color: Ink.muted)
        }
    }

    // MARK: - Sheet 3: link and radio

    private static func panel(_ pen: Pen, title: String, rect: CGRect,
                              pairs: [(String, String)]) {
        pen.stroke(rect: rect, color: Ink.faint, width: 0.6)
        pen.fill(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 15),
                 color: NSColor(white: 0.94, alpha: 1).cgColor)
        pen.text(title.uppercased(), at: CGPoint(x: rect.minX + 7, y: rect.minY + 10.5),
                 font: Type.sectionHead, color: Ink.muted, tracking: 0.9)

        var y = rect.minY + 27
        for pair in pairs {
            guard y < rect.maxY - 2 else { break }
            pen.text(pair.0, at: CGPoint(x: rect.minX + 7, y: y),
                     font: Type.bodySmall, color: Ink.muted)
            pen.text(pen.elide(pair.1, font: Type.tableMono,
                               maxWidth: rect.width - pen.width(of: pair.0, font: Type.bodySmall) - 22),
                     at: CGPoint(x: rect.maxX - 7, y: y),
                     font: Type.tableMono, color: Ink.text, align: .right)
            y += 13
        }
    }

    static func linkSheet(_ pen: Pen, _ input: NetworkReportInput) {
        sheetHeading(pen, "Link and Radio Data",
                     "The state of the link this Mac had joined when the sheet was drawn. Every value here was read from the system, none was probed.")

        let sample = input.sample
        let width: CGFloat = 372
        let gap: CGFloat = 10
        let top = contentTop + 8

        panel(pen, title: "Connection",
              rect: CGRect(x: contentLeft, y: top, width: width, height: 132),
              pairs: [
                ("Network", sample?.ssid ?? "Not available"),
                ("BSSID", sample?.bssid ?? "Not available"),
                ("Channel", sample.map { String($0.channel) } ?? "—"),
                ("Band", sample.map { bandLabel($0.bandRaw).label } ?? "—"),
                ("Channel width", sample.map { channelWidthLabel($0.channelWidthRaw) } ?? "—"),
                ("PHY mode", sample.map { phyModeLabel($0.phyRaw) } ?? "—"),
                ("Security", sample.map { securityLabel($0.securityRaw) } ?? "—"),
                ("Country", sample?.countryCode ?? "—")
              ])

        panel(pen, title: "Signal",
              rect: CGRect(x: contentLeft + width + gap, y: top, width: width, height: 132),
              pairs: [
                ("Signal (RSSI)", sample.map { "\($0.rssi) dBm" } ?? "—"),
                ("Noise floor", sample?.validNoise.map { "\($0) dBm" } ?? "Not reported"),
                ("Signal clarity (SNR)", sample?.snr.map { "\($0) dB" } ?? "Not available"),
                ("Transmit rate", sample.map { Fmt.rate($0.txRate) } ?? "—"),
                ("Transmit power", sample.map { $0.txPower > 0 ? "\($0.txPower) mW" : "—" } ?? "—"),
                ("Verdict", sample.map { $0.quality.label } ?? "—"),
                ("Interface", sample?.interfaceName ?? input.config.primaryInterface ?? "—"),
                ("Link state", input.status.label)
              ])

        let lease: String = {
            guard let expiry = input.config.leaseExpiry else { return "—" }
            return Fmt.reportStamp(expiry)
        }()
        panel(pen, title: "IP configuration",
              rect: CGRect(x: contentLeft + (width + gap) * 2, y: top, width: width, height: 132),
              pairs: [
                ("IPv4 address", input.config.ipv4 ?? "—"),
                ("Subnet mask", input.config.subnetMask ?? "—"),
                ("Router", input.config.router ?? "—"),
                ("DNS servers", input.config.dnsServers.prefix(2).joined(separator: ", ")),
                ("Search domains", input.config.searchDomains.first ?? "—"),
                ("DHCP server", input.config.dhcpServer ?? "—"),
                ("Lease expires", lease),
                ("Address on the wire", input.config.activeMAC ?? "—")
              ])

        // Access points this Mac has named or seen.
        let apTop = top + 156
        pen.text("ACCESS POINTS", at: CGPoint(x: contentLeft, y: apTop - 6),
                 font: Type.sectionHead, color: Ink.muted, tracking: 0.9)
        let columns = [
            Column(title: "Name", width: 260),
            Column(title: "Site", width: 170),
            Column(title: "Identity", width: 180, mono: true),
            Column(title: "Channel", width: 90, align: .right),
            Column(title: "Band", width: 80),
            Column(title: "Best dBm", width: 110, mono: true, align: .right),
            Column(title: "Worst dBm", width: 110, mono: true, align: .right),
            Column(title: "Last seen", width: 136, mono: true, align: .right)
        ]
        let rows: [[String]] = input.accessPoints.prefix(16).map { record in
            [
                record.hasNickname ? record.nickname : "Not named",
                record.site.isEmpty ? "—" : record.site,
                record.key.bssidValue.map { Fmt.shortMAC($0) } ?? "Not available",
                record.lastChannel.map(String.init) ?? "—",
                bandLabel(record.lastBandRaw ?? 0).short,
                record.bestRSSI.map { "\($0)" } ?? "—",
                record.worstRSSI.map { "\($0)" } ?? "—",
                Fmt.relativeTime(record.lastSeen)
            ]
        }
        if rows.isEmpty {
            pen.text("No access point has been recorded yet.",
                     at: CGPoint(x: contentLeft, y: apTop + 14),
                     font: Type.body, color: Ink.muted)
        } else {
            table(pen, columns: columns, rows: rows, top: apTop + 2, rowHeight: 14)
        }
    }

    // MARK: - Sheet 4: method

    static func methodSheet(_ pen: Pen, _ input: NetworkReportInput) {
        sheetHeading(pen, "Method and Provenance",
                     "How every figure in this set was obtained, so a reader can judge what it is worth.")

        struct Section { var title: String; var body: [String] }
        let sections: [Section] = [
            Section(title: "What this is",
                    body: [
                        "This set records the state of one Wi-Fi link and the devices this Mac had already exchanged traffic with, at the moment given in the title block. It is a snapshot of one vantage point, not an audit of the network.",
                        "Readings come from the radio this Mac is associated with. Another device, in another part of the building, would produce different numbers."
                    ]),
            Section(title: "What the app read",
                    body: [
                        "The state of the Wi-Fi link this Mac had already joined, through CoreWLAN. The IP settings this Mac was assigned, through the system configuration database. The kernel's existing neighbour cache, which lists hosts this Mac has exchanged traffic with. Hardware makers were resolved against a copy of the IEEE registry carried inside the app.",
                        "None of that transmits anything. It is all state the operating system was already holding."
                    ]),
            Section(title: "What the app did not do",
                    body: [
                        "It did not scan ports, sweep addresses, capture packets, or attempt to reach any host beyond the local gateway. It cannot see traffic between two other devices: Wi-Fi delivers frames only to the client they are addressed to, and each client holds a different key.",
                        "Absence from the device schedule therefore means the device had not spoken to this Mac. It does not mean the device was not there."
                    ]),
            Section(title: "Where a value was obtained by asking",
                    body: [
                        input.discoveryUsed
                            ? "Some names in this set were obtained by asking. Bonjour queries were sent on the local subnet, or reverse lookups were sent to this network's name servers, at the operator's request. Every row carrying such a value is marked Asked in the device schedule."
                            : "Nothing in this set was obtained by asking. No query was sent to any device, and no lookup was sent to any name server."
                    ]),
            Section(title: "Reading confidence",
                    body: [
                        "Measured: read directly from this Mac or reported by a device that was asked. Inferred: derived from measured facts by stated reasoning, such as a router and access point sharing one chassis because their hardware addresses are adjacent within one vendor block. Not observable: a path that must exist for the network to work but that a client cannot see, such as switching between the access point and the router.",
                        "An unobservable path is drawn rather than omitted, so the diagram does not read as though it were complete."
                    ])
        ]

        var y = contentTop + 10
        let columnWidth = (contentRight - contentLeft - 24) / 2
        var column = 0
        for section in sections {
            let x = contentLeft + CGFloat(column) * (columnWidth + 24)
            pen.text(section.title.uppercased(), at: CGPoint(x: x, y: y),
                     font: Type.sectionHead, color: Ink.text, tracking: 0.9)
            pen.stroke(line: CGPoint(x: x, y: y + 4),
                       to: CGPoint(x: x + columnWidth, y: y + 4), color: Ink.faint, width: 0.4)
            y += 16
            for paragraph in section.body {
                let used = pen.paragraph(paragraph,
                                         in: CGRect(x: x, y: y, width: columnWidth,
                                                    height: contentBottom - y),
                                         font: Type.bodySmall, color: Ink.text, lineHeight: 10)
                y += used + 8
            }
            y += 6
            // Move to the second column once the first is full.
            if y > contentBottom - 60, column == 0 {
                column = 1
                y = contentTop + 10
            }
        }
    }
}
