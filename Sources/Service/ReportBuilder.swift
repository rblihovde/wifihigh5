import Foundation

/// Turns a saved walkthrough into something you can hand to a client.
///
/// The output is one self-contained HTML file: no external stylesheets, no
/// scripts, no network requests. It opens on any machine and prints to PDF from
/// the browser, which is what site reports usually end up as.
enum ReportBuilder {

    // MARK: HTML

    @MainActor
    static func html(for session: SurveySession, registry: APRegistry) -> String {
        let values = session.samples.map(\.rssi)
        let avg = values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        let worst = values.min()
        let best = values.max()

        var out = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <title>\(esc(displayName(session))) — Wi-Fi walkthrough</title>
        <style>
          :root { color-scheme: light; }
          body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                 margin: 0; padding: 32px; color: #1a1a1a; background: #fff; max-width: 1000px; }
          h1 { font-size: 22px; margin: 0 0 4px; }
          h2 { font-size: 14px; text-transform: uppercase; letter-spacing: .06em;
               color: #666; margin: 32px 0 10px; font-weight: 600; }
          .sub { color: #666; font-size: 12.5px; margin-bottom: 24px; }
          .tiles { display: flex; flex-wrap: wrap; gap: 10px; }
          .tile { border: 1px solid #e2e2e2; border-radius: 8px; padding: 10px 14px; min-width: 110px; }
          .tile .k { font-size: 10px; text-transform: uppercase; letter-spacing: .05em; color: #777; }
          .tile .v { font-size: 19px; font-weight: 600; font-variant-numeric: tabular-nums; }
          table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
          th { text-align: left; font-size: 10px; text-transform: uppercase; letter-spacing: .05em;
               color: #777; border-bottom: 1px solid #ddd; padding: 6px 8px; }
          td { padding: 7px 8px; border-bottom: 1px solid #f0f0f0; }
          td.num { text-align: right; font-variant-numeric: tabular-nums; }
          .chip { display: inline-block; width: 9px; height: 9px; border-radius: 2px;
                  margin-right: 6px; vertical-align: baseline; }
          .note { color: #666; font-size: 11px; }
          .method { border-left: 3px solid #ddd; padding: 4px 0 4px 14px; color: #555; font-size: 12px; }
          svg { border: 1px solid #e2e2e2; border-radius: 8px; background: #fafafa; }
          @media print { body { padding: 0; } h2 { margin-top: 20px; } }
        </style></head><body>

        <h1>\(esc(displayName(session)))</h1>
        <div class="sub">\(esc(session.site.isEmpty ? "Wi-Fi walkthrough" : session.site))
        &middot; \(esc(Fmt.stamp.string(from: session.started)))
        &middot; \(esc(Fmt.duration(session.duration)))</div>

        <div class="tiles">
        \(tile("Readings", "\(session.samples.count)"))
        \(tile("Duration", Fmt.duration(session.duration)))
        \(avg.map { tile("Average", "\($0) dBm") } ?? "")
        \(worst.map { tile("Worst", "\($0) dBm") } ?? "")
        \(best.map { tile("Best", "\($0) dBm") } ?? "")
        \(tile("Marked spots", "\(session.waypoints.count)"))
        \(tile("Access points", "\(session.apKeys.count)"))
        \(tile("Changes", "\(max(0, session.roamEvents.count - 1))"))
        </div>

        <h2>Signal over the walk</h2>
        \(chartSVG(session))
        <div class="note">Signal strength in dBm. Higher (closer to zero) is stronger.
        &minus;67 dBm is the usual practical floor for voice and video.
        Vertical marks are the spots recorded during the walk.</div>
        """

        if !session.waypoints.isEmpty {
            out += "\n<h2>By marked spot</h2>\n<table><tr><th>Spot</th><th>Time</th><th>Held</th><th class=\"num\">Average</th><th class=\"num\">Worst</th><th>Access point</th></tr>\n"
            for w in session.waypoints.sorted(by: { $0.time < $1.time }) {
                let leg = session.leg(for: w)
                let v = leg.map(\.rssi)
                let a = v.isEmpty ? w.rssi : Int((Double(v.reduce(0, +)) / Double(v.count)).rounded())
                let mn = v.min() ?? w.rssi
                let key = leg.last?.apKey ?? w.apKey
                let apName = key.map { registry.displayName(for: $0) } ?? "—"
                let color = key.map { hex(registry.colorIndexHint(for: $0)) } ?? "#ccc"
                out += """
                <tr><td><strong>\(esc(w.label))</strong>\(w.note.isEmpty ? "" : "<br><span class=\"note\">\(esc(w.note))</span>")</td>
                <td>\(esc(Fmt.clock.string(from: w.time)))</td>
                <td>\(esc(leg.isEmpty ? "—" : Fmt.duration(Double(leg.count) * session.sampleInterval)))</td>
                <td class="num">\(a.map { "\($0) dBm" } ?? "—")</td>
                <td class="num">\(mn.map { "\($0) dBm" } ?? "—")</td>
                <td><span class="chip" style="background:\(color)"></span>\(esc(apName))</td></tr>

                """
            }
            out += "</table>\n"
        }

        out += "\n<h2>Access points seen</h2>\n<table><tr><th>Access point</th><th>BSSID</th><th class=\"num\">Readings</th><th class=\"num\">Range</th></tr>\n"
        for key in session.apKeys {
            let forThis = session.samples.filter { $0.apKey == key }
            let v = forThis.map(\.rssi)
            let range = (v.min()).flatMap { mn in v.max().map { "\(mn) … \($0) dBm" } } ?? "—"
            out += """
            <tr><td><span class="chip" style="background:\(hex(registry.colorIndexHint(for: key)))"></span>\(esc(registry.displayName(for: key)))</td>
            <td>\(esc(key.bssidValue ?? "not available"))</td>
            <td class="num">\(forThis.count)</td>
            <td class="num">\(esc(range))</td></tr>

            """
        }
        out += "</table>\n"

        out += """

        <h2>Method</h2>
        <div class="method">
        Readings were taken from this Mac's own Wi-Fi interface once every
        \(String(format: "%.1f", session.sampleInterval)) seconds while walking the site.
        The tool reads only the state of the link this Mac had already joined, plus the IP
        settings it was assigned. It captured no traffic, probed no other hosts, and sent
        nothing off the machine. Signal strength is the value reported by the Wi-Fi driver
        for the access point serving the link at that moment.
        </div>

        </body></html>
        """
        return out
    }

    // MARK: CSV

    @MainActor
    static func csv(for session: SurveySession, registry: APRegistry) -> String {
        var rows = ["timestamp,waypoint,ssid,bssid,ap_nickname,rssi_dbm,noise_dbm,snr_db,channel,band,tx_rate_mbps,quality"]
        let ordered = session.waypoints.sorted { $0.time < $1.time }
        for s in session.samples {
            // Attribute each reading to the most recent spot marked before it.
            let spot = ordered.last { $0.time <= s.time }?.label ?? ""
            let cols = [
                Fmt.stamp.string(from: s.time),
                escapeCSV(spot),
                escapeCSV(s.ssid ?? ""),
                s.bssid ?? "",
                escapeCSV(registry.nickname(for: s.apKey) ?? ""),
                String(s.rssi),
                s.validNoise.map(String.init) ?? "",
                s.snr.map(String.init) ?? "",
                String(s.channel),
                s.band.label,
                String(format: "%.0f", s.txRate),
                s.quality.label
            ]
            rows.append(cols.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func displayName(_ s: SurveySession) -> String {
        s.name.isEmpty ? "Untitled walkthrough" : s.name
    }

    private static func tile(_ k: String, _ v: String) -> String {
        "<div class=\"tile\"><div class=\"k\">\(esc(k))</div><div class=\"v\">\(esc(v))</div></div>"
    }

    /// Signal trace as inline SVG, with the coverage floor and the marked spots.
    private static func chartSVG(_ session: SurveySession) -> String {
        let w = 940.0, h = 260.0, left = 44.0, right = 12.0, top = 14.0, bottom = 26.0
        let plotW = w - left - right, plotH = h - top - bottom
        guard let first = session.samples.first?.time,
              let last = session.samples.last?.time,
              last > first else {
            return "<svg width=\"\(Int(w))\" height=\"60\"><text x=\"12\" y=\"34\" font-size=\"12\" fill=\"#777\">Not enough readings to plot.</text></svg>"
        }
        let span = last.timeIntervalSince(first)
        let lo = -95.0, hi = -25.0
        func px(_ t: Date) -> Double { left + plotW * (t.timeIntervalSince(first) / span) }
        func py(_ v: Double) -> Double { top + plotH * (1 - (v - lo) / (hi - lo)) }

        var svg = "<svg width=\"\(Int(w))\" height=\"\(Int(h))\" viewBox=\"0 0 \(Int(w)) \(Int(h))\" xmlns=\"http://www.w3.org/2000/svg\">"
        for v in stride(from: -90.0, through: -30.0, by: 10) {
            let y = py(v)
            svg += "<line x1=\"\(left)\" y1=\"\(y)\" x2=\"\(left + plotW)\" y2=\"\(y)\" stroke=\"#e8e8e8\"/>"
            svg += "<text x=\"\(left - 6)\" y=\"\(y + 3)\" font-size=\"9\" fill=\"#999\" text-anchor=\"end\">\(Int(v))</text>"
        }
        // The practical coverage floor, the line most site decisions hang on.
        let floorY = py(-67)
        svg += "<line x1=\"\(left)\" y1=\"\(floorY)\" x2=\"\(left + plotW)\" y2=\"\(floorY)\" stroke=\"#e0a030\" stroke-dasharray=\"4 3\"/>"
        svg += "<text x=\"\(left + plotW - 2)\" y=\"\(floorY - 4)\" font-size=\"9\" fill=\"#c08020\" text-anchor=\"end\">−67 dBm</text>"

        // Downsample so the file stays small on long walks.
        let stride_ = Swift.max(1, session.samples.count / 1200)
        let pts = session.samples.enumerated().filter { $0.offset % stride_ == 0 }.map { $0.element }
        let d = pts.map { "\(String(format: "%.1f", px($0.time))),\(String(format: "%.1f", py(Double($0.rssi))))" }
                   .joined(separator: " ")
        svg += "<polyline fill=\"none\" stroke=\"#2f6fd0\" stroke-width=\"1.6\" points=\"\(d)\"/>"

        for wp in session.waypoints {
            let x = px(wp.time)
            guard x >= left, x <= left + plotW else { continue }
            svg += "<line x1=\"\(x)\" y1=\"\(top)\" x2=\"\(x)\" y2=\"\(top + plotH)\" stroke=\"#8a8a8a\" stroke-dasharray=\"2 3\"/>"
            svg += "<text x=\"\(x)\" y=\"\(top + plotH + 16)\" font-size=\"9\" fill=\"#555\" text-anchor=\"middle\">\(esc(String(wp.label.prefix(14))))</text>"
        }
        svg += "</svg>"
        return svg
    }

    private static func hex(_ index: Int) -> String {
        let palette = ["#4d9ef2", "#f2735a", "#59cc8c", "#d98cf2", "#fabf40",
                       "#59d1d9", "#f28cb2", "#99bf4d", "#8c8cf2", "#e5a666",
                       "#66b3bf", "#cc6688"]
        return palette[index % palette.count]
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeCSV(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
