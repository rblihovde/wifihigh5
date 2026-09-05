import SwiftUI

/// Line-art hardware symbols, drawn as vectors so they stay sharp at any zoom
/// and read like a schematic rather than clip art.
///
/// Each glyph is authored in a unit square and scaled to the rect it is given,
/// so one definition serves the map, the node inspector and the exported SVG.
enum DeviceGlyph {

    struct Drawing {
        /// Heavier strokes: the outline of the chassis.
        var outline = Path()
        /// Lighter strokes: ports, vents, detail lines.
        var detail = Path()
        /// Filled accents: status lamps, radio waves.
        var accent = Path()
    }

    static func draw(_ kind: NodeKind, in r: CGRect) -> Drawing {
        switch kind {
        case .internet:     return cloud(r)
        case .router:       return router(r)
        case .accessPoint:  return accessPoint(r)
        case .switchFabric: return fabric(r)
        case .thisMac:      return laptop(r)
        case .neighbours:   return devices(r)
        }
    }

    // Helpers mapping unit coordinates onto the target rect.
    private static func pt(_ r: CGRect, _ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y)
    }

    private static func rect(_ r: CGRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: r.minX + r.width * x, y: r.minY + r.height * y,
               width: r.width * w, height: r.height * h)
    }

    // MARK: Glyphs

    private static func cloud(_ r: CGRect) -> Drawing {
        var d = Drawing()
        var p = Path()
        p.addEllipse(in: rect(r, 0.06, 0.42, 0.36, 0.40))
        p.addEllipse(in: rect(r, 0.26, 0.20, 0.44, 0.48))
        p.addEllipse(in: rect(r, 0.56, 0.38, 0.38, 0.42))
        p.addRect(rect(r, 0.16, 0.58, 0.68, 0.22))
        d.outline = p
        // Meridians, so it reads as "the wider network" rather than weather.
        var det = Path()
        det.move(to: pt(r, 0.30, 0.50)); det.addLine(to: pt(r, 0.72, 0.50))
        det.move(to: pt(r, 0.34, 0.64)); det.addLine(to: pt(r, 0.68, 0.64))
        d.detail = det
        return d
    }

    private static func router(_ r: CGRect) -> Drawing {
        var d = Drawing()
        var p = Path()
        p.addRoundedRect(in: rect(r, 0.08, 0.44, 0.84, 0.34), cornerSize: CGSize(width: r.width * 0.04, height: r.width * 0.04))
        d.outline = p

        var det = Path()
        // Antennas.
        det.move(to: pt(r, 0.26, 0.44)); det.addLine(to: pt(r, 0.16, 0.16))
        det.move(to: pt(r, 0.74, 0.44)); det.addLine(to: pt(r, 0.84, 0.16))
        // Port row along the front face.
        for i in 0..<5 {
            let x = 0.18 + Double(i) * 0.145
            det.addRect(rect(r, x, 0.62, 0.085, 0.075))
        }
        d.detail = det

        var acc = Path()
        acc.addEllipse(in: rect(r, 0.16, 0.50, 0.06, 0.06))
        acc.addEllipse(in: rect(r, 0.26, 0.50, 0.06, 0.06))
        d.accent = acc
        return d
    }

    private static func accessPoint(_ r: CGRect) -> Drawing {
        var d = Drawing()
        var p = Path()
        // Ceiling-mounted disc seen edge-on.
        p.addRoundedRect(in: rect(r, 0.18, 0.56, 0.64, 0.20),
                         cornerSize: CGSize(width: r.width * 0.09, height: r.width * 0.09))
        p.addRect(rect(r, 0.46, 0.76, 0.08, 0.10))
        d.outline = p

        var acc = Path()
        // Emission arcs above the disc.
        for (i, radius) in [0.16, 0.26, 0.36].enumerated() {
            let box = CGRect(x: r.midX - r.width * radius,
                             y: r.minY + r.height * 0.56 - r.height * radius,
                             width: r.width * radius * 2, height: r.height * radius * 2)
            var arc = Path()
            arc.addArc(center: CGPoint(x: box.midX, y: box.midY),
                       radius: box.width / 2,
                       startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            acc.addPath(arc)
            _ = i
        }
        d.accent = acc
        return d
    }

    private static func fabric(_ r: CGRect) -> Drawing {
        var d = Drawing()
        var p = Path()
        p.addRoundedRect(in: rect(r, 0.10, 0.34, 0.80, 0.40),
                         cornerSize: CGSize(width: r.width * 0.05, height: r.width * 0.05))
        d.outline = p
        var det = Path()
        // Port array, drawn faintly: something is here, we just cannot see it.
        for row in 0..<2 {
            for col in 0..<6 {
                det.addRect(rect(r, 0.17 + Double(col) * 0.115, 0.44 + Double(row) * 0.14, 0.07, 0.09))
            }
        }
        d.detail = det
        return d
    }

    private static func laptop(_ r: CGRect) -> Drawing {
        var d = Drawing()
        var p = Path()
        p.addRoundedRect(in: rect(r, 0.16, 0.26, 0.68, 0.42),
                         cornerSize: CGSize(width: r.width * 0.03, height: r.width * 0.03))
        // Base.
        p.move(to: pt(r, 0.06, 0.76))
        p.addLine(to: pt(r, 0.94, 0.76))
        p.addLine(to: pt(r, 0.88, 0.70))
        p.addLine(to: pt(r, 0.12, 0.70))
        p.closeSubpath()
        d.outline = p
        var det = Path()
        det.addRect(rect(r, 0.21, 0.31, 0.58, 0.32))
        d.detail = det
        return d
    }

    private static func devices(_ r: CGRect) -> Drawing {
        var d = Drawing()
        var p = Path()
        p.addRoundedRect(in: rect(r, 0.08, 0.30, 0.44, 0.34), cornerSize: CGSize(width: 3, height: 3))
        p.addRoundedRect(in: rect(r, 0.34, 0.46, 0.44, 0.34), cornerSize: CGSize(width: 3, height: 3))
        p.addRoundedRect(in: rect(r, 0.56, 0.24, 0.34, 0.30), cornerSize: CGSize(width: 3, height: 3))
        d.outline = p
        return d
    }
}
