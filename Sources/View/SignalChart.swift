import SwiftUI

/// Live plot of signal strength over time.
///
/// The trace is drawn in the colour of whichever access point was serving the
/// link at that moment, so a roam shows up as a colour change rather than
/// something you have to read out of a log.
struct SignalChart: View {
    var samples: [WiFiSample]
    var roamEvents: [RoamEvent]
    var registry: APRegistry
    var window: TimeInterval?
    var referenceDate: Date
    var showNoise: Bool
    var showRate: Bool

    @State private var hoverPoint: CGPoint?

    private let gutter: CGFloat = 42      // y-axis labels
    private let footer: CGFloat = 22      // x-axis labels
    private let topPad: CGFloat = 14

    // dBm range shown; widened if a sample falls outside it.
    private var yRange: ClosedRange<Double> {
        var lo = -95.0, hi = -25.0
        for s in samples {
            lo = Swift.min(lo, Double(s.rssi) - 3)
            hi = Swift.max(hi, Double(s.rssi) + 3)
            if showNoise, let noise = s.validNoise { lo = Swift.min(lo, Double(noise) - 3) }
        }
        return lo...hi
    }

    private var timeRange: (start: Date, end: Date) {
        let end = referenceDate
        if let window { return (end.addingTimeInterval(-window), end) }
        let start = samples.first?.time ?? end.addingTimeInterval(-60)
        return (start, Swift.max(end, start.addingTimeInterval(10)))
    }

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(
                x: gutter, y: topPad,
                width: Swift.max(1, geo.size.width - gutter - 8),
                height: Swift.max(1, geo.size.height - topPad - footer)
            )
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    drawQualityBands(ctx, plot)
                    drawGrid(ctx, plot)
                    drawRoamMarkers(ctx, plot)
                    if showRate { drawRateTrace(ctx, plot) }
                    if showNoise { drawNoiseTrace(ctx, plot) }
                    drawSignalTrace(ctx, plot)
                    drawLiveDot(ctx, plot)
                    drawTimeAxis(ctx, plot)
                    if let h = hoverPoint { drawCrosshair(ctx, plot, at: h) }
                }
                if let h = hoverPoint, let s = sample(nearestTo: h.x, in: plot) {
                    tooltip(for: s, plot: plot)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverPoint = plot.contains(p) ? p : nil
                case .ended: hoverPoint = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wi-Fi signal history")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: Coordinate mapping

    private func x(for t: Date, in plot: CGRect) -> CGFloat {
        let (s, e) = timeRange
        let span = e.timeIntervalSince(s)
        guard span > 0 else { return plot.minX }
        let f = t.timeIntervalSince(s) / span
        return plot.minX + plot.width * CGFloat(f)
    }

    private func y(for dbm: Double, in plot: CGRect) -> CGFloat {
        let r = yRange
        let f = (dbm - r.lowerBound) / (r.upperBound - r.lowerBound)
        return plot.maxY - plot.height * CGFloat(f)
    }

    private func sample(nearestTo px: CGFloat, in plot: CGRect) -> WiFiSample? {
        guard !samples.isEmpty else { return nil }
        var best: WiFiSample?
        var bestD = CGFloat.greatestFiniteMagnitude
        for s in samples {
            let d = abs(x(for: s.time, in: plot) - px)
            if d < bestD { bestD = d; best = s }
        }
        return bestD < 40 ? best : nil
    }

    // MARK: Drawing

    private func drawQualityBands(_ ctx: GraphicsContext, _ plot: CGRect) {
        // Bottom-to-top thresholds with the quality each band represents.
        let bands: [(Double, Double, SignalQuality)] = [
            (yRange.lowerBound, -75, .poor),
            (-75, -67, .weak),
            (-67, -60, .fair),
            (-60, -50, .good),
            (-50, yRange.upperBound, .excellent)
        ]
        for (lo, hi, q) in bands where hi > lo {
            let top = y(for: hi, in: plot), bottom = y(for: lo, in: plot)
            let rect = CGRect(x: plot.minX, y: top, width: plot.width, height: Swift.max(0, bottom - top))
            ctx.fill(Path(rect), with: .color(q.color.opacity(0.07)))
        }
        ctx.stroke(Path(plot), with: .color(.gray.opacity(0.25)), lineWidth: 1)
    }

    private func drawGrid(_ ctx: GraphicsContext, _ plot: CGRect) {
        var v = (yRange.upperBound / 10).rounded(.down) * 10
        while v > yRange.lowerBound {
            let yy = y(for: v, in: plot)
            if yy > plot.minY, yy < plot.maxY {
                var p = Path()
                p.move(to: CGPoint(x: plot.minX, y: yy))
                p.addLine(to: CGPoint(x: plot.maxX, y: yy))
                ctx.stroke(p, with: .color(.gray.opacity(0.16)), lineWidth: 0.5)
                let t = Text("\(Int(v))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                ctx.draw(ctx.resolve(t), at: CGPoint(x: plot.minX - 6, y: yy), anchor: .trailing)
            }
            v -= 10
        }
        let unit = Text("dBm").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
        ctx.draw(ctx.resolve(unit), at: CGPoint(x: plot.minX - 6, y: plot.minY - 5), anchor: .trailing)
    }

    private func drawTimeAxis(_ ctx: GraphicsContext, _ plot: CGRect) {
        let (s, e) = timeRange
        let span = e.timeIntervalSince(s)
        guard span > 0 else { return }
        let ticks = 5
        for i in 0...ticks {
            let t = s.addingTimeInterval(span * Double(i) / Double(ticks))
            let px = plot.minX + plot.width * CGFloat(i) / CGFloat(ticks)
            let label = span > 3600 ? Fmt.clockShort.string(from: t) : Fmt.clock.string(from: t)
            let txt = Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            // Pin the end labels inward so the plot edge does not clip them.
            let anchor: UnitPoint = i == 0 ? .leading : (i == ticks ? .trailing : .center)
            ctx.draw(ctx.resolve(txt), at: CGPoint(x: px, y: plot.maxY + 11), anchor: anchor)
        }
    }

    /// Splits the trace into runs of consecutive samples served by one AP.
    private func segments() -> [(key: APKey, points: [WiFiSample])] {
        var out: [(key: APKey, points: [WiFiSample])] = []
        for s in samples {
            // Append through the subscript so the run grows in place; copying the
            // tuple out and back made this quadratic in the length of a run.
            if !out.isEmpty, out[out.count - 1].key == s.apKey {
                out[out.count - 1].points.append(s)
            } else {
                // Repeat the previous sample so segments join without a gap.
                var seed: [WiFiSample] = []
                if let prev = out.last?.points.last { seed.append(prev) }
                seed.append(s)
                out.append((key: s.apKey, points: seed))
            }
        }
        return out
    }

    private func drawSignalTrace(_ ctx: GraphicsContext, _ plot: CGRect) {
        guard samples.count > 0 else { return }
        for seg in segments() {
            guard seg.points.count > 0 else { continue }
            let color = registry.color(for: seg.key)
            let pts = seg.points.map { CGPoint(x: x(for: $0.time, in: plot), y: y(for: Double($0.rssi), in: plot)) }

            // Soft fill beneath the run.
            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: plot.maxY))
            for p in pts { fill.addLine(to: p) }
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: plot.maxY))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.30), color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: plot.minY),
                endPoint: CGPoint(x: 0, y: plot.maxY)))

            var line = Path()
            line.addLines(pts)
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawNoiseTrace(_ ctx: GraphicsContext, _ plot: CGRect) {
        let noiseSamples = samples.compactMap { s -> (Date, Int)? in
            s.validNoise.map { (s.time, $0) }
        }
        guard noiseSamples.count > 1 else { return }
        var p = Path()
        p.addLines(noiseSamples.map { CGPoint(x: x(for: $0.0, in: plot), y: y(for: Double($0.1), in: plot)) })
        ctx.stroke(p, with: .color(.secondary.opacity(0.65)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    /// TX rate on its own implicit scale, for spotting rate collapse.
    private func drawRateTrace(_ ctx: GraphicsContext, _ plot: CGRect) {
        let maxRate = Swift.max(samples.map(\.txRate).max() ?? 1, 1)
        guard samples.count > 1 else { return }
        var p = Path()
        p.addLines(samples.map {
            CGPoint(x: x(for: $0.time, in: plot),
                    y: plot.maxY - plot.height * CGFloat($0.txRate / maxRate) * 0.92)
        })
        ctx.stroke(p, with: .color(.purple.opacity(0.5)),
                   style: StrokeStyle(lineWidth: 1.2, dash: [5, 2]))
    }

    private func drawRoamMarkers(_ ctx: GraphicsContext, _ plot: CGRect) {
        let (s, e) = timeRange
        for ev in roamEvents where ev.time >= s && ev.time <= e {
            guard ev.reason.countsAsConnectionChange else { continue }
            let px = x(for: ev.time, in: plot)
            var p = Path()
            p.move(to: CGPoint(x: px, y: plot.minY))
            p.addLine(to: CGPoint(x: px, y: plot.maxY))
            let c = registry.color(for: ev.toKey)
            ctx.stroke(p, with: .color(c.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            let dot = Path(ellipseIn: CGRect(x: px - 3.5, y: plot.minY - 7, width: 7, height: 7))
            ctx.fill(dot, with: .color(c))
        }
    }

    private func drawLiveDot(_ ctx: GraphicsContext, _ plot: CGRect) {
        guard let last = samples.last else { return }
        let p = CGPoint(x: x(for: last.time, in: plot), y: y(for: Double(last.rssi), in: plot))
        guard p.x >= plot.minX, p.x <= plot.maxX else { return }
        let c = registry.color(for: last.apKey)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(c.opacity(0.22)))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(c))
    }

    private func drawCrosshair(_ ctx: GraphicsContext, _ plot: CGRect, at point: CGPoint) {
        guard let s = sample(nearestTo: point.x, in: plot) else { return }
        let px = x(for: s.time, in: plot)
        var v = Path()
        v.move(to: CGPoint(x: px, y: plot.minY))
        v.addLine(to: CGPoint(x: px, y: plot.maxY))
        ctx.stroke(v, with: .color(.primary.opacity(0.28)), lineWidth: 1)
        let py = y(for: Double(s.rssi), in: plot)
        ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: py - 4, width: 8, height: 8)),
                 with: .color(registry.color(for: s.apKey)))
        ctx.stroke(Path(ellipseIn: CGRect(x: px - 4, y: py - 4, width: 8, height: 8)),
                   with: .color(.white.opacity(0.9)), lineWidth: 1.5)
    }

    @ViewBuilder
    private func tooltip(for s: WiFiSample, plot: CGRect) -> some View {
        let px = x(for: s.time, in: plot)
        let name = registry.displayName(for: s.apKey, fallbackChannel: s.channel, fallbackBand: s.bandRaw)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(registry.color(for: s.apKey)).frame(width: 8, height: 8)
                Text(name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            Text(Fmt.clock.string(from: s.time))
                .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 1)
            tipRow("Signal", "\(s.rssi) dBm", s.quality.color)
            tipRow("Noise", s.validNoise.map { "\($0) dBm" } ?? "Not reported", .secondary)
            tipRow("SNR", s.snr.map { "\($0) dB" } ?? "—", s.snrQuality?.color ?? .secondary)
            tipRow("Rate", Fmt.rate(s.txRate), .secondary)
            tipRow("Channel", "\(s.channel) · \(s.band.short)", .secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .frame(width: 156)
        // Flip to the left of the cursor near the right edge so it stays visible.
        .offset(x: Swift.min(px + 12, plot.maxX - 160), y: plot.minY + 6)
        .allowsHitTesting(false)
    }

    private func tipRow(_ l: String, _ v: String, _ tint: Color) -> some View {
        HStack {
            Text(l).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(v).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(tint)
        }
    }

    private var accessibilitySummary: String {
        guard let last = samples.last else { return "No samples collected" }
        let values = samples.map(\.rssi)
        let low = values.min() ?? last.rssi
        let high = values.max() ?? last.rssi
        return "Current \(last.rssi) dBm, range \(low) to \(high) dBm, \(samples.count) samples"
    }
}
