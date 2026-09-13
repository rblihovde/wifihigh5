import SwiftUI

/// Live plot of signal strength over time.
///
/// The trace is drawn in the colour of whichever access point was serving the
/// link at that moment, so a roam shows up as a colour change rather than
/// something you have to read out of a log.
///
/// It is built in two layers. The frame, meaning the quality bands, the
/// gridlines and the signal axis, does not move. The content, meaning the
/// trace, its markers and the time axis, is drawn once per reading and then
/// slid left as time passes. Scrolling therefore costs a change of position
/// per frame, not a redraw; redrawing the whole chart thirty times a second
/// took half a core.
struct SignalChart: View {
    var samples: [WiFiSample]
    var roamEvents: [RoamEvent]
    var waypoints: [Waypoint] = []
    var registry: APRegistry
    var window: TimeInterval?
    /// The moment the content is drawn for. While the chart glides, the content
    /// is slid from here towards the present.
    var referenceDate: Date
    var showNoise: Bool
    var showRate: Bool
    /// Poll cadence, used to tell a real sampling gap from normal jitter.
    var sampleInterval: Double = 1.0
    var scale: ChartScale = .full
    /// Glide between readings instead of stepping once per reading.
    var animates: Bool = false
    /// The colour index of each access point in view, so a recolour redraws.
    var colorVersion: [Int] = []

    @State private var hovered: WiFiSample?

    fileprivate static let gutter: CGFloat = 42      // y-axis labels
    fileprivate static let footer: CGFloat = 22      // x-axis labels
    fileprivate static let topPad: CGFloat = 14

    private var timeRange: (start: Date, end: Date) {
        let end = referenceDate
        if let window { return (end.addingTimeInterval(-window), end) }
        let start = samples.first?.time ?? end.addingTimeInterval(-60)
        return (start, Swift.max(end, start.addingTimeInterval(10)))
    }

    private func mapping(in size: CGSize) -> ChartMapping {
        let plot = CGRect(
            x: Self.gutter, y: Self.topPad,
            width: Swift.max(1, size.width - Self.gutter - 8),
            height: Swift.max(1, size.height - Self.topPad - Self.footer))
        let range = scale.verticalRange(
            signal: samples.map(\.rssi),
            noise: showNoise ? samples.compactMap(\.validNoise) : [])
        let (start, end) = timeRange
        return ChartMapping(plot: plot, range: range, start: start,
                            span: end.timeIntervalSince(start))
    }

    /// How often to move the content: once per point of travel, and never
    /// more often. A one-minute window travels about twelve points a second, a
    /// five-minute window about two. Half-point steps looked no smoother and
    /// cost twice the frames; each frame carries a fixed cost in SwiftUI that
    /// no amount of caching the drawing removes.
    private func frameInterval(_ m: ChartMapping) -> Double {
        let speed = Double(m.pointsPerSecond)
        guard speed > 0 else { return 1 }
        return Swift.max(1.0 / 60, 1 / speed)
    }

    private func drift(at date: Date, _ m: ChartMapping) -> CGFloat {
        guard animates else { return 0 }
        return CGFloat(Swift.max(0, date.timeIntervalSince(referenceDate))) * m.pointsPerSecond
    }

    /// Zoomed in, the noise floor usually sits far below the frame. Saying so
    /// beats letting the overlay silently vanish.
    private func noiseNote(_ m: ChartMapping) -> String? {
        guard showNoise, scale.isZoomed, let noise = samples.last?.validNoise,
              Double(noise) < m.range.lowerBound else { return nil }
        return "Noise \(noise) dBm, below this scale"
    }

    private var signature: ContentSignature {
        ContentSignature(
            count: samples.count,
            first: samples.first?.id,
            last: samples.last?.id,
            roams: roamEvents.count,
            lastRoam: roamEvents.last?.id,
            waypoints: waypoints.map { "\($0.id)|\($0.label)" },
            showNoise: showNoise,
            showRate: showRate,
            sampleInterval: sampleInterval,
            colors: colorVersion)
    }

    var body: some View {
        GeometryReader { geo in
            let m = mapping(in: geo.size)
            let content = ChartContent(
                mapping: m, samples: samples, roamEvents: roamEvents,
                waypoints: waypoints, registry: registry, showNoise: showNoise,
                showRate: showRate, sampleInterval: sampleInterval, signature: signature)

            ZStack(alignment: .topLeading) {
                ChartFrame(mapping: m, scale: scale, noiseNote: noiseNote(m))
                    .equatable()

                // Only the offset changes between readings. The content is
                // equatable, so SwiftUI keeps the drawing it already has. The
                // animation schedule keeps the steps in time with the display.
                TimelineView(.animation(minimumInterval: frameInterval(m), paused: !animates)) { context in
                    ZStack(alignment: .topLeading) {
                        content.equatable()
                        if let hovered {
                            HoverMarker(sample: hovered, mapping: m, registry: registry)
                                .equatable()
                        }
                    }
                    .offset(x: -drift(at: context.date, m))
                }
                .clipShape(ColumnClip(minX: m.plot.minX, maxX: m.plot.maxX + 7))
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hovered = m.plot.contains(p)
                        ? sample(nearestTo: p.x + drift(at: Date(), m), m)
                        : nil
                case .ended:
                    hovered = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wi-Fi signal history")
        .accessibilityValue(accessibilitySummary)
    }

    private func sample(nearestTo x: CGFloat, _ m: ChartMapping) -> WiFiSample? {
        var best: WiFiSample?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for s in samples {
            let d = abs(m.x(s.time) - x)
            if d < bestDistance { bestDistance = d; best = s }
        }
        return bestDistance < 40 ? best : nil
    }

    private var accessibilitySummary: String {
        guard let last = samples.last else { return "No samples collected" }
        let values = samples.map(\.rssi)
        let low = values.min() ?? last.rssi
        let high = values.max() ?? last.rssi
        return "Current \(last.rssi) dBm, range \(low) to \(high) dBm, \(samples.count) samples"
    }
}

// MARK: - Mapping

/// Maps readings onto the plot, built once per reading.
///
/// The vertical range used to be recomputed inside every coordinate lookup by
/// scanning every sample, and a lookup is made for every point drawn, so each
/// redraw was quadratic in the length of the history.
private struct ChartMapping: Equatable {
    let plot: CGRect
    let range: ClosedRange<Double>
    let start: Date
    let span: TimeInterval

    var pointsPerSecond: CGFloat { span > 0 ? plot.width / CGFloat(span) : 0 }

    func x(_ t: Date) -> CGFloat {
        guard span > 0 else { return plot.minX }
        return plot.minX + plot.width * CGFloat(t.timeIntervalSince(start) / span)
    }

    func y(_ dbm: Double) -> CGFloat {
        let f = (dbm - range.lowerBound) / (range.upperBound - range.lowerBound)
        return plot.maxY - plot.height * CGFloat(f)
    }
}

/// What the content depends on, cheap to compare. Comparing the readings
/// themselves would cost as much as drawing them.
private struct ContentSignature: Equatable {
    let count: Int
    let first: UUID?
    let last: UUID?
    let roams: Int
    let lastRoam: UUID?
    let waypoints: [String]
    let showNoise: Bool
    let showRate: Bool
    let sampleInterval: Double
    let colors: [Int]
}

/// Clips the sliding content to the plot's width while leaving room above and
/// below it for the connection markers and the time labels.
private struct ColumnClip: Shape {
    var minX: CGFloat
    var maxX: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: minX, y: rect.minY, width: maxX - minX, height: rect.height))
    }
}

// MARK: - Frame

/// The part that stays still: quality bands, signal gridlines and their axis.
private struct ChartFrame: View, Equatable {
    let mapping: ChartMapping
    let scale: ChartScale
    let noiseNote: String?

    var body: some View {
        Canvas { ctx, _ in
            drawQualityBands(ctx)
            drawGrid(ctx)
            if let noiseNote {
                let note = Text(noiseNote).font(.system(size: 8.5)).foregroundStyle(.secondary)
                ctx.draw(ctx.resolve(note),
                         at: CGPoint(x: mapping.plot.maxX, y: mapping.plot.minY - 6),
                         anchor: .trailing)
            }
        }
    }

    private func drawQualityBands(_ ctx: GraphicsContext) {
        let m = mapping
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

    private func drawGrid(_ ctx: GraphicsContext) {
        let m = mapping
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
}

// MARK: - Content

/// The part that moves: the trace, the markers on it, and the time axis.
private struct ChartContent: View, Equatable {
    let mapping: ChartMapping
    let samples: [WiFiSample]
    let roamEvents: [RoamEvent]
    let waypoints: [Waypoint]
    let registry: APRegistry
    let showNoise: Bool
    let showRate: Bool
    let sampleInterval: Double
    let signature: ContentSignature

    static func == (a: ChartContent, b: ChartContent) -> Bool {
        a.mapping == b.mapping && a.signature == b.signature
    }

    var body: some View {
        Canvas { ctx, _ in
            let ticks = timeTicks()
            drawTimeGrid(ctx, ticks)
            drawGaps(ctx)
            drawRoamMarkers(ctx)
            if showRate { drawRateTrace(ctx) }
            if showNoise { drawNoiseTrace(ctx) }
            drawSignalTrace(ctx)
            drawWaypoints(ctx)
            drawLiveDot(ctx)
            drawTimeAxis(ctx, ticks)
        }
    }

    // MARK: Time axis

    /// Ticks on round times, so each label stays attached to its moment and
    /// slides with the trace. Ticks at fixed fractions of the width, as before,
    /// would jump back every time a reading arrived.
    private func timeTicks() -> (dates: [Date], seconds: Bool) {
        let m = mapping
        guard m.span > 0 else { return ([], false) }
        let steps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900,
                                     1_800, 3_600, 7_200, 10_800, 21_600, 43_200, 86_400]
        // Roughly one label per 110 points, so labels never collide.
        let target = Double(Swift.max(2, Int(m.plot.width / 110)))
        let step = steps.first { m.span / $0 <= target } ?? 86_400
        let midnight = Calendar.current.startOfDay(for: m.start)
        let first = (m.start.timeIntervalSince(midnight) / step).rounded(.up) * step
        // One step past the right edge, so the next label slides in rather
        // than appearing.
        let end = m.start.addingTimeInterval(m.span + step)
        var dates: [Date] = []
        var t = midnight.addingTimeInterval(first)
        while t <= end {
            dates.append(t)
            t = t.addingTimeInterval(step)
        }
        return (dates, step < 60)
    }

    private func drawTimeGrid(_ ctx: GraphicsContext, _ ticks: (dates: [Date], seconds: Bool)) {
        let m = mapping
        var p = Path()
        for t in ticks.dates {
            let px = m.x(t)
            p.move(to: CGPoint(x: px, y: m.plot.minY))
            p.addLine(to: CGPoint(x: px, y: m.plot.maxY))
        }
        ctx.stroke(p, with: .color(.gray.opacity(0.08)), lineWidth: 0.5)
    }

    private func drawTimeAxis(_ ctx: GraphicsContext, _ ticks: (dates: [Date], seconds: Bool)) {
        let m = mapping
        let format = ticks.seconds ? Fmt.clock : Fmt.clockShort
        for t in ticks.dates {
            let txt = Text(format.string(from: t))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            ctx.draw(ctx.resolve(txt), at: CGPoint(x: m.x(t), y: m.plot.maxY + 11), anchor: .center)
        }
    }

    // MARK: Runs and gaps

    /// True when two consecutive samples are too far apart to be continuous:
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

    private func drawGaps(_ ctx: GraphicsContext) {
        let m = mapping
        for gap in gaps() {
            let x0 = m.x(gap.start), x1 = m.x(gap.end)
            let rect = CGRect(x: x0, y: m.plot.minY, width: x1 - x0, height: m.plot.height)
            ctx.fill(Path(rect), with: .color(.gray.opacity(0.16)))
            if rect.width > 34 {
                let t = Text("no data").font(.system(size: 8.5)).foregroundStyle(.secondary)
                ctx.draw(ctx.resolve(t), at: CGPoint(x: rect.midX, y: m.plot.minY + 9), anchor: .center)
            }
        }
    }

    /// Splits the trace into runs of consecutive samples served by one AP.
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

    // MARK: Curves

    /// Thins a dense run to at most two points per pixel column, keeping the
    /// highest and the lowest reading in each column, so no peak or dip is lost.
    ///
    /// An hour at four readings a second is 14,400 points on a plot a few
    /// hundred pixels wide. Each column can only show the range of the readings
    /// that land in it, and that range is exactly what the two kept points carry.
    private func thinned(_ pts: [CGPoint]) -> [CGPoint] {
        let limit = Int(mapping.plot.width.rounded(.up)) * 2
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

    // MARK: Traces

    private func drawSignalTrace(_ ctx: GraphicsContext) {
        let m = mapping
        for seg in segments() {
            guard !seg.points.isEmpty else { continue }
            let color = registry.color(for: seg.key)
            let pts = thinned(seg.points.map { CGPoint(x: m.x($0.time), y: m.y(Double($0.rssi))) })

            // Soft fill beneath the run.
            var fill = smoothPath(through: pts, startingAt: CGPoint(x: pts[0].x, y: m.plot.maxY))
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: m.plot.maxY))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.30), color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: m.plot.minY),
                endPoint: CGPoint(x: 0, y: m.plot.maxY)))

            ctx.stroke(smoothPath(through: pts), with: .color(color),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawNoiseTrace(_ ctx: GraphicsContext) {
        let m = mapping
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
        // clipped to the plot's height rather than drawn across the time axis.
        // The width is left open: the content slides, and the outer clip
        // already holds it to the plot.
        var clipped = ctx
        clipped.clip(to: Path(CGRect(x: -100_000, y: m.plot.minY, width: 200_000, height: m.plot.height)))
        for run in runs where run.count > 1 {
            let p = smoothPath(through: thinned(run.map { CGPoint(x: m.x($0.0), y: m.y(Double($0.1))) }))
            clipped.stroke(p, with: .color(.secondary.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    /// Transmit rate on its own implicit scale, for spotting a rate collapse.
    /// It stays straight: rates step between fixed values, and a curve would
    /// imply rates in between.
    private func drawRateTrace(_ ctx: GraphicsContext) {
        let m = mapping
        guard samples.count > 1 else { return }
        let maxRate = Swift.max(samples.map(\.txRate).max() ?? 1, 1)
        var p = Path()
        p.addLines(samples.map {
            CGPoint(x: m.x($0.time),
                    y: m.plot.maxY - m.plot.height * CGFloat($0.txRate / maxRate) * 0.92)
        })
        ctx.stroke(p, with: .color(.purple.opacity(0.5)),
                   style: StrokeStyle(lineWidth: 1.2, dash: [5, 2]))
    }

    // MARK: Markers

    private func drawRoamMarkers(_ ctx: GraphicsContext) {
        let m = mapping
        for ev in roamEvents where ev.reason.countsAsConnectionChange {
            let px = m.x(ev.time)
            guard px >= m.plot.minX - 10, px <= m.plot.maxX + 20 else { continue }
            var p = Path()
            p.move(to: CGPoint(x: px, y: m.plot.minY))
            p.addLine(to: CGPoint(x: px, y: m.plot.maxY))
            let c = registry.color(for: ev.toKey)
            ctx.stroke(p, with: .color(c.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            let dot = Path(ellipseIn: CGRect(x: px - 3.5, y: m.plot.minY - 7, width: 7, height: 7))
            ctx.fill(dot, with: .color(c))
        }
    }

    /// Places the operator marked, pinned along the bottom of the plot so they
    /// read as annotations on the trace rather than competing with it.
    private func drawWaypoints(_ ctx: GraphicsContext) {
        let m = mapping
        var lastLabelEnd: CGFloat = -.greatestFiniteMagnitude
        for w in waypoints {
            let px = m.x(w.time)
            guard px >= m.plot.minX - 10, px <= m.plot.maxX + 20 else { continue }

            var line = Path()
            line.move(to: CGPoint(x: px, y: m.plot.minY))
            line.addLine(to: CGPoint(x: px, y: m.plot.maxY))
            ctx.stroke(line, with: .color(.blue.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            var pin = Path()
            pin.move(to: CGPoint(x: px, y: m.plot.maxY - 7))
            pin.addLine(to: CGPoint(x: px - 4, y: m.plot.maxY - 1))
            pin.addLine(to: CGPoint(x: px + 4, y: m.plot.maxY - 1))
            pin.closeSubpath()
            ctx.fill(pin, with: .color(.blue))

            // Skip labels that would collide with the previous one.
            let text = Text(w.label).font(.system(size: 9, weight: .medium)).foregroundStyle(.blue)
            let resolved = ctx.resolve(text)
            let width = resolved.measure(in: CGSize(width: 120, height: 20)).width
            let left = px - width / 2
            if left > lastLabelEnd + 6 {
                ctx.draw(resolved, at: CGPoint(x: px, y: m.plot.maxY - 14), anchor: .center)
                lastLabelEnd = left + width
            }
        }
    }

    private func drawLiveDot(_ ctx: GraphicsContext) {
        let m = mapping
        guard let last = samples.last else { return }
        let p = CGPoint(x: m.x(last.time), y: m.y(Double(last.rssi)))
        let c = registry.color(for: last.apKey)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(c.opacity(0.22)))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(c))
    }
}

// MARK: - Hover

/// Crosshair and readout for the reading under the pointer. It sits in the
/// sliding layer, so it stays on its reading while the chart moves.
private struct HoverMarker: View, Equatable {
    let sample: WiFiSample
    let mapping: ChartMapping
    let registry: APRegistry

    static func == (a: HoverMarker, b: HoverMarker) -> Bool {
        a.sample.id == b.sample.id && a.mapping == b.mapping
    }

    var body: some View {
        let m = mapping
        let px = m.x(sample.time)
        let py = m.y(Double(sample.rssi))
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                var v = Path()
                v.move(to: CGPoint(x: px, y: m.plot.minY))
                v.addLine(to: CGPoint(x: px, y: m.plot.maxY))
                ctx.stroke(v, with: .color(.primary.opacity(0.28)), lineWidth: 1)
                let dot = Path(ellipseIn: CGRect(x: px - 4, y: py - 4, width: 8, height: 8))
                ctx.fill(dot, with: .color(registry.color(for: sample.apKey)))
                ctx.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }
            tooltip(px: px)
        }
        .allowsHitTesting(false)
    }

    private func tooltip(px: CGFloat) -> some View {
        let s = sample
        let name = registry.displayName(for: s.apKey, fallbackChannel: s.channel, fallbackBand: s.bandRaw)
        return VStack(alignment: .leading, spacing: 3) {
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
        .offset(x: Swift.min(px + 12, mapping.plot.maxX - 160), y: mapping.plot.minY + 6)
    }

    private func tipRow(_ l: String, _ v: String, _ tint: Color) -> some View {
        HStack {
            Text(l).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(v).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(tint)
        }
    }
}
