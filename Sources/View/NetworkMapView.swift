import SwiftUI

/// A schematic of the current Wi-Fi path and the local evidence around it.
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
    @State private var arpObservedAt: Date?
    @State private var arpReadInFlight = false
    @State private var selectedNodeID: String?
    @State private var showNotes = false
    @State private var lastViewportSize = CGSize(width: 900, height: 600)
    /// Until the operator pans or zooms, the drawing keeps framing itself as
    /// nodes arrive — ARP and scan results land a few seconds after launch.
    @State private var userAdjusted = false

    // Lattice geometry.
    private let nodeWidth: CGFloat = 232
    private let columnSpacing: CGFloat = 280
    private let rowSpacing: CGFloat = 240

    /// The built topology, held rather than recomputed.
    ///
    /// It used to be a computed property, which meant a full rebuild — vendor
    /// lookups for every neighbour included — on each of the eight or so places
    /// the body, the layout and the hit testing read it. It is now assembled
    /// once whenever the data behind it actually moves.
    @State private var map = NetworkMap()

    private func rebuildMap() {
        map = TopologyBuilder.build(
            sample: monitor.current, status: monitor.status,
            ip: netInfo.config, arp: arp, scan: scanner.results,
            ipObservedAt: netInfo.lastRefresh,
            arpObservedAt: arpObservedAt,
            scanObservedAt: scanner.lastScan,
            registry: registry, pinger: pinger, vendors: vendors)
    }

    /// How much of each node is worth showing at the current magnification.
    private var detail: Detail? {
        switch zoom {
        case ..<0.72: return nil
        case ..<1.25: return .primary
        case ..<2.0: return .secondary
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

    /// Only values that can change the fitted extents belong here. Live RSSI
    /// changes redraw continuously without needlessly snapping the viewport.
    private var layoutSignature: [String] {
        map.nodes.map { node in
            let primaryCount = node.facts.filter { $0.detail == .primary && !$0.inspectorOnly }.count
            return "\(node.id):\(primaryCount)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    canvas(geo.size)
                    if showNotes, !operationalNotes.isEmpty {
                        notesPanel
                            .padding(12)
                            .allowsHitTesting(true)
                    }
                    if let selectedNodeID, let node = map.node(selectedNodeID) {
                        inspector(node)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .allowsHitTesting(true)
                    }
                    legend
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
                            let nextZoom = clampedZoom(committedZoom * v.magnification)
                            let anchor = CGPoint(x: geo.size.width * v.startAnchor.x,
                                                 y: geo.size.height * v.startAnchor.y)
                            offset = zoomedOffset(from: committedOffset,
                                                  oldZoom: committedZoom,
                                                  newZoom: nextZoom,
                                                  anchor: anchor,
                                                  viewport: geo.size)
                            zoom = nextZoom
                        }
                        .onEnded { _ in
                            committedZoom = zoom
                            committedOffset = offset
                            userAdjusted = true
                        }
                )
                .onTapGesture { location in
                    selectedNodeID = hitTest(location, in: geo.size)?.id
                }
                .onAppear {
                    lastViewportSize = geo.size
                    fit(in: geo.size)
                }
                .onChange(of: geo.size) { _, new in
                    lastViewportSize = new
                    if !userAdjusted { fit(in: new) }
                }
                .onChange(of: layoutSignature) { _, _ in
                    if !userAdjusted { fit(in: lastViewportSize) }
                }
                .onChange(of: map.nodes.map(\.id)) { _, ids in
                    if let selectedNodeID, !ids.contains(selectedNodeID) {
                        self.selectedNodeID = nil
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            reloadARP()
            rebuildMap()
        }
        // The sample identity changes once a second while monitoring, which is
        // also what picks up nickname and vendor edits. The timer covers the
        // case where sampling is paused.
        .onChange(of: monitor.current?.id) { _, _ in rebuildMap() }
        .onChange(of: monitor.status) { _, _ in rebuildMap() }
        .onChange(of: arp) { _, _ in rebuildMap() }
        .onChange(of: scanner.results.count) { _, _ in rebuildMap() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            reloadARP()
            rebuildMap()
        }
    }

    private func reloadARP() {
        guard !arpReadInFlight else { return }
        arpReadInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let entries = ARPTable.read()
            Task { @MainActor in
                self.arp = entries
                self.arpObservedAt = Date()
                self.arpReadInFlight = false
            }
        }
    }

    // MARK: Toolbar

    private var operationalNotes: [String] {
        map.notes + (scanner.errorMessage.map { ["Scan could not be refreshed: \($0)"] } ?? [])
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("CURRENT WI-FI PATH")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("The current Wi-Fi path and locally observed context — not a full network inventory")

            Pill(text: detailName, tint: .blue)
                .fixedSize()
                .help("Zoom in for more detail on every node and link")

            Spacer()

            Menu {
                ForEach(map.nodes) { node in
                    Button(node.title) { focus(on: node) }
                }
            } label: {
                Label("Jump to", systemImage: "scope")
            }
            .controlSize(.small)
            .help("Center a map item and show all of its facts")

            Button {
                scanner.scan(currentSSID: monitor.current?.ssid,
                             currentBSSID: monitor.current?.bssid)
            } label: {
                Label(scanner.isScanning ? "Scanning…" : "Scan APs",
                      systemImage: scanner.isScanning ? "dot.radiowaves.left.and.right" : "dot.radiowaves.up.forward")
            }
            .controlSize(.small)
            .disabled(scanner.isScanning || monitor.current?.ssid == nil)
            .help(monitor.current?.ssid == nil
                  ? "The current network name is needed to match other access points."
                  : "Scans for nearby access points. This sends Wi-Fi probe requests.")

            Pill(text: "TRANSMITS", tint: .orange)
                .help("Nearby-network scans send Wi-Fi probe requests")

            if let lastScan = scanner.lastScan {
                Text(Fmt.relativeTime(lastScan))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Date().timeIntervalSince(lastScan) > 120 ? .orange : .secondary)
                    .help("Last nearby-network scan: \(Fmt.stamp.string(from: lastScan))")
            }

            if !operationalNotes.isEmpty {
                Button { showNotes.toggle() } label: {
                    Label("Map notes", systemImage: "info.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Show \(operationalNotes.count) map note\(operationalNotes.count == 1 ? "" : "s")")
            }

            Button { setZoom(zoom / 1.35) } label: {
                Label("Zoom out", systemImage: "minus.magnifyingglass")
            }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("Zoom out")
            Text(String(format: "%.0f%%", zoom * 100))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 42)
            Button { setZoom(zoom * 1.35) } label: {
                Label("Zoom in", systemImage: "plus.magnifyingglass")
            }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("Zoom in")
            Button("Fit") { fitToDefault() }.controlSize(.small)
                .help("Fit the whole connection map in the window")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func setZoom(_ z: CGFloat) {
        userAdjusted = true
        let nextZoom = clampedZoom(z)
        let centre = CGPoint(x: lastViewportSize.width / 2, y: lastViewportSize.height / 2)
        let nextOffset = zoomedOffset(from: offset, oldZoom: zoom, newZoom: nextZoom,
                                      anchor: centre, viewport: lastViewportSize)
        withAnimation(.easeOut(duration: 0.18)) {
            zoom = nextZoom
            offset = nextOffset
            committedZoom = nextZoom
            committedOffset = nextOffset
        }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.22), 4.5)
    }

    /// Keeps the model point beneath the gesture anchor in place while the
    /// rest of the drawing scales around it.
    private func zoomedOffset(from oldOffset: CGSize, oldZoom: CGFloat, newZoom: CGFloat,
                              anchor: CGPoint, viewport: CGSize) -> CGSize {
        guard oldZoom > 0 else { return oldOffset }
        let centre = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let modelX = (anchor.x - centre.x - oldOffset.width) / oldZoom
        let modelY = (anchor.y - centre.y - oldOffset.height) / oldZoom
        return CGSize(width: anchor.x - centre.x - modelX * newZoom,
                      height: anchor.y - centre.y - modelY * newZoom)
    }

    private func focus(on node: MapNode) {
        userAdjusted = true
        let nextZoom = max(zoom, 1.0)
        let point = origin(for: node)
        let nextOffset = CGSize(width: -point.x * nextZoom, height: -point.y * nextZoom)
        withAnimation(.easeOut(duration: 0.22)) {
            zoom = nextZoom
            committedZoom = nextZoom
            offset = nextOffset
            committedOffset = nextOffset
            selectedNodeID = node.id
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
        zoom = min(max(scale, 0.22), 1.15)
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
        .accessibilityLabel("Current connection map")
        .accessibilityHint("Use Jump to in the toolbar to inspect a map item without panning or zooming.")
        .accessibilityRepresentation {
            VStack {
                ForEach(map.nodes) { node in
                    Button("\(node.title), \(node.confidence.label)") { focus(on: node) }
                }
            }
        }
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
        let dash: [CGFloat] = edge.confidence == .unobserved ? [5, 4] : []
        ctx.stroke(path, with: .color(tint.opacity(edge.confidence == .unobserved ? 0.6 : 0.9)),
                   style: StrokeStyle(lineWidth: edge.kind == .wireless ? 2 : 1.3,
                                      lineCap: .round, lineJoin: .round, dash: dash))

        // Terminators.
        for p in [start, end] {
            let t = transform(p, size)
            ctx.fill(Path(ellipseIn: CGRect(x: t.x - 2.5, y: t.y - 2.5, width: 5, height: 5)),
                     with: .color(tint))
        }

        // At overview scale, topology is more useful than repeated tiny labels.
        guard zoom > 0.8 else { return }
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
        let isSelected = selectedNodeID == node.id

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
        let titleSize = max(8.5, 11.5 * zoom)
        let confidenceReserve: CGFloat = {
            guard zoom > 0.9 else { return 0 }
            switch node.confidence {
            case .observed: return 0
            case .inferred: return 46 * zoom
            case .unobserved: return 78 * zoom
            }
        }()
        let title = elide(node.title,
                          to: box.maxX - textX - 9 * zoom - confidenceReserve,
                          ctx: ctx, size: titleSize, weight: .semibold,
                          design: .default, tint: Color.primary)
        ctx.draw(title, at: CGPoint(x: textX, y: box.minY + 17 * zoom), anchor: .leading)

        if let sub = node.subtitle, zoom >= 0.58 {
            let subtitle = elide(sub,
                                 to: box.maxX - textX - 9 * zoom,
                                 ctx: ctx, size: max(7.5, 9 * zoom),
                                 weight: .regular, design: .monospaced,
                                 tint: Color.secondary)
            ctx.draw(subtitle, at: CGPoint(x: textX, y: box.minY + 30 * zoom), anchor: .leading)
        }

        // Confidence stamp, like a drawing revision mark.
        if node.confidence != .observed, zoom > 0.9 {
            let stamp = ctx.resolve(Text(node.confidence.label.uppercased())
                .font(.system(size: max(6.5, 7 * zoom), weight: .bold))
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
                .font(.system(size: max(8, 8.5 * zoom)))
                .foregroundStyle(Color.secondary))
            let keyWidth = key.measure(in: CGSize(width: 400, height: 40)).width
            ctx.draw(key, at: CGPoint(x: box.minX + 11 * zoom, y: y), anchor: .leading)

            // Values are elided to whatever space the label leaves; the full
            // text is always available in the inspector.
            let available = box.width - keyWidth - 30 * zoom
            let value = elide(fact.value, to: available, ctx: ctx,
                              size: max(8, 9 * zoom), tint: fact.tint ?? Color.primary)
            ctx.draw(value, at: CGPoint(x: box.maxX - 11 * zoom, y: y), anchor: .trailing)
            y += 17 * zoom
        }
    }

    private func elide(_ text: String, to width: CGFloat, ctx: GraphicsContext,
                       size: CGFloat, weight: Font.Weight = .medium,
                       design: Font.Design = .monospaced,
                       tint: Color) -> GraphicsContext.ResolvedText {
        func resolve(_ s: String) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(s).font(.system(size: size, weight: weight, design: design))
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

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("About this map").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { showNotes = false } label: {
                    Label("Close notes", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
            }
            ForEach(operationalNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CONFIDENCE")
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            ForEach([Confidence.observed, .inferred, .unobserved], id: \.label) { c in
                HStack(spacing: 6) {
                    Canvas { context, size in
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: size.height / 2))
                        line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        context.stroke(line, with: .color(c.tint),
                                       style: StrokeStyle(lineWidth: 2,
                                                          dash: c == .unobserved ? [3, 2] : []))
                    }
                    .frame(width: 14, height: 4)
                    Text(c.label).font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
            Text("Only grey dashed paths are not observable.")
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
                Button { selectedNodeID = nil } label: {
                    Label("Close details", systemImage: "xmark.circle.fill")
                }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
            }
            if let sub = node.subtitle {
                Text(sub).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Divider()
            // The inspector always shows everything, whatever the zoom.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(node.facts) { fact in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.label.uppercased())
                                .font(.system(size: 8, weight: .semibold)).tracking(0.4)
                                .foregroundStyle(.secondary)
                                .explains(fact.label)
                            Text(fact.value)
                                .font(.system(size: 11, design: fact.value.count > 40 ? .default : .monospaced))
                                .foregroundStyle(fact.tint ?? .primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if let metadata = factMetadata(fact) {
                                Text(metadata)
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(fact.isStale() ? Color.orange : Color.subtle)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(fact.observedAt.map { Fmt.stamp.string(from: $0) } ?? "")
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 430)
        }
        .padding(12)
        .frame(width: 282)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private func factMetadata(_ fact: Fact) -> String? {
        var pieces: [String] = []
        if fact.isStale() { pieces.append("STALE") }
        if let confidence = fact.confidence { pieces.append(confidence.label) }
        if let source = fact.source { pieces.append(source) }
        if let observedAt = fact.observedAt { pieces.append(Fmt.relativeTime(observedAt)) }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }
}
