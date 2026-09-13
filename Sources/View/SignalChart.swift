import SwiftUI

/// Live plot of signal strength over time.
///
/// The trace is drawn in the colour of whichever access point was serving the
/// link at that moment, so a roam shows up as a colour change rather than
/// something you have to read out of a log.
struct SignalChart: View {
    var samples: [WiFiSample]
    var roamEvents: [RoamEvent]
    var waypoints: [Waypoint] = []
    var registry: APRegistry
    var window: TimeInterval?
    var referenceDate: Date
    var showNoise: Bool
    var showRate: Bool
    /// Poll cadence, used to tell a real sampling gap from normal jitter.
    var sampleInterval: Double = 1.0
    var scale: ChartScale = .full

    @State private var hoverPoint: CGPoint?

    private let gutter: CGFloat = 42      // y-axis labels
    private let footer: CGFloat = 22      // x-axis labels
    private let topPad: CGFloat = 14

    /// Maps readings onto the plot, built once per redraw.
    ///
    /// The vertical range used to be recomputed inside every coordinate lookup
    /// by scanning every sample, and a lookup is made for every point drawn, so
    /// each redraw was quadratic in the length of the history. An hour at four
    /// readings a second made that hundreds of millions of steps per frame.
    private struct Mapping {
        let plot: CGRect
        let range: ClosedRange<Double>
        let start: Date
        let span: TimeInterval

        func x(_ t: Date) -> CGFloat {
            guard span > 0 else { return plot.minX }
            return plot.minX + plot.width * CGFloat(t.timeIntervalSince(start) / span)
        }

        func y(_ dbm: Double) -> CGFloat {
            let f = (dbm - range.lowerBound) / (range.upperBound - range.lowerBound)
            return plot.maxY - plot.height * CGFloat(f)
        }
    }

    private func mapping(in size: CGSize) -> Mapping {
        let plot = CGRect(
            x: gutter, y: topPad,
            width: Swift.max(1, size.width - gutter - 8),
            height: Swift.max(1, size.height - topPad - footer)
        )
        let range = scale.verticalRange(
            signal: samples.map(\.rssi),
            noise: showNoise ? samples.compactMap(\.validNoise) : [])
        let (start, end) = timeRange
        return Mapping(plot: plot, range: range, start: start,
                       span: end.timeIntervalSince(start))
    }

    private var timeRange: (start: Date, end: Date) {
        let end = referenceDate
        if let window { return (end.addingTimeInterval(-window), end) }
        let start = samples.first?.time ?? end.addingTimeInterval(-60)
        return (start, Swift.max(end, start.addingTimeInterval(10)))
    }

    var body: some View {
        GeometryReader { geo in
            let m = mapping(in: geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    drawQualityBands(ctx, m)
                    drawGrid(ctx, m)
                    drawGaps(ctx, m)
                    drawRoamMarkers(ctx, m)
                    if showRate { drawRateTrace(ctx, m) }
                    if showNoise { drawNoiseTrace(ctx, m) }
                    drawSignalTrace(ctx, m)
                    drawWaypoints(ctx, m)
                    drawLiveDot(ctx, m)
                    drawTimeAxis(ctx, m)
                    if let h = hoverPoint { drawCrosshair(ctx, m, at: h) }
                }
                if let h = hoverPoint, let s = sample(nearestTo: h.x, m) {
                    tooltip(for: s, m)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverPoint = m.plot.contains(p) ? p : nil
                case .ended: hoverPoint = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wi-Fi signal history")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: Lookup

    private func sample(nearestTo px: CGFloat, _ m: Mapping) -> WiFiSample? {
        guard !samples.isEmpty else { return nil }
        var best: WiFiSample?
        var bestD = CGFloat.greatestFiniteMagnitude
        for s in samples {
            let sx = m.x(s.time)
            guard sx >= m.plot.minX else { continue }
            let d = abs(sx - px)
            if d < bestD { bestD = d; best = s }
        }
        return bestD < 40 ? best : nil
    }

    // MARK: Drawing

    private func drawQualityBands(_ ctx: GraphicsContext, _ m: Mapping) {
        // Thresholds from the bottom up, with the quality each band represents.
        let bands: [(Double, Double, SignalQuality)] = [
            (-.infinity, -75, .poor),
            (-75, -67, .weak),
            (-67, -60, .fair),
            (-60, -50, .good),
            (-50, .infinity, .excellent)
        ]
        for (bandLo, bandHi, q) in bands {
            // Clamped to the frame: a zoomed view shows only part of the range,
            // and an unclamped band would paint over the axis below the plot.
            let lo = Swift.max(bandLo, m.range.lowerBound)
            let hi = Swift.min(bandHi, m.range.upperBound)
            guard hi > lo else { continue }
            let top = m.y(hi), bottom = m.y(lo)
            let rect = CGRect(x: m.plot.minX, y: top, width: m.plot.width, height: bottom - top)
            ctx.fill(Path(rect), with: .color(q.color.opacity(0.07)))

            // Zoomed in, the named bands are what stop a one-decibel wiggle from
            // reading as a real change in the connection.
            if scale.isZoomed, rect.height > 16 {
                let label = Text(q.label)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(q.color.opacity(0.75))
                ctx.draw(ctx.resolve(label), at: CGPoint(x: m.plot.minX + 6, y: rect.minY + 8),
                         anchor: .leading)
            }
        }
        ctx.stroke(Path(m.plot), with: .color(.gray.opacity(0.25)), lineWidth: 1)
    }

    private func drawGrid(_ ctx: GraphicsContext, _ m: Mapping) {
        let step = ChartScale.gridStep(for: m.range.upperBound - m.range.lowerBound)
        var v = (m.range.lowerBound / step).rounded(.up) * step
        while v < m.range.upperBound {
            let yy = m.y(v)
            if yy > m.plot.minY + 0.5, yy < m.plot.maxY - 0.5 {
                var p = Path()
                p.move(to: CGPoint(x: m.plot.minX, y: yy))
                p.addLine(to: CGPoint(x: m.plot.maxX, y: yy))
                ctx.stroke(p, with: .color(.gray.opacity(0.16)), lineWidth: 0.5)
                let t = Text("\(Int(v))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                ctx.draw(ctx.resolve(t), at: CGPoint(x: m.plot.minX - 6, y: yy), anchor: .trailing)
            }
            v += step
        }
        let unit = Text("dBm").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
        ctx.draw(ctx.resolve(unit), at: CGPoint(x: m.plot.minX - 6, y: m.plot.minY - 5), anchor: .trailing)
    }

    private func drawTimeAxis(_ ctx: GraphicsContext, _ m: Mapping) {
        let span = m.span
        guard span > 0 else { return }
        let plot = m.plot
        let ticks = 5
        for i in 0...ticks {
            let t = m.start.addingTimeInterval(span * Double(i) / Double(ticks))
            let px = plot.minX + plot.width * CGFloat(i) / CGFloat(ticks)
            let label = span > 3600 ? Fmt.clockShort.string(from: t) : Fmt.clock.string(from: t)
            let txt = Text(label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            // Pin the end labels inward so the plot edge does not clip them.
            let anchor: UnitPoint = i == 0 ? .leading : (i == ticks ? .trailing : .center)
            ctx.draw(ctx.resolve(txt), at: CGPoint(x: px, y: plot.maxY + 11), anchor: anchor)
        }
    }

    /// Splits the trace into runs of consecutive samples served by one AP.
    /// True when two consecutive samples are too far apart to be continuous —
    /// the Mac slept, sampling was paused, or the app was suspended. Drawing
    /// straight through such a gap would assert data that was never measured.
    private func isGap(_ a: WiFiSample, _ b: WiFiSample) -> Bool {
        b.time.timeIntervalSince(a.time) > Swift.max(sampleInterval * 3, 5)
    }

    /// Spans with no measurements, for shading behind the trace.
    private func gaps() -> [(start: Date, end: Date)] {
        guard samples.count > 1 else { return [] }
        var out: [(start: Date, end: Date)] = []
        for i in 1..<samples.count where isGap(samples[i - 1], samples[i]) {
            out.append((start: samples[i - 1].time, end: samples[i].time))
        }
        return out
    }

    private func drawGaps(_ ctx: GraphicsContext, _ m: Mapping) {
        let plot = m.plot
        for gap in gaps() {
            let x0 = m.x(gap.start), x1 = m.x(gap.end)
            guard x1 > plot.minX, x0 < plot.maxX else { continue }
            let rect = CGRect(x: Swift.max(x0, plot.minX), y: plot.minY,
                              width: Swift.min(x1, plot.maxX) - Swift.max(x0, plot.minX),
                              height: plot.height)
            ctx.fill(Path(rect), with: .color(.gray.opacity(0.16)))
            if rect.width > 34 {
                let t = Text("no data").font(.system(size: 8.5)).foregroundStyle(.secondary)
                ctx.draw(ctx.resolve(t), at: CGPoint(x: rect.midX, y: plot.minY + 9), anchor: .center)
            }
        }
    }

    private func segments() -> [(key: APKey, points: [WiFiSample])] {
        var out: [(key: APKey, points: [WiFiSample])] = []
        for s in samples {
            // Append through the subscript so the run grows in place; copying the
            // tuple out and back made this quadratic in the length of a run.
            let continuous = out.last?.points.last.map { !isGap($0, s) } ?? false
            if !out.isEmpty, out[out.count - 1].key == s.apKey, continuous {
                out[out.count - 1].points.append(s)
            } else {
                // Join AP changes to the previous run. Do not join across a gap.
                var seed: [WiFiSample] = []
                if continuous, let prev = out.last?.points.last { seed.append(prev) }
                seed.append(s)
                out.append((key: s.apKey, points: seed))
            }
        }
        return out
    }

    /// A smooth path through the points. The curve itself is worked out by
    /// SmoothCurve, which never overshoots a reading.
    private func smoothPath(through pts: [CGPoint], startingAt start: CGPoint? = nil) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        if let start {
            path.move(to: start)
            path.addLine(to: first)
        } else {
            path.move(to: first)
        }
        for (i, controls) in SmoothCurve.controlPoints(through: pts).enumerated() {
            path.addCurve(to: pts[i + 1], control1: controls.0, control2: controls.1)
        }
        return path
    }

    /// Thins a dense run to at most two points per pixel column, keeping the
    /// highest and the lowest reading in each column, so no peak or dip is lost.
    ///
    /// An hour at four readings a second is 14,400 points on a plot a few
    /// hundred pixels wide. Drawing them all costs far more than it shows: each
    /// column can only display the range of the readings that land in it, and
    /// that range is exactly what the two kept points carry.
    private func thinned(_ pts: [CGPoint], width: CGFloat) -> [CGPoint] {
        let limit = Int(width.rounded(.up)) * 2
        guard limit > 0, pts.count > limit else { return pts }
        var out: [CGPoint] = []
        out.reserveCapacity(limit + 2)
        var column = Int(pts[0].x.rounded(.down))
        var top = pts[0], bottom = pts[0]
        func flush() {
            // Keep the two in the order they were measured.
            let pair = top.x <= bottom.x ? [top, bottom] : [bottom, top]
            out.append(pair[0])
            if pair[1] != pair[0] { out.append(pair[1]) }
        }
        for p in pts.dropFirst() {
            let c = Int(p.x.rounded(.down))
            if c != column {
                flush()
                column = c
                top = p
                bottom = p
                continue
            }
            if p.y < top.y { top = p }
            if p.y > bottom.y { bottom = p }
        }
        flush()
        return out
    }

    private func drawSignalTrace(_ ctx: GraphicsContext, _ m: Mapping) {
        guard samples.count > 0 else { return }
        let plot = m.plot
        for seg in segments() {
            guard seg.points.count > 0 else { continue }
            let color = registry.color(for: seg.key)
            let pts = thinned(seg.points.map { CGPoint(x: m.x($0.time), y: m.y(Double($0.rssi))) },
                              width: plot.width)

            // Clipped to the plot: while the chart scrolls, the oldest reading
            // slides out past the left edge a little at a time instead of
            // vanishing in one step, and it must not paint over the axis.
            var clipped = ctx
            clipped.clip(to: Path(plot))

            // Soft fill beneath the run.
            var fill = smoothPath(through: pts,
                                  startingAt: CGPoint(x: pts[0].x, y: plot.maxY))
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: plot.maxY))
            fill.closeSubpath()
            clipped.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.30), color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: plot.minY),
                endPoint: CGPoint(x: 0, y: plot.maxY)))

            clipped.stroke(smoothPath(through: pts), with: .color(color),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawNoiseTrace(_ ctx: GraphicsContext, _ m: Mapping) {
        // Split on gaps and on samples the driver gave no noise floor for, so
        // the dashed line never spans a stretch that was not measured.
        var runs: [[(Date, Int)]] = []
        var previous: WiFiSample?
        for s in samples {
            defer { previous = s }
            guard let noise = s.validNoise else { continue }
            let continuous = previous.map { !isGap($0, s) } ?? false
            if continuous, !runs.isEmpty, previous?.validNoise != nil {
                runs[runs.count - 1].append((s.time, noise))
            } else {
                runs.append([(s.time, noise)])
            }
        }
        // A zoomed view frames the signal, not the noise, so the noise line is
        // clipped to the plot rather than drawn across the axis labels.
        var clipped = ctx
        clipped.clip(to: Path(m.plot))
        for run in runs where run.count > 1 {
            let p = smoothPath(through: thinned(run.map { CGPoint(x: m.x($0.0), y: m.y(Double($0.1))) },
                                                width: m.plot.width))
            clipped.stroke(p, with: .color(.secondary.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // Say so when the whole noise floor is off the bottom, rather than
        // letting the overlay silently vanish.
        if scale.isZoomed, let noise = samples.last?.validNoise,
           Double(noise) < m.range.lowerBound {
            let note = Text("Noise \(noise) dBm, below this scale")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
            ctx.draw(ctx.resolve(note), at: CGPoint(x: m.plot.maxX, y: m.plot.minY - 6),
                     anchor: .trailing)
        }
    }

    /// TX rate on its own implicit scale, for spotting rate collapse.
    private func drawRateTrace(_ ctx: GraphicsContext, _ m: Mapping) {
        let maxRate = Swift.max(samples.map(\.txRate).max() ?? 1, 1)
        guard samples.count > 1 else { return }
        let plot = m.plot
        var clipped = ctx
        clipped.clip(to: Path(plot))
        var p = Path()
        p.addLines(samples.map {
            CGPoint(x: m.x($0.time),
                    y: plot.maxY - plot.height * CGFloat($0.txRate / maxRate) * 0.92)
        })
        clipped.stroke(p, with: .color(.purple.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [5, 2]))
    }

    private func drawRoamMarkers(_ ctx: GraphicsContext, _ m: Mapping) {
        let plot = m.plot
        let end = m.start.addingTimeInterval(m.span)
        for ev in roamEvents where ev.time >= m.start && ev.time <= end {
            guard ev.reason.countsAsConnectionChange else { continue }
            let px = m.x(ev.time)
            var p = Path()
            p.move(to: CGPoint(x: px, y: plot.minY))
            p.addLine(to: CGPoint(x: px, y: plot.maxY))
            let c = registry.color(for: ev.toKey)
            ctx.stroke(p, with: .color(c.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            let dot = Path(ellipseIn: CGRect(x: px - 3.5, y: plot.minY - 7, width: 7, height: 7))
            ctx.fill(dot, with: .color(c))
        }
    }

    /// Places the operator marked, pinned along the bottom of the plot so they
    /// read as annotations on the trace rather than competing with it.
    private func drawWaypoints(_ ctx: GraphicsContext, _ m: Mapping) {
        let plot = m.plot
        let end = m.start.addingTimeInterval(m.span)
        var lastLabelEnd: CGFloat = -.greatestFiniteMagnitude
        for w in waypoints where w.time >= m.start && w.time <= end {
            let px = m.x(w.time)
            guard px >= plot.minX, px <= plot.maxX else { continue }

            var line = Path()
            line.move(to: CGPoint(x: px, y: plot.minY))
            line.addLine(to: CGPoint(x: px, y: plot.maxY))
            ctx.stroke(line, with: .color(.blue.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            var pin = Path()
            pin.move(to: CGPoint(x: px, y: plot.maxY - 7))
            pin.addLine(to: CGPoint(x: px - 4, y: plot.maxY - 1))
            pin.addLine(to: CGPoint(x: px + 4, y: plot.maxY - 1))
            pin.closeSubpath()
            ctx.fill(pin, with: .color(.blue))

            // Skip labels that would collide with the previous one.
            let text = Text(w.label).font(.system(size: 9, weight: .medium)).foregroundStyle(.blue)
            let resolved = ctx.resolve(text)
            let width = resolved.measure(in: CGSize(width: 120, height: 20)).width
            let left = px - width / 2
            if left > lastLabelEnd + 6, left > plot.minX, px + width / 2 < plot.maxX {
                ctx.draw(resolved, at: CGPoint(x: px, y: plot.maxY - 14), anchor: .center)
                lastLabelEnd = left + width
            }
        }
    }

    private func drawLiveDot(_ ctx: GraphicsContext, _ m: Mapping) {
        guard let last = samples.last else { return }
        let p = CGPoint(x: m.x(last.time), y: m.y(Double(last.rssi)))
        guard p.x >= m.plot.minX, p.x <= m.plot.maxX else { return }
        let c = registry.color(for: last.apKey)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(c.opacity(0.22)))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(c))
    }

    private func drawCrosshair(_ ctx: GraphicsContext, _ m: Mapping, at point: CGPoint) {
        guard let s = sample(nearestTo: point.x, m) else { return }
        let plot = m.plot
        let px = m.x(s.time)
        var v = Path()
        v.move(to: CGPoint(x: px, y: plot.minY))
        v.addLine(to: CGPoint(x: px, y: plot.maxY))
        ctx.stroke(v, with: .color(.primary.opacity(0.28)), lineWidth: 1)
        let py = m.y(Double(s.rssi))
        ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: py - 4, width: 8, height: 8)),
                 with: .color(registry.color(for: s.apKey)))
        ctx.stroke(Path(ellipseIn: CGRect(x: px - 4, y: py - 4, width: 8, height: 8)),
                   with: .color(.white.opacity(0.9)), lineWidth: 1.5)
    }

    @ViewBuilder
    private func tooltip(for s: WiFiSample, _ m: Mapping) -> some View {
        let plot = m.plot
        let px = m.x(s.time)
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
