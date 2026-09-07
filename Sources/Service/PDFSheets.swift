import Foundation
import AppKit
import SwiftUI

// Sheet layout constants shared by every page.
extension PDFReport {
    static var inner: CGRect { CGRect(x: 34, y: 34, width: 1156, height: 724) }
    static var contentTop: CGFloat { 74 }
    static var contentBottom: CGFloat { 674 }
    static var contentLeft: CGFloat { 44 }
    static var contentRight: CGFloat { 1180 }

    static func sheetHeading(_ pen: Pen, _ title: String, _ subtitle: String) {
        pen.text(title, at: CGPoint(x: contentLeft, y: 58),
                 font: Type.sheetTitle, color: Ink.text)
        pen.text(subtitle, at: CGPoint(x: contentLeft, y: 68),
                 font: Type.caption, color: Ink.muted)
        pen.stroke(line: CGPoint(x: contentLeft, y: 72),
                   to: CGPoint(x: contentRight, y: 72), color: Ink.faint, width: 0.5)
    }

    // MARK: - Sheet 1: the diagram

    /// Facts worth printing. A sheet has no zoom, so this is the level a reader
    /// gets. It is capped because a node tall enough to hold everything forces
    /// the whole drawing down to an unreadable scale; the rest stays in the app
    /// and in the schedules.
    static var factsPerNode: Int { 7 }

    static func printedFacts(_ node: MapNode) -> [Fact] {
        Array(node.facts.filter { !$0.inspectorOnly && $0.detail <= .secondary }
            .prefix(factsPerNode))
    }

    static func omittedFactCount(_ node: MapNode) -> Int {
        let all = node.facts.filter { !$0.inspectorOnly && $0.detail <= .secondary }
        return max(0, all.count - factsPerNode)
    }

    static func nodeHeight(_ node: MapNode) -> CGFloat {
        let facts = printedFacts(node)
        let extra: CGFloat = omittedFactCount(node) > 0 ? 11 : 0
        return facts.isEmpty ? 50 : 58 + CGFloat(facts.count) * 13 + extra
    }

    /// Places the lattice, giving each row the height its tallest node needs.
    ///
    /// The on-screen map can use a fixed row pitch because it scrolls. A sheet
    /// cannot, and a fixed pitch here drops a tall node straight through the
    /// one below it.
    static func layout(_ map: NetworkMap) -> [String: CGRect] {
        let width: CGFloat = 232
        let connectorRun: CGFloat = 78
        let grouped = Dictionary(grouping: map.nodes, by: \.row)

        var placed: [String: CGRect] = [:]
        var y: CGFloat = 0
        for key in grouped.keys.sorted() {
            let nodes = grouped[key] ?? []
            let tallest = nodes.map(nodeHeight).max() ?? 50
            for node in nodes {
                let height = nodeHeight(node)
                placed[node.id] = CGRect(x: node.column * 280 - width / 2,
                                         y: y + (tallest - height) / 2,
                                         width: width, height: height)
            }
            y += tallest + connectorRun
        }
        return placed
    }

    static func diagramSheet(_ pen: Pen, _ input: NetworkReportInput,
                             _ refs: [String: String]) {
        sheetHeading(pen, "Network Diagram",
                     "Signal path from this Mac to the gateway. Line style carries confidence, not importance.")

        let area = CGRect(x: contentLeft, y: contentTop,
                          width: contentRight - contentLeft,
                          height: contentBottom - contentTop - 8)

        // Drafting grid, faint enough to read through.
        var grid = Path()
        var gx = area.minX
        while gx <= area.maxX { grid.move(to: CGPoint(x: gx, y: area.minY))
            grid.addLine(to: CGPoint(x: gx, y: area.maxY)); gx += 24 }
        var gy = area.minY
        while gy <= area.maxY { grid.move(to: CGPoint(x: area.minX, y: gy))
            grid.addLine(to: CGPoint(x: area.maxX, y: gy)); gy += 24 }
        pen.stroke(path: grid, color: Ink.grid, width: 0.3)

        let map = input.map
        guard !map.nodes.isEmpty else {
            pen.text("No topology was available when this sheet was drawn.",
                     at: CGPoint(x: area.midX, y: area.midY), font: Type.body,
                     color: Ink.muted, align: .center)
            legend(pen, input)
            return
        }

        // Fit the lattice to the drawing area.
        let placed = layout(map)
        guard var bounds = placed[map.nodes[0].id] else { return }
        for node in map.nodes.dropFirst() {
            if let rect = placed[node.id] { bounds = bounds.union(rect) }
        }
        bounds = bounds.insetBy(dx: -18, dy: -18)
        let scale = min(area.width / bounds.width, area.height / bounds.height, 1.0)
        let offset = CGPoint(
            x: area.midX - bounds.midX * scale,
            y: area.midY - bounds.midY * scale)

        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
        }
        func place(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale + offset.x, y: rect.minY * scale + offset.y,
                   width: rect.width * scale, height: rect.height * scale)
        }

        for edge in map.edges { drawEdge(pen, edge, map, placed, place, scale) }
        for node in map.nodes {
            guard let rect = placed[node.id] else { continue }
            drawNode(pen, node, place(rect), scale, refs[node.id])
        }
        legend(pen, input)
        notesBlock(pen, input)
    }

    private static func drawEdge(_ pen: Pen, _ edge: MapEdge, _ map: NetworkMap,
                                 _ placed: [String: CGRect],
                                 _ place: (CGPoint) -> CGPoint, _ scale: CGFloat) {
        guard let ra = placed[edge.from], let rb = placed[edge.to] else { return }
        let start = CGPoint(x: ra.midX, y: ra.maxY)
        let end = CGPoint(x: rb.midX, y: rb.minY)
        let midY = (start.y + end.y) / 2

        var path = Path()
        path.move(to: place(start))
        if abs(start.x - end.x) < 0.5 {
            path.addLine(to: place(end))
        } else {
            path.addLine(to: place(CGPoint(x: start.x, y: midY)))
            path.addLine(to: place(CGPoint(x: end.x, y: midY)))
            path.addLine(to: place(end))
        }

        let color = Ink.confidence(edge.confidence)
        let dash: [CGFloat] = edge.confidence == .unobserved ? [4, 3] : []
        pen.stroke(path: path, color: color,
                   width: edge.kind == .wireless ? 1.5 : 1.0, dash: dash)

        // Terminators, as on a schematic.
        for point in [start, end] {
            let p = place(point)
            pen.fill(path: Path(ellipseIn: CGRect(x: p.x - 1.8, y: p.y - 1.8,
                                                  width: 3.6, height: 3.6)),
                     color: color)
        }

        let caption = edge.caption ?? edge.kind.label
        let anchor = place(CGPoint(x: (start.x + end.x) / 2, y: midY))
        let textWidth = pen.width(of: caption, font: Type.edgeLabel)
        let plate = CGRect(x: anchor.x - textWidth / 2 - 3, y: anchor.y - 5,
                           width: textWidth + 6, height: 10)
        pen.fill(rect: plate, color: Ink.paper)
        pen.text(caption, at: CGPoint(x: anchor.x, y: anchor.y + 2.5),
                 font: Type.edgeLabel, color: color, align: .center)
    }

    /// Draws one node.
    ///
    /// Every offset and every type size is multiplied by the sheet scale. The
    /// plate is scaled, so anything drawn at a fixed size inside it runs
    /// straight out of the bottom once the drawing is reduced to fit.
    private static func drawNode(_ pen: Pen, _ node: MapNode, _ box: CGRect,
                                 _ scale: CGFloat, _ reference: String?) {
        let color = Ink.confidence(node.confidence)
        let s = scale
        pen.fill(rounded: box, radius: 4 * s, color: Ink.plate)
        pen.stroke(rounded: box, radius: 4 * s, color: color, width: 0.9,
                   dash: node.confidence == .unobserved ? [3, 2.5] : [])

        // Reference designator, so the schedules can cite this node.
        if let reference {
            let tag = CGRect(x: box.minX + 5 * s, y: box.minY + 4 * s,
                             width: 20 * s, height: 10 * s)
            pen.stroke(rect: tag, color: Ink.faint, width: 0.5)
            pen.text(reference, at: CGPoint(x: tag.midX, y: tag.maxY - 2.8 * s),
                     font: Type.mono(6.5 * s, .bold), color: Ink.muted, align: .center)
        }

        let glyphSide = 24 * s
        let glyphRect = CGRect(x: box.minX + 30 * s, y: box.minY + 4 * s,
                               width: glyphSide, height: glyphSide)
        let glyph = DeviceGlyph.draw(node.kind, in: glyphRect)
        pen.stroke(path: glyph.outline, color: color, width: 0.9)
        pen.stroke(path: glyph.detail, color: Ink.muted, width: 0.6)
        pen.stroke(path: glyph.accent, color: color, width: 0.75)

        let textX = glyphRect.maxX + 7 * s
        let available = box.maxX - textX - 8 * s
        let titleFont = Type.sans(9 * s, .semibold)
        pen.text(pen.elide(node.title, font: titleFont, maxWidth: available),
                 at: CGPoint(x: textX, y: box.minY + 14 * s),
                 font: titleFont, color: Ink.text)
        if let subtitle = node.subtitle {
            let subFont = Type.mono(6.5 * s)
            pen.text(pen.elide(subtitle, font: subFont, maxWidth: available),
                     at: CGPoint(x: textX, y: box.minY + 24 * s),
                     font: subFont, color: Ink.muted)
        }
        if node.confidence != .observed {
            pen.text(node.confidence.label.uppercased(),
                     at: CGPoint(x: box.maxX - 6 * s, y: box.minY + 11 * s),
                     font: Type.sans(5.5 * s, .bold), color: color,
                     align: .right, tracking: 0.5 * s)
        }

        let facts = printedFacts(node)
        guard !facts.isEmpty else { return }
        let keyFont = Type.sans(6.5 * s)
        let valueFont = Type.mono(6.5 * s, .medium)
        var y = box.minY + 40 * s
        pen.stroke(line: CGPoint(x: box.minX + 7 * s, y: y - 7 * s),
                   to: CGPoint(x: box.maxX - 7 * s, y: y - 7 * s),
                   color: Ink.faint, width: 0.4)
        for fact in facts {
            pen.text(fact.label, at: CGPoint(x: box.minX + 8 * s, y: y),
                     font: keyFont, color: Ink.muted)
            let keyWidth = pen.width(of: fact.label, font: keyFont)
            let room = box.width - keyWidth - 24 * s
            pen.text(pen.elide(fact.value, font: valueFont, maxWidth: room),
                     at: CGPoint(x: box.maxX - 8 * s, y: y),
                     font: valueFont, color: Ink.text, align: .right)
            y += 13 * s
        }
        let omitted = omittedFactCount(node)
        if omitted > 0 {
            pen.text("+\(omitted) more in the app",
                     at: CGPoint(x: box.minX + 8 * s, y: y + 1 * s),
                     font: Type.sans(6 * s), color: Ink.faintInk)
        }
    }

    private static func legend(_ pen: Pen, _ input: NetworkReportInput) {
        let box = CGRect(x: contentLeft, y: contentBottom + 4, width: 240, height: 76)
        pen.stroke(rect: box, color: Ink.faint, width: 0.6)
        pen.text("LEGEND", at: CGPoint(x: box.minX + 7, y: box.minY + 12),
                 font: Type.sectionHead, color: Ink.muted, tracking: 0.9)

        var y = box.minY + 26
        for confidence: Confidence in [.observed, .inferred, .unobserved] {
            let color = Ink.confidence(confidence)
            pen.stroke(line: CGPoint(x: box.minX + 8, y: y - 2.5),
                       to: CGPoint(x: box.minX + 34, y: y - 2.5),
                       color: color, width: 1.2,
                       dash: confidence == .unobserved ? [3, 2.5] : [])
            pen.text(confidence.label, at: CGPoint(x: box.minX + 40, y: y),
                     font: Type.bodySmall, color: Ink.text)
            y += 13
        }
        pen.text("Wi-Fi links are drawn heavier than wired.",
                 at: CGPoint(x: box.minX + 8, y: y + 2),
                 font: Type.caption, color: Ink.muted)
    }

    private static func notesBlock(_ pen: Pen, _ input: NetworkReportInput) {
        let box = CGRect(x: contentLeft + 250, y: contentBottom + 4, width: 320, height: 76)
        pen.stroke(rect: box, color: Ink.faint, width: 0.6)
        pen.text("NOTES", at: CGPoint(x: box.minX + 7, y: box.minY + 12),
                 font: Type.sectionHead, color: Ink.muted, tracking: 0.9)

        let notes = input.map.notes.isEmpty
            ? ["Nothing on this sheet was probed. Every value was read from this Mac or reported by a device that was asked."]
            : input.map.notes
        var y = box.minY + 24
        for note in notes.prefix(4) {
            let used = pen.paragraph("— " + note,
                                     in: CGRect(x: box.minX + 8, y: y,
                                                width: box.width - 16, height: box.maxY - y - 4),
                                     font: Type.caption, color: Ink.muted, lineHeight: 8.4)
            y += used + 3
            if y > box.maxY - 8 { break }
        }
    }
}
