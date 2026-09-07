import Foundation
import AppKit
import SwiftUI
import CoreText

/// Ink colours for a printed sheet.
///
/// These are chosen for paper rather than for a dark screen: near-black line
/// work, greys that survive a laser printer, and the same three confidence
/// colours the map uses so the sheet and the app cannot disagree.
enum Ink {
    static let text     = NSColor(white: 0.10, alpha: 1).cgColor
    static let muted    = NSColor(white: 0.42, alpha: 1).cgColor
    static let faintInk = NSColor(white: 0.60, alpha: 1).cgColor
    static let rule     = NSColor(white: 0.25, alpha: 1).cgColor
    static let faint    = NSColor(white: 0.78, alpha: 1).cgColor
    static let grid     = NSColor(white: 0.90, alpha: 1).cgColor
    static let paper    = NSColor.white.cgColor
    static let plate    = NSColor(white: 0.985, alpha: 1).cgColor

    static func confidence(_ c: Confidence) -> CGColor {
        switch c {
        case .observed:   return NSColor(red: 0.10, green: 0.42, blue: 0.72, alpha: 1).cgColor
        case .inferred:   return NSColor(red: 0.72, green: 0.48, blue: 0.05, alpha: 1).cgColor
        case .unobserved: return NSColor(white: 0.52, alpha: 1).cgColor
        }
    }
}

/// Type styles. Data is monospaced so columns line up and a MAC address cannot
/// be misread; labels are the system sans.
enum Type {
    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
    }

    static var brand: CTFont { sans(11, .bold) }
    static var sheetTitle: CTFont { sans(15, .semibold) }
    static var sectionHead: CTFont { sans(8, .semibold) }
    static var blockLabel: CTFont { sans(6, .semibold) }
    static var blockValue: CTFont { mono(8, .medium) }
    static var zone: CTFont { sans(6, .medium) }

    static var nodeTitle: CTFont { sans(9, .semibold) }
    static var nodeSub: CTFont { mono(6.5) }
    static var nodeKey: CTFont { sans(6.5) }
    static var nodeValue: CTFont { mono(6.5, .medium) }
    static var designator: CTFont { mono(6.5, .bold) }
    static var stamp: CTFont { sans(5.5, .bold) }
    static var edgeLabel: CTFont { mono(6) }

    static var tableHead: CTFont { sans(6.5, .semibold) }
    static var tableCell: CTFont { sans(7.5) }
    static var tableMono: CTFont { mono(7) }
    static var body: CTFont { sans(8) }
    static var bodySmall: CTFont { sans(7) }
    static var caption: CTFont { sans(6.5) }
}

/// A thin drawing surface over a PDF context.
///
/// Layout is written top-down, the way the on-screen map is, and converted to
/// the PDF's bottom-up space at the point of drawing. That keeps every
/// coordinate in this file consistent with the view it is reproducing.
struct Pen {
    let ctx: CGContext
    let page: CGSize

    enum Align { case left, center, right }

    private var flip: CGAffineTransform {
        CGAffineTransform(translationX: 0, y: page.height).scaledBy(x: 1, y: -1)
    }

    /// Top-down y to PDF y.
    private func up(_ y: CGFloat) -> CGFloat { page.height - y }

    // MARK: Shapes

    func stroke(rect: CGRect, color: CGColor, width: CGFloat, dash: [CGFloat] = []) {
        stroke(path: Path(rect), color: color, width: width, dash: dash)
    }

    func stroke(rounded rect: CGRect, radius: CGFloat, color: CGColor,
                width: CGFloat, dash: [CGFloat] = []) {
        stroke(path: Path(roundedRect: rect, cornerRadius: radius),
               color: color, width: width, dash: dash)
    }

    func fill(rect: CGRect, color: CGColor) {
        fill(path: Path(rect), color: color)
    }

    func fill(rounded rect: CGRect, radius: CGFloat, color: CGColor) {
        fill(path: Path(roundedRect: rect, cornerRadius: radius), color: color)
    }

    func stroke(line from: CGPoint, to: CGPoint, color: CGColor,
                width: CGFloat, dash: [CGFloat] = []) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        stroke(path: path, color: color, width: width, dash: dash)
    }

    func stroke(path: Path, color: CGColor, width: CGFloat, dash: [CGFloat] = []) {
        // The transform has to outlive the call. Taking a pointer to a
        // temporary array leaves copy(using:) reading freed memory, which drops
        // shapes at random while leaving text untouched.
        var transform = flip
        guard let cg = path.cgPath.copy(using: &transform) else { return }
        ctx.saveGState()
        ctx.addPath(cg)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if dash.isEmpty { ctx.setLineDash(phase: 0, lengths: []) }
        else { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    func fill(path: Path, color: CGColor) {
        var transform = flip
        guard let cg = path.cgPath.copy(using: &transform) else { return }
        ctx.saveGState()
        ctx.addPath(cg)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: Type

    private func attributed(_ string: String, font: CTFont,
                            color: CGColor, tracking: CGFloat) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// Draws one line. `at` is the baseline, in top-down coordinates.
    func text(_ string: String, at point: CGPoint, font: CTFont, color: CGColor,
              align: Align = .left, tracking: CGFloat = 0) {
        guard !string.isEmpty else { return }
        let line = CTLineCreateWithAttributedString(
            attributed(string, font: font, color: color, tracking: tracking))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x: CGFloat
        switch align {
        case .left:   x = point.x
        case .center: x = point.x - width / 2
        case .right:  x = point.x - width
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: up(point.y))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    func width(of string: String, font: CTFont, tracking: CGFloat = 0) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(
            attributed(string, font: font, color: Ink.text, tracking: tracking))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Shortens to fit, with an ellipsis, so a long vendor name cannot run into
    /// the next column.
    func elide(_ string: String, font: CTFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 0 else { return "" }
        guard width(of: string, font: font) > maxWidth else { return string }
        var text = string
        while !text.isEmpty && width(of: text + "…", font: font) > maxWidth {
            text.removeLast()
        }
        return text.isEmpty ? "" : text + "…"
    }

    /// Wrapped body text. Returns the height consumed.
    @discardableResult
    func paragraph(_ string: String, in rect: CGRect, font: CTFont,
                   color: CGColor, lineHeight: CGFloat) -> CGFloat {
        let words = string.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return 0 }
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if width(of: candidate, font: font) <= rect.width {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }

        var y = rect.minY
        for line in lines {
            guard y <= rect.maxY else { break }
            text(line, at: CGPoint(x: rect.minX, y: y), font: font, color: color)
            y += lineHeight
        }
        return y - rect.minY
    }
}
