import SwiftUI

/// A schematic of the paths this Mac's traffic actually takes.
///
/// Drawn as vectors on a drafting lattice: connectors run orthogonally, line
/// weights stay constant on screen however far you zoom, and each node reveals
/// progressively more of what is known about it as you move closer.
struct NetworkMapView: View {
    @EnvironmentObject private var monitor: WiFiMonitor
    @EnvironmentObject private var registry: APRegistry
    @EnvironmentObject private var netInfo: NetworkInfoModel
    @EnvironmentObject private var scanner: Scanner
    @EnvironmentObject private var pinger: GatewayPinger
    @EnvironmentObject private var vendors: VendorDatabase

    @State private var zoom: CGFloat = 1.0
    @State private var committedZoom: CGFloat = 1.0
    @State private var offset = CGSize.zero
    @State private var committedOffset = CGSize.zero
    @State private var arp: [ARPEntry] = []
    @State private var selected: MapNode?
    @State private var refreshTick = 0
    @State private var lastViewportSize = CGSize(width: 900, height: 600)
    /// Until the operator pans or zooms, the drawing keeps framing itself as
    /// nodes arrive — ARP and scan results land a few seconds after launch.
    @State private var userAdjusted = false

    // Lattice geometry.
    private let nodeWidth: CGFloat = 232
    private let columnSpacing: CGFloat = 296
    private let rowSpacing: CGFloat = 268

    private var map: NetworkMap {
        _ = refreshTick
        return TopologyBuilder.build(
            sample: monitor.current, status: monitor.status,
            ip: netInfo.config, arp: arp, scan: scanner.results,
            registry: registry, pinger: pinger, vendors: vendors)
    }

    /// How much of each node is worth showing at the current magnification.
    private var detail: Detail? {
        switch zoom {
        case ..<0.55: return nil
        case ..<1.28: return .primary
        case ..<2.15: return .secondary
        default:      return .full
        }
    }

    private var detailName: String {
        switch detail {
        case .none: return "Overview"
        case .primary: return "Key facts"
        case .secondary: return "Detailed"
        case .full: return "Everything"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    canvas(geo.size)
                    if let node = selected {
                        inspector(node)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .allowsHitTesting(true)
                    }
                    legend
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(width: committedOffset.width + v.translation.width,
                                            height: committedOffset.height + v.translation.height)
                        }
                        .onEnded { _ in committedOffset = offset; userAdjusted = true }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            zoom = min(max(committedZoom * v.magnification, 0.35), 4.5)
                        }
                        .onEnded { _ in committedZoom = zoom; userAdjusted = true }
                )
                .onTapGesture { location in
                    selected = hitTest(location, in: geo.size)
                }
                .onAppear {
                    lastViewportSize = geo.size
                    fit(in: geo.size)
                }
                .onChange(of: geo.size) { _, new in
                    lastViewportSize = new
                    if !userAdjusted { fit(in: new) }
                }
                .onChange(of: map.nodes.count) { _, _ in
                    if !userAdjusted { fit(in: lastViewportSize) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: reloadARP)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            reloadARP()
            refreshTick &+= 1
        }
    }

    private func reloadARP() {
        DispatchQueue.global(qos: .utility).async {
            let entries = ARPTable.read()
            Task { @MainActor in self.arp = entries }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("SIGNAL PATH")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)

            Pill(text: detailName, tint: .blue)
                .help("Zoom in for more detail on every node and link")

            Spacer()

            if scanner.results.isEmpty {
                Button {
                    scanner.scan(currentSSID: monitor.current?.ssid,
                                 currentBSSID: monitor.current?.bssid)
                } label: {
                    Label("Find other access points", systemImage: "dot.radiowaves.up.forward")
                }
                .controlSize(.small)
                .help("Runs a scan. Unlike the rest of the app this transmits.")
            }

            Button { setZoom(zoom / 1.35) } label: { Image(systemName: "minus.magnifyingglass") }
                .controlSize(.small)
            Text(String(format: "%.0f%%", zoom * 100))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 42)
            Button { setZoom(zoom * 1.35) } label: { Image(systemName: "plus.magnifyingglass") }
                .controlSize(.small)
            Button("Fit") { fitToDefault() }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func setZoom(_ z: CGFloat) {
        userAdjusted = true
        withAnimation(.easeOut(duration: 0.18)) {
            zoom = min(max(z, 0.35), 4.5)
            committedZoom = zoom
        }
    }

    private func fitToDefault() {
        userAdjusted = false
        withAnimation(.easeOut(duration: 0.22)) { fit(in: lastViewportSize) }
    }

    /// Frames the whole drawing with a margin, the way a CAD zoom-extents does.
    private func fit(in size: CGSize) {
        let box = drawingBounds()
        guard box.width > 0, box.height > 0, size.width > 0, size.height > 0 else { return }
        let margin: CGFloat = 72
        let scale = min((size.width - margin) / box.width,
                        (size.height - margin) / box.height)
        zoom = min(max(scale, 0.35), 1.15)
        committedZoom = zoom
        let centre = CGPoint(x: box.midX, y: box.midY)
        offset = CGSize(width: -centre.x * zoom, height: -centre.y * zoom)
        committedOffset = offset
    }

    // MARK: Layout

    private func origin(for node: MapNode) -> CGPoint {
        CGPoint(x: node.column * columnSpacing, y: node.row * rowSpacing)
    }

    private func visibleFacts(_ node: MapNode) -> [Fact] {
        guard let detail else { return [] }
        return node.facts.filter { $0.detail <= detail && !$0.inspectorOnly }
    }

    private func nodeRect(_ node: MapNode) -> CGRect {
        let o = origin(for: node)
        let facts = visibleFacts(node)
        let height: CGFloat = 62 + (facts.isEmpty ? 0 : CGFloat(facts.count) * 17 + 8)
        return CGRect(x: o.x - nodeWidth / 2, y: o.y - height / 2, width: nodeWidth, height: height)
    }

    /// Model space -> view space. Pan is stored in screen units so dragging
    /// tracks the cursor exactly at any magnification.
    private func transform(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * zoom + offset.width + size.width / 2,
                y: p.y * zoom + offset.height + size.height / 2)
    }

    /// Bounding box of the whole drawing, measured at a stable detail level so
    /// that fitting does not depend on the zoom it is about to set.
    private func drawingBounds() -> CGRect {
        let nodes = map.nodes
        guard !nodes.isEmpty else { return .zero }
        var box: CGRect?
        for node in nodes {
            let o = origin(for: node)
            let count = node.facts.filter { $0.detail == .primary && !$0.inspectorOnly }.count
            let h: CGFloat = 62 + (count == 0 ? 0 : CGFloat(count) * 17 + 8)
            let r = CGRect(x: o.x - nodeWidth / 2, y: o.y - h / 2, width: nodeWidth, height: h)
            box = box.map { $0.union(r) } ?? r
        }
        return box ?? .zero
    }

    private func hitTest(_ point: CGPoint, in size: CGSize) -> MapNode? {
        for node in map.nodes {
            let r = nodeRect(node)
            let tl = transform(CGPoint(x: r.minX, y: r.minY), size)
            let screen = CGRect(x: tl.x, y: tl.y, width: r.width * zoom, height: r.height * zoom)
            if screen.contains(point) { return node }
        }
        return nil
    }

    // MARK: Canvas

    private func canvas(_ size: CGSize) -> some View {
        Canvas { ctx, canvasSize in
            drawGrid(ctx, canvasSize)
            let m = map
            for edge in m.edges { drawEdge(ctx, edge, m, canvasSize) }
            for node in m.nodes { drawNode(ctx, node, canvasSize) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Drafting lattice. The fine grid only appears once you are close enough
    /// for it to mean anything.
    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        let major = 100.0 * zoom
        let originPoint = transform(.zero, size)

        if zoom > 0.9 {
            var minor = Path()
            let step = major / 5
            var x = originPoint.x.truncatingRemainder(dividingBy: step)
            while x < size.width { minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y = originPoint.y.truncatingRemainder(dividingBy: step)
            while y < size.height { minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(minor, with: .color(.gray.opacity(0.07)), lineWidth: 0.5)
        }

        var grid = Path()
        var x = originPoint.x.truncatingRemainder(dividingBy: major)
        while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += major }
        var y = originPoint.y.truncatingRemainder(dividingBy: major)
        while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += major }
        ctx.stroke(grid, with: .color(.gray.opacity(0.13)), lineWidth: 0.5)
    }

    private func drawEdge(_ ctx: GraphicsContext, _ edge: MapEdge, _ m: NetworkMap, _ size: CGSize) {
        guard let a = m.node(edge.from), let b = m.node(edge.to) else { return }
        let ra = nodeRect(a), rb = nodeRect(b)

        // Orthogonal routing: leave the lower edge, run to the target's column,
        // then drop in — the way a schematic is drawn.
        let start = CGPoint(x: ra.midX, y: ra.maxY)
        let end = CGPoint(x: rb.midX, y: rb.minY)
        let midY = (start.y + end.y) / 2

        var path = Path()
        path.move(to: transform(start, size))
        if abs(start.x - end.x) < 0.5 {
            path.addLine(to: transform(end, size))
        } else {
            path.addLine(to: transform(CGPoint(x: start.x, y: midY), size))
            path.addLine(to: transform(CGPoint(x: end.x, y: midY), size))
            path.addLine(to: transform(end, size))
        }

        let tint = edge.confidence.tint
        let dash: [CGFloat] = edge.confidence == .observed ? [] : [5, 4]
        ctx.stroke(path, with: .color(tint.opacity(edge.confidence == .observed ? 0.9 : 0.6)),
                   style: StrokeStyle(lineWidth: edge.kind == .wireless ? 2 : 1.3,
                                      lineCap: .round, lineJoin: .round, dash: dash))

        // Terminators.
        for p in [start, end] {
            let t = transform(p, size)
            ctx.fill(Path(ellipseIn: CGRect(x: t.x - 2.5, y: t.y - 2.5, width: 5, height: 5)),
                     with: .color(tint))
        }

        guard zoom > 0.6 else { return }
        let caption = edge.caption ?? edge.kind.label
        let label = Text(caption)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(tint)
        let resolved = ctx.resolve(label)
        let measured = resolved.measure(in: CGSize(width: 240, height: 40))
        let anchor = transform(CGPoint(x: (start.x + end.x) / 2, y: midY), size)
        let plate = CGRect(x: anchor.x - measured.width / 2 - 5, y: anchor.y - measured.height / 2 - 2,
                           width: measured.width + 10, height: measured.height + 4)
        ctx.fill(Path(roundedRect: plate, cornerRadius: 3),
                 with: .color(Color(nsColor: .textBackgroundColor).opacity(0.92)))
        ctx.draw(resolved, at: anchor, anchor: .center)
    }

    private func drawNode(_ ctx: GraphicsContext, _ node: MapNode, _ size: CGSize) {
        let r = nodeRect(node)
        let tl = transform(CGPoint(x: r.minX, y: r.minY), size)
        let box = CGRect(x: tl.x, y: tl.y, width: r.width * zoom, height: r.height * zoom)
        guard box.maxX > -40, box.minX < size.width + 40,
              box.maxY > -40, box.minY < size.height + 40 else { return }

        let tint = node.accent ?? node.confidence.tint
        let isSelected = selected?.id == node.id

        // Plate.
        let plate = Path(roundedRect: box, cornerRadius: 6 * zoom)
        ctx.fill(plate, with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.97)))
        ctx.stroke(plate, with: .color(isSelected ? tint : tint.opacity(0.65)),
                   style: StrokeStyle(lineWidth: isSelected ? 2 : 1.2,
                                      dash: node.confidence == .unobserved ? [4, 3] : []))

        // Glyph.
        let glyphSide = 30 * zoom
        let glyphRect = CGRect(x: box.minX + 11 * zoom, y: box.minY + 10 * zoom,
                               width: glyphSide, height: glyphSide)
        let drawing = DeviceGlyph.draw(node.kind, in: glyphRect)
        ctx.stroke(drawing.outline, with: .color(tint), lineWidth: 1.4)
        ctx.stroke(drawing.detail, with: .color(tint.opacity(0.55)), lineWidth: 0.9)
        ctx.stroke(drawing.accent, with: .color(tint.opacity(0.85)), lineWidth: 1.2)

        // Title block.
        let textX = box.minX + (11 + 30 + 9) * zoom
        let title = ctx.resolve(Text(node.title)
            .font(.system(size: 11.5 * zoom, weight: .semibold))
            .foregroundStyle(Color.primary))
        ctx.draw(title, at: CGPoint(x: textX, y: box.minY + 17 * zoom), anchor: .leading)

        if let sub = node.subtitle {
            let subtitle = ctx.resolve(Text(sub)
                .font(.system(size: 9 * zoom, design: .monospaced))
                .foregroundStyle(Color.secondary))
            ctx.draw(subtitle, at: CGPoint(x: textX, y: box.minY + 30 * zoom), anchor: .leading)
        }

        // Confidence stamp, like a drawing revision mark.
        if node.confidence != .observed {
            let stamp = ctx.resolve(Text(node.confidence.label.uppercased())
                .font(.system(size: 7 * zoom, weight: .bold))
                .foregroundStyle(node.confidence.tint))
            ctx.draw(stamp, at: CGPoint(x: box.maxX - 8 * zoom, y: box.minY + 12 * zoom), anchor: .trailing)
        }

        // Facts, revealed by zoom.
        let facts = visibleFacts(node)
        guard !facts.isEmpty else { return }
        var y = box.minY + 62 * zoom
        var rule = Path()
        rule.move(to: CGPoint(x: box.minX + 10 * zoom, y: y - 9 * zoom))
        rule.addLine(to: CGPoint(x: box.maxX - 10 * zoom, y: y - 9 * zoom))
        ctx.stroke(rule, with: .color(.gray.opacity(0.25)), lineWidth: 0.6)

        for fact in facts {
            let key = ctx.resolve(Text(fact.label)
                .font(.system(size: 8.5 * zoom))
                .foregroundStyle(Color.secondary))
            let keyWidth = key.measure(in: CGSize(width: 400, height: 40)).width
            ctx.draw(key, at: CGPoint(x: box.minX + 11 * zoom, y: y), anchor: .leading)

            // Values are elided to whatever space the label leaves; the full
            // text is always available in the inspector.
            let available = box.width - keyWidth - 30 * zoom
            let value = elide(fact.value, to: available, ctx: ctx,
                              size: 9 * zoom, tint: fact.tint ?? Color.primary)
            ctx.draw(value, at: CGPoint(x: box.maxX - 11 * zoom, y: y), anchor: .trailing)
            y += 17 * zoom
        }
    }

    private func elide(_ text: String, to width: CGFloat, ctx: GraphicsContext,
                       size: CGFloat, tint: Color) -> GraphicsContext.ResolvedText {
        func resolve(_ s: String) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(s).font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundStyle(tint))
        }
        var resolved = resolve(text)
        guard width > 0 else { return resolved }
        if resolved.measure(in: CGSize(width: 4000, height: 40)).width <= width { return resolved }

        var characters = Array(text)
        while characters.count > 2 {
            characters.removeLast()
            resolved = resolve(String(characters) + "…")
            if resolved.measure(in: CGSize(width: 4000, height: 40)).width <= width { return resolved }
        }
        return resolved
    }

    // MARK: Overlays

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CONFIDENCE")
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            ForEach([Confidence.observed, .inferred, .unobserved], id: \.label) { c in
                HStack(spacing: 6) {
                    Rectangle().fill(c.tint).frame(width: 14, height: 2)
                    Text(c.label).font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
            Text("Dashed lines are paths this Mac cannot see.")
                .font(.system(size: 9)).foregroundStyle(Color.subtle)
                .padding(.top, 2)
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.hairline, lineWidth: 1))
    }

    private func inspector(_ node: MapNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(node.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Pill(text: node.confidence.label, tint: node.confidence.tint)
                Button { selected = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
            }
            if let sub = node.subtitle {
                Text(sub).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Divider()
            // The inspector always shows everything, whatever the zoom.
            ForEach(node.facts) { fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.label.uppercased())
                        .font(.system(size: 8, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .font(.system(size: 11, design: fact.value.count > 40 ? .default : .monospaced))
                        .foregroundStyle(fact.tint ?? .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(width: 268)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}
