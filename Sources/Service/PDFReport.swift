import Foundation
import AppKit
import SwiftUI
import CoreText

/// Everything a report sheet needs, gathered once so drawing never reaches back
/// into live models halfway through a page.
struct NetworkReportInput {
    var map: NetworkMap
    var devices: [ObservedDevice]
    var sample: WiFiSample?
    var status: LinkStatus
    var config: IPConfig
    var accessPoints: [APRecord]
    var networkName: String?
    var siteName: String
    var discoveryUsed: Bool
    var watchingSince: Date?
    var generated = Date()
}

/// Renders the network as a drawing set rather than a screenshot.
///
/// Everything is vector: the connectors, the hardware glyphs and the type. The
/// sheet furniture follows drawing-office convention — a ruled border with zone
/// markers, a title block in the bottom right, a legend keyed to line style,
/// and reference designators on each node so the schedules can point back at
/// the diagram.
enum PDFReport {

    // ANSI B, landscape: the sheet size a drawing of this kind is normally
    // issued on. Letter is too short for a path of four ranks of detailed
    // nodes, which forced the diagram down to an unreadable scale. This prints
    // on 11x17, or scales onto Letter without anything being lost.
    private static let pageSize = CGSize(width: 1224, height: 792)
    private static let margin: CGFloat = 22
    private static let innerInset: CGFloat = 34

    // MARK: Entry point

    static func render(_ input: NetworkReportInput) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, pageInfo(input)) else {
            return nil
        }

        let references = designators(for: input.map)

        // The schedule continues onto further sheets rather than being cut, so
        // the page count is not known until the devices have been counted.
        let devicePages = max(1, Int(ceil(Double(input.devices.count) / Double(rowsPerSheet))))
        var sheets: [(title: String, draw: (Pen) -> Void)] = [
            ("Network Diagram", { pen in diagramSheet(pen, input, references) })
        ]
        for page in 1...devicePages {
            sheets.append(("Device Schedule", { pen in
                deviceSheet(pen, input, page: page, pages: devicePages)
            }))
        }
        sheets.append(("Link and Radio Data", { pen in linkSheet(pen, input) }))
        sheets.append(("Method and Provenance", { pen in methodSheet(pen, input) }))

        for (index, sheet) in sheets.enumerated() {
            ctx.beginPDFPage(nil)
            let pen = Pen(ctx: ctx, page: pageSize)
            frame(pen, input, title: sheet.title, sheet: index + 1, of: sheets.count)
            sheet.draw(pen)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private static func pageInfo(_ input: NetworkReportInput) -> CFDictionary {
        [
            kCGPDFContextTitle: "WifiHigh5 network report — \(input.siteName)",
            kCGPDFContextCreator: "WifiHigh5",
            kCGPDFContextSubject: "Passive Wi-Fi link and topology survey"
        ] as CFDictionary
    }

    // MARK: Sheet furniture

    private static func frame(_ pen: Pen, _ input: NetworkReportInput,
                              title: String, sheet: Int, of total: Int) {
        let outer = CGRect(x: margin, y: margin,
                           width: pageSize.width - margin * 2,
                           height: pageSize.height - margin * 2)
        pen.stroke(rect: outer, color: Ink.rule, width: 1.1)

        let inner = outer.insetBy(dx: innerInset - margin, dy: innerInset - margin)
        pen.stroke(rect: inner, color: Ink.faint, width: 0.5)

        // Zone markers, as on a drawing sheet, so a reviewer can say where on
        // the page something sits.
        let columns = ["1", "2", "3", "4", "5", "6"]
        let rows = ["A", "B", "C", "D"]
        for (i, label) in columns.enumerated() {
            let x = outer.minX + outer.width * (CGFloat(i) + 0.5) / CGFloat(columns.count)
            pen.text(label, at: CGPoint(x: x, y: outer.minY + 9), font: Type.zone,
                     color: Ink.faintInk, align: .center)
            pen.text(label, at: CGPoint(x: x, y: outer.maxY - 4), font: Type.zone,
                     color: Ink.faintInk, align: .center)
        }
        for (i, label) in rows.enumerated() {
            let y = outer.minY + outer.height * (CGFloat(i) + 0.5) / CGFloat(rows.count)
            pen.text(label, at: CGPoint(x: outer.minX + 8, y: y), font: Type.zone,
                     color: Ink.faintInk, align: .center)
            pen.text(label, at: CGPoint(x: outer.maxX - 8, y: y), font: Type.zone,
                     color: Ink.faintInk, align: .center)
        }

        titleBlock(pen, input, title: title, sheet: sheet, of: total, within: inner)
    }

    /// Bottom-right, ruled, the way a drawing is signed.
    private static func titleBlock(_ pen: Pen, _ input: NetworkReportInput,
                                   title: String, sheet: Int, of total: Int,
                                   within inner: CGRect) {
        let size = CGSize(width: 318, height: 74)
        let box = CGRect(x: inner.maxX - size.width, y: inner.maxY - size.height,
                         width: size.width, height: size.height)
        pen.fill(rect: box, color: Ink.paper)
        pen.stroke(rect: box, color: Ink.rule, width: 0.9)

        let bandHeight: CGFloat = 26
        let band = CGRect(x: box.minX, y: box.minY, width: box.width, height: bandHeight)
        pen.stroke(line: CGPoint(x: box.minX, y: band.maxY),
                   to: CGPoint(x: box.maxX, y: band.maxY), color: Ink.rule, width: 0.7)

        pen.text("WIFIHIGH5", at: CGPoint(x: box.minX + 9, y: band.minY + 11),
                 font: Type.brand, color: Ink.text, tracking: 1.6)
        pen.text(title.uppercased(), at: CGPoint(x: box.minX + 9, y: band.minY + 21),
                 font: Type.blockLabel, color: Ink.muted, tracking: 0.9)
        pen.text("SHEET \(sheet) OF \(total)", at: CGPoint(x: box.maxX - 9, y: band.minY + 16),
                 font: Type.blockValue, color: Ink.text, align: .right)

        // Two rows of field/value pairs beneath the band.
        let fields: [[(String, String)]] = [
            [("SITE", input.siteName),
             ("NETWORK", input.networkName ?? "Not available")],
            [("DRAWN", Fmt.reportStamp(input.generated)),
             ("BASIS", input.discoveryUsed ? "Observed + asked" : "Observed only")]
        ]
        let columnWidth = box.width / 2
        for (rowIndex, row) in fields.enumerated() {
            let y = band.maxY + 14 + CGFloat(rowIndex) * 20
            for (columnIndex, pair) in row.enumerated() {
                let x = box.minX + 9 + CGFloat(columnIndex) * columnWidth
                pen.text(pair.0, at: CGPoint(x: x, y: y - 7),
                         font: Type.blockLabel, color: Ink.muted, tracking: 0.8)
                pen.text(pen.elide(pair.1, font: Type.blockValue, maxWidth: columnWidth - 18),
                         at: CGPoint(x: x, y: y + 4), font: Type.blockValue, color: Ink.text)
            }
        }
        pen.stroke(line: CGPoint(x: box.minX + columnWidth, y: band.maxY),
                   to: CGPoint(x: box.minX + columnWidth, y: box.maxY),
                   color: Ink.faint, width: 0.5)
    }

    /// Reference designators, assigned in reading order so N1 is the top of the
    /// path and the schedules can cite them.
    private static func designators(for map: NetworkMap) -> [String: String] {
        let ordered = map.nodes.sorted {
            ($0.row, $0.column) < ($1.row, $1.column)
        }
        var table: [String: String] = [:]
        for (index, node) in ordered.enumerated() {
            table[node.id] = "N\(index + 1)"
        }
        return table
    }
}
