import Foundation
import CoreGraphics

// A tiny harness rather than XCTest: the app is built by swiftc directly, and
// this keeps `./run-tests.sh` a single command with no project restructuring.
// These cover the arithmetic whose output ends up in front of a client.

private var checks = 0
private var failures: [String] = []

private func expect(_ label: String, _ condition: Bool) {
    checks += 1
    if !condition { failures.append(label) }
}

private func expectEqual<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    checks += 1
    if actual != expected {
        failures.append("\(label) — expected \(expected), got \(actual)")
    }
}

private func sample(rssi: Int, noise: Int = -90, bssid: String? = "aa:bb:cc:dd:ee:ff",
                    ssid: String? = "Net", channel: Int = 36, band: Int = 2,
                    at offset: TimeInterval = 0, from base: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> WiFiSample {
    WiFiSample(time: base.addingTimeInterval(offset), ssid: ssid, bssid: bssid,
               rssi: rssi, noise: noise, txRate: 866, txPower: 20,
               channel: channel, channelWidthRaw: 3, bandRaw: band, phyRaw: 6,
               securityRaw: 4, countryCode: "US", interfaceName: "en0",
               hardwareAddress: "11:22:33:44:55:66")
}

/// A fresh folder for a registry under test, so no test ever reads or writes
/// the saved data in Application Support.
private func scratchFolder() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wifihigh5-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: Signal quality thresholds

private func testSignalQuality() {
    expectEqual("rssi -40 excellent", SignalQuality(rssi: -40), .excellent)
    expectEqual("rssi -50 boundary is excellent", SignalQuality(rssi: -50), .excellent)
    expectEqual("rssi -51 good", SignalQuality(rssi: -51), .good)
    expectEqual("rssi -60 boundary is good", SignalQuality(rssi: -60), .good)
    expectEqual("rssi -61 fair", SignalQuality(rssi: -61), .fair)
    expectEqual("rssi -67 boundary is fair", SignalQuality(rssi: -67), .fair)
    expectEqual("rssi -68 weak", SignalQuality(rssi: -68), .weak)
    expectEqual("rssi -75 boundary is weak", SignalQuality(rssi: -75), .weak)
    expectEqual("rssi -76 poor", SignalQuality(rssi: -76), .poor)

    expectEqual("snr 45 excellent", SignalQuality(snr: 45), .excellent)
    expectEqual("snr 40 boundary excellent", SignalQuality(snr: 40), .excellent)
    expectEqual("snr 39 good", SignalQuality(snr: 39), .good)
    expectEqual("snr 25 boundary good", SignalQuality(snr: 25), .good)
    expectEqual("snr 24 fair", SignalQuality(snr: 24), .fair)
    expectEqual("snr 14 weak", SignalQuality(snr: 14), .weak)
    expectEqual("snr 9 poor", SignalQuality(snr: 9), .poor)

    expect("quality is ordered", SignalQuality.poor < SignalQuality.excellent)
}

// MARK: Noise and SNR optionality

private func testNoiseHandling() {
    expectEqual("valid noise passes through", sample(rssi: -40, noise: -85).validNoise, -85)
    expect("zero noise is treated as unreported", sample(rssi: -40, noise: 0).validNoise == nil)
    expect("positive noise is rejected", sample(rssi: -40, noise: 5).validNoise == nil)
    expect("absurdly low noise is rejected", sample(rssi: -40, noise: -130).validNoise == nil)

    expectEqual("snr computed from valid noise", sample(rssi: -40, noise: -90).snr, 50)
    expect("snr nil when noise unreported", sample(rssi: -40, noise: 0).snr == nil)
    expect("snrQuality nil when noise unreported", sample(rssi: -40, noise: 0).snrQuality == nil)
    expectEqual("snrQuality graded when noise present",
                sample(rssi: -60, noise: -80).snrQuality, SignalQuality.fair)
}

// MARK: Access point identity

private func testAPIdentity() {
    let withBSSID = sample(rssi: -50).apKey
    expect("bssid gives precise identity", withBSSID.isPreciseIdentity)
    expectEqual("bssid is normalised to lower case",
                APKey(bssid: "AA:BB:CC:DD:EE:FF", ssid: "N", channel: 1, bandRaw: 1, phyRaw: 6, securityRaw: 4).raw,
                "bssid:aa:bb:cc:dd:ee:ff")

    let noBSSID = sample(rssi: -50, bssid: nil).apKey
    expect("missing bssid falls back to fingerprint", !noBSSID.isPreciseIdentity)
    expect("fingerprint has no bssid value", noBSSID.bssidValue == nil)

    // The fingerprint's known limitation: same channel and SSID collapses to one AP.
    let a = sample(rssi: -50, bssid: nil, channel: 36).apKey
    let b = sample(rssi: -80, bssid: nil, channel: 36).apKey
    expectEqual("same channel fingerprints collide (documented limitation)", a, b)

    let c = sample(rssi: -50, bssid: nil, channel: 149).apKey
    expect("different channel is a different fingerprint", a != c)

    // Colour must be stable across launches for the graph to stay readable.
    let key1 = APKey(raw: "bssid:aa:bb:cc:dd:ee:ff")
    let key2 = APKey(raw: "bssid:aa:bb:cc:dd:ee:ff")
    expectEqual("colour index is deterministic", key1.colorIndex, key2.colorIndex)
    expect("colour index is in range", key1.colorIndex >= 0 && key1.colorIndex < APPalette.colors.count)
}

// MARK: Formatting

private func testFormatting() {
    expectEqual("short mac", Fmt.shortMAC("00:00:5e:00:53:a1"), "…:53:a1")
    expectEqual("short mac passes through non-mac", Fmt.shortMAC("nope"), "nope")
    expectEqual("rate in mbps", Fmt.rate(866), "866 Mbps")
    expectEqual("rate in gbps", Fmt.rate(1200), "1.2 Gbps")
    expectEqual("zero rate", Fmt.rate(0), "—")
    expectEqual("seconds", Fmt.duration(45), "45s")
    expectEqual("minutes", Fmt.duration(125), "2m 5s")
    expectEqual("hours", Fmt.duration(3725), "1h 2m")
}

// MARK: Walkthrough leg attribution

@MainActor
private func testSurveyLegs() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let samples = (0..<30).map { sample(rssi: -50 - $0, at: Double($0), from: base) }
    let w1 = Waypoint(time: base, label: "Reception")
    let w2 = Waypoint(time: base.addingTimeInterval(10), label: "Corridor")
    let w3 = Waypoint(time: base.addingTimeInterval(20), label: "Server room")

    let session = SurveySession(
        name: "Test", site: "Site", started: base,
        ended: base.addingTimeInterval(30), sampleInterval: 1,
        samples: samples, roamEvents: [], waypoints: [w1, w2, w3])

    expectEqual("first leg spans to the next waypoint", session.leg(for: w1).count, 10)
    expectEqual("middle leg spans to the next waypoint", session.leg(for: w2).count, 10)
    expectEqual("last leg runs to the end of the session", session.leg(for: w3).count, 10)
    expectEqual("leg starts at its own waypoint",
                session.leg(for: w2).first?.time, base.addingTimeInterval(10))
    expectEqual("distinct APs counted once", session.apKeys.count, 1)

    // Waypoints out of order must still produce correct legs.
    let shuffled = SurveySession(
        name: "T", site: "", started: base, ended: base.addingTimeInterval(30),
        sampleInterval: 1, samples: samples, roamEvents: [], waypoints: [w3, w1, w2])
    expectEqual("leg is correct regardless of waypoint order",
                shuffled.leg(for: w1).count, 10)
}

// MARK: Export safety

@MainActor
private func testExports() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let registry = APRegistry(folder: scratchFolder())
    let samples = (0..<5).map { sample(rssi: -55, at: Double($0), from: base) }
    let nasty = Waypoint(time: base, label: "Reception, \"main\" desk")
    let session = SurveySession(
        name: "Export", site: "", started: base, ended: base.addingTimeInterval(5),
        sampleInterval: 1, samples: samples, roamEvents: [], waypoints: [nasty])

    let csv = ReportBuilder.csv(for: session, registry: registry)
    expect("csv quotes a field containing a comma",
           csv.contains("\"Reception, \"\"main\"\" desk\""))
    expectEqual("csv has a header plus one row per sample",
                csv.split(separator: "\n").count, samples.count + 1)

    let scripted = Waypoint(time: base, label: "<script>alert(1)</script>")
    let xss = SurveySession(
        name: "X<>", site: "", started: base, ended: base.addingTimeInterval(5),
        sampleInterval: 1, samples: samples, roamEvents: [], waypoints: [scripted])
    let html = ReportBuilder.html(for: xss, registry: registry)
    expect("html escapes angle brackets from labels", !html.contains("<script>alert"))
    expect("html contains the escaped form", html.contains("&lt;script&gt;"))

    // A session with no readings must not crash the chart generator.
    let empty = SurveySession(name: "Empty", site: "", started: base, ended: base,
                              sampleInterval: 1, samples: [], roamEvents: [], waypoints: [])
    let emptyHTML = ReportBuilder.html(for: empty, registry: registry)
    expect("empty session still produces a report", emptyHTML.contains("Not enough readings"))
}

// MARK: Codable round trip

@MainActor
private func testRoundTrip() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let samples = (0..<50).map { sample(rssi: -50 - ($0 % 20), at: Double($0), from: base) }
    let session = SurveySession(
        name: "Round trip", site: "Acme", started: base,
        ended: base.addingTimeInterval(50), sampleInterval: 1,
        samples: samples, roamEvents: [], waypoints: [Waypoint(time: base, label: "Start")])

    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    guard let data = try? enc.encode(session),
          let back = try? dec.decode(SurveySession.self, from: data) else {
        expect("session encodes and decodes", false); return
    }
    expectEqual("sample count survives", back.samples.count, session.samples.count)
    expectEqual("rssi survives", back.samples[7].rssi, session.samples[7].rssi)
    expectEqual("ap identity survives", back.samples[7].apKey, session.samples[7].apKey)
    expectEqual("waypoint id survives", back.waypoints.first?.id, session.waypoints.first?.id)
    expectEqual("waypoint label survives", back.waypoints.first?.label, "Start")
    expect("view-only sample ids are not encoded",
           !String(data: data, encoding: .utf8)!.contains("\"id\":\"\(session.samples[0].id)\""))
}

// MARK: Connection topology

private func scannedAP(_ suffix: Int, rssi: Int) -> ScanResult {
    ScanResult(ssid: "Net",
               bssid: String(format: "00:11:22:33:44:%02x", suffix),
               rssi: rssi, noise: -92, channel: 36 + suffix,
               bandRaw: 2, widthRaw: 3, securityRaw: 4,
               isCurrentNetwork: true, isCurrentAP: false)
}

@MainActor
private func testTopology(databaseURL: URL) {
    let registry = APRegistry(folder: scratchFolder())
    let vendors = VendorDatabase(url: databaseURL)
    let pinger = GatewayPinger()
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let config = IPConfig(ipv4: "192.168.10.20", subnetMask: "255.255.255.0",
                          router: "192.168.10.1", primaryInterface: "en0",
                          activeMAC: "11:22:33:44:55:66")
    let router = ARPEntry(ip: "192.168.10.1", mac: "00:aa:bb:cc:dd:10",
                          interfaceName: "en0")

    let hiddenBSSID = sample(rssi: -58, bssid: nil)
    let hiddenMap = TopologyBuilder.build(
        sample: hiddenBSSID, status: .connected, ip: config, arp: [router], scan: [],
        ipObservedAt: now, arpObservedAt: now, scanObservedAt: nil,
        registry: registry, pinger: pinger, vendors: vendors)
    expect("missing BSSID still shows the unknown router-to-AP path",
           hiddenMap.node("fabric") != nil)
    expect("missing BSSID does not disconnect the AP from the path",
           hiddenMap.edges.contains { $0.id == "fabric-ap" })

    var vpnConfig = config
    vpnConfig.primaryInterface = "utun3"
    let vpnMap = TopologyBuilder.build(
        sample: hiddenBSSID, status: .connected, ip: vpnConfig, arp: [router], scan: [],
        ipObservedAt: now, arpObservedAt: now, scanObservedAt: nil,
        registry: registry, pinger: pinger, vendors: vendors)
    expect("another default interface is disclosed on the upstream node",
           vpnMap.node("internet")?.facts.contains { $0.label == "Default route" && $0.value.contains("utun3") } == true)
    expect("another default interface adds a plain-language scope note",
           vpnMap.notes.contains { $0.contains("default route") && $0.contains("local Wi-Fi path") })

    let combined = sample(rssi: -51, bssid: "00:aa:bb:cc:dd:17")
    let combinedMap = TopologyBuilder.build(
        sample: combined, status: .connected, ip: config, arp: [router], scan: [],
        ipObservedAt: now, arpObservedAt: now, scanObservedAt: nil,
        registry: registry, pinger: pinger, vendors: vendors)
    expectEqual("same-chassis inference does not rename the measured router",
                combinedMap.node("router")?.title, "Router")
    expectEqual("same-chassis link is explicitly inferred",
                combinedMap.edges.first { $0.id == "router-ap" }?.confidence, .inferred)
    expect("same-chassis reasoning is available on a selectable node",
           combinedMap.node("ap")?.facts.contains { $0.label == "Likely shared chassis" && $0.confidence == .inferred } == true)

    let neighbours = [
        router,
        ARPEntry(ip: "192.168.10.30", mac: "00:00:5e:00:00:01", interfaceName: "en0"),
        ARPEntry(ip: "192.168.10.31", mac: "00:00:5e:00:00:02", interfaceName: "en1"),
        ARPEntry(ip: "192.168.10.32", mac: "00:00:5e:00:00:04", interfaceName: nil),
        ARPEntry(ip: "10.0.0.5", mac: "00:00:5e:00:00:03", interfaceName: "en0"),
        ARPEntry(ip: "192.168.10.20", mac: "11:22:33:44:55:66", interfaceName: "en0"),
        ARPEntry(ip: "192.168.10.255", mac: "ff:ff:ff:ff:ff:ff", interfaceName: "en0")
    ]
    let scopedMap = TopologyBuilder.build(
        sample: combined, status: .connected, ip: config, arp: neighbours, scan: [],
        ipObservedAt: now, arpObservedAt: now, scanObservedAt: nil,
        registry: registry, pinger: pinger, vendors: vendors)
    expectEqual("device cache is limited to this interface and subnet",
                scopedMap.node("neighbours")?.facts.first { $0.label == "Cached" }?.value, "1")

    let observed = ARPTable.devicesOnActiveSubnet(
        neighbours,
        interface: "en0",
        localAddress: config.ipv4,
        mask: config.subnetMask
    )
    expectEqual("passive device list stays on the active Wi-Fi subnet",
                observed.map(\.ip), ["192.168.10.1", "192.168.10.30"])
    expect("passive device list needs subnet data",
           ARPTable.devicesOnActiveSubnet(neighbours, interface: "en0",
                                          localAddress: nil, mask: nil).isEmpty)

    let scan = (1...6).map { scannedAP($0, rssi: -40 - $0) }
    let crowdedMap = TopologyBuilder.build(
        sample: combined, status: .connected, ip: config, arp: [router], scan: scan,
        ipObservedAt: now, arpObservedAt: now, scanObservedAt: now,
        registry: registry, pinger: pinger, vendors: vendors)
    let strongestID = "peer-\(scan[0].key.raw)"
    expect("strongest peer gets a stable identity", crowdedMap.node(strongestID) != nil)
    expectEqual("additional APs collapse into an explicit group",
                crowdedMap.node("peer-group")?.facts.first { $0.label == "Count" }?.value, "5")
    expect("large scan results are not silently discarded",
           crowdedMap.node("peer-group")?.title.contains("5 more") == true)
    let reorderedMap = TopologyBuilder.build(
        sample: combined, status: .connected, ip: config, arp: [router], scan: Array(scan.reversed()),
        ipObservedAt: now, arpObservedAt: now, scanObservedAt: now,
        registry: registry, pinger: pinger, vendors: vendors)
    expect("peer identity survives scan reordering", reorderedMap.node(strongestID) != nil)

    let manyNeighbours = [router] + (2...26).map {
        ARPEntry(ip: "192.168.10.\($0)",
                 mac: String(format: "00:00:5e:00:01:%02x", $0),
                 interfaceName: "en0")
    }
    let largeCacheMap = TopologyBuilder.build(
        sample: combined, status: .connected, ip: config, arp: manyNeighbours, scan: [],
        ipObservedAt: now, arpObservedAt: now, scanObservedAt: nil,
        registry: registry, pinger: pinger, vendors: vendors)
    expectEqual("large device cache reports its visible subset",
                largeCacheMap.node("neighbours")?.facts.first { $0.label == "Showing" }?.value,
                "14 of 24")
    expectEqual("large device cache reports omitted rows",
                largeCacheMap.node("neighbours")?.facts.first { $0.label == "Not listed" }?.value,
                "10")

    let dated = Fact(label: "Scan", value: "old", observedAt: now, staleAfter: 120)
    expect("fact freshness becomes stale at its declared threshold",
           dated.isStale(at: now.addingTimeInterval(121)))

    expect("same /24 subnet accepted",
           ARPTable.isOnSubnet("192.168.10.200", localAddress: "192.168.10.20", mask: "255.255.255.0"))
    expect("different /24 subnet rejected",
           !ARPTable.isOnSubnet("192.168.11.20", localAddress: "192.168.10.20", mask: "255.255.255.0"))
    expect("directed broadcast is not a subnet host",
           !ARPTable.isHostOnSubnet("192.168.10.255", localAddress: "192.168.10.20", mask: "255.255.255.0"))
    expect("network address is not a subnet host",
           !ARPTable.isHostOnSubnet("192.168.10.0", localAddress: "192.168.10.20", mask: "255.255.255.0"))
    expect("ordinary local address is a subnet host",
           ARPTable.isHostOnSubnet("192.168.10.30", localAddress: "192.168.10.20", mask: "255.255.255.0"))
    expect("broadcast MAC is not a device",
           !ARPEntry(ip: "192.168.10.255", mac: "ff:ff:ff:ff:ff:ff").isUnicast)
    expect("zero MAC is not a device",
           !ARPEntry(ip: "192.168.10.2", mac: "00:00:00:00:00:00").isUnicast)
    expect("malformed IPv4 rejected",
           !ARPTable.isOnSubnet("192.168.10.999", localAddress: "192.168.10.20", mask: "255.255.255.0"))
    expect("universal adjacent MACs support a chassis inference",
           ARPTable.likelySameChassis("00:AA:BB:CC:DD:10", "00:aa:bb:cc:dd:17"))
    expect("locally administered MACs never support a chassis inference",
           !ARPTable.likelySameChassis("02:aa:bb:cc:dd:10", "02:aa:bb:cc:dd:17"))
    expect("multicast MACs never support a chassis inference",
           !ARPTable.likelySameChassis("01:aa:bb:cc:dd:10", "01:aa:bb:cc:dd:17"))
    expect("malformed MACs never support a chassis inference",
           !ARPTable.likelySameChassis("00:zz:bb:cc:dd:10", "00:zz:bb:cc:dd:17"))
    expect("zero MACs never support a chassis inference",
           !ARPTable.likelySameChassis("00:00:00:00:00:00", "00:00:00:00:00:01"))
}

// MARK: Chart scale

private func testChartScale() {
    let steady = [-41, -42, -40, -43, -41]

    // Full keeps the fixed frame while the readings sit inside it.
    let full = ChartScale.full.verticalRange(signal: steady, noise: [-90])
    expectEqual("full scale keeps its floor", full.lowerBound, -95)
    expectEqual("full scale keeps its ceiling", full.upperBound, -25)
    let loud = ChartScale.full.verticalRange(signal: [-20], noise: [])
    expect("full scale widens rather than crop a strong reading", loud.upperBound >= -17)

    // Every zoomed scale frames the readings without cropping any of them.
    for scale in ChartScale.allCases where scale.isZoomed {
        let range = scale.verticalRange(signal: steady, noise: [])
        expect("\(scale.label) keeps the lowest reading inside",
               range.lowerBound <= -43)
        expect("\(scale.label) keeps the highest reading inside",
               range.upperBound >= -40)
        expect("\(scale.label) is at least its stated span",
               range.upperBound - range.lowerBound >= (scale.minimumSpan ?? 0))

        let step = ChartScale.gridStep(for: range.upperBound - range.lowerBound)
        expect("\(scale.label) lands on gridlines, so the axis does not shimmer",
               range.lowerBound.truncatingRemainder(dividingBy: step) == 0 &&
               range.upperBound.truncatingRemainder(dividingBy: step) == 0)
    }

    // A roam from strong to weak is far wider than a close scale. The span is
    // a floor, not a crop: the frame grows to hold both ends.
    let roam = ChartScale.close.verticalRange(signal: [-40, -72], noise: [])
    expect("a close scale widens to hold a large swing",
           roam.lowerBound <= -74 && roam.upperBound >= -38)

    // Zoomed views frame the signal. Including a noise floor 50 dB down would
    // undo the zoom entirely.
    let withNoise = ChartScale.fit.verticalRange(signal: steady, noise: [-92])
    expect("a zoomed scale ignores the noise floor", withNoise.lowerBound > -60)

    // Fit is the tightest view of all.
    let fit = ChartScale.fit.verticalRange(signal: steady, noise: [])
    let close = ChartScale.close.verticalRange(signal: steady, noise: [])
    expect("fit is no wider than the close scale",
           fit.upperBound - fit.lowerBound <= close.upperBound - close.lowerBound)

    expectEqual("no readings falls back to the full frame",
                ChartScale.fit.verticalRange(signal: [], noise: []), -95...(-25))
    expectEqual("close spans label every 2 dB", ChartScale.gridStep(for: 10), 2)
    expectEqual("medium spans label every 5 dB", ChartScale.gridStep(for: 20), 5)
    expectEqual("wide spans label every 10 dB", ChartScale.gridStep(for: 70), 10)
}

// MARK: Smooth curve

private func testSmoothCurve() {
    // Readings one second apart, with a peak, a trough, a plateau and a jump.
    let ys: [CGFloat] = [-44, -41, -43, -40, -40, -40, -47, -46, -52, -45, -45, -38]
    let pts = ys.enumerated().map { CGPoint(x: CGFloat($0.offset) * 10, y: $0.element) }
    let controls = SmoothCurve.controlPoints(through: pts)
    expectEqual("one pair of control points per span", controls.count, pts.count - 1)

    // A cubic Bézier never leaves the box its control points make. If both
    // control points sit between the readings at either end, the curve does
    // too, which is the guarantee that it draws nothing that was not measured.
    var overshoots = 0
    for (i, pair) in controls.enumerated() {
        let lo = Swift.min(pts[i].y, pts[i + 1].y) - 0.0001
        let hi = Swift.max(pts[i].y, pts[i + 1].y) + 0.0001
        for y in [pair.0.y, pair.1.y] where y < lo || y > hi { overshoots += 1 }
    }
    expectEqual("the curve never goes past a reading", overshoots, 0)

    // A run of identical readings is drawn flat, not as a wave.
    let flatStart = 3, flatEnd = 5
    for i in flatStart..<flatEnd {
        expect("a plateau is drawn flat",
               controls[i].0.y == pts[i].y && controls[i].1.y == pts[i + 1].y)
    }

    // Control points stay inside their span horizontally, so time runs forward.
    for (i, pair) in controls.enumerated() {
        expect("the curve moves forward in time",
               pair.0.x >= pts[i].x && pair.1.x <= pts[i + 1].x)
    }

    expect("a single reading has no spans", SmoothCurve.controlPoints(through: [pts[0]]).isEmpty)
    expectEqual("two readings make one span",
                SmoothCurve.controlPoints(through: Array(pts.prefix(2))).count, 1)
}

// MARK: CSV neutralisation

/// Splits one CSV line into cell values, undoing the quoting the way a
/// spreadsheet does before it decides whether a cell is a formula.
private func csvCells(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    var quoted = false
    let chars = Array(line.unicodeScalars)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if quoted {
            if c == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.unicodeScalars.append("\"")
                    i += 1
                } else {
                    quoted = false
                }
            } else {
                current.unicodeScalars.append(c)
            }
        } else if c == "\"" {
            quoted = true
        } else if c == "," {
            cells.append(current)
            current = ""
        } else {
            current.unicodeScalars.append(c)
        }
        i += 1
    }
    cells.append(current)
    return cells
}

private func startsLikeFormula(_ cell: String) -> Bool {
    guard let first = cell.unicodeScalars.first else { return false }
    return "=+-@\t\r\n\u{FF1D}\u{FF0B}\u{FF0D}\u{FF20}".unicodeScalars.contains(first)
}

@MainActor
private func testCSVEncoder() {
    for lead in ["=", "+", "-", "@", "\t", "\r", "\n", "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}"] {
        let cell = csvCells(CSVEncoder.field(lead + "SUM(1,2)")).joined(separator: ",")
        let code = String(lead.unicodeScalars.first!.value, radix: 16)
        expect("a field led by U+\(code) cannot start a formula", !startsLikeFormula(cell))
    }
    // Swift reads CR LF as one character; the check must still catch it.
    expect("a field led by CR LF is neutralised", CSVEncoder.field("\r\n=1").hasPrefix("\"'"))
    expectEqual("ordinary text is untouched", CSVEncoder.field("Reception printer"), "Reception printer")
    expectEqual("a comma is quoted", CSVEncoder.field("a,b"), "\"a,b\"")
    expectEqual("a quote is doubled", CSVEncoder.field("say \"hi\""), "\"say \"\"hi\"\"\"")
    expectEqual("a bare carriage return is quoted", CSVEncoder.field("a\rb"), "\"a\rb\"")
    expectEqual("a formula with commas and quotes is neutralised, then quoted",
                CSVEncoder.field("=HYPERLINK(\"http://x\",\"y\")"),
                "\"'=HYPERLINK(\"\"http://x\"\",\"\"y\"\")\"")

    // Names chosen by a device on the network, carried all the way through.
    let hostile = DeviceFinding(advertisedName: "=HYPERLINK(\"http://evil.example\",\"open\")",
                                model: "+cmd|' /C calc'!A0",
                                services: ["Printing"],
                                hostname: "@SUM(1+1)")
    let device = ObservedDevice(
        mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.1.9", role: .device,
        record: DeviceRecord(macKey: "aa:bb:cc:dd:ee:ff", notes: "-2+3"),
        vendor: .known("Example Corp"), sighting: nil,
        isLocallyAdministered: false, isPresent: true, guess: nil, finding: hostile)
    let deviceCSV = ReportBuilder.deviceCSV([device], networkName: "=1+1")
    var formulaCells = 0
    for line in deviceCSV.split(separator: "\n") {
        for cell in csvCells(String(line)) where startsLikeFormula(cell) { formulaCells += 1 }
    }
    expectEqual("no cell of the device export starts a formula", formulaCells, 0)
    expect("the hostile name is kept, neutralised", deviceCSV.contains("'=HYPERLINK"))

    // A walkthrough export carries an SSID, a nickname and a spot label.
    let registry = APRegistry(folder: scratchFolder())
    let reading = sample(rssi: -50, ssid: "=1+1")
    registry.setNickname("-evil", for: reading.apKey)
    let session = SurveySession(
        name: "T", site: "", started: reading.time, ended: reading.time.addingTimeInterval(5),
        sampleInterval: 1, samples: [reading], roamEvents: [],
        waypoints: [Waypoint(time: reading.time, label: "+SUM(A1)", note: "",
                             rssi: nil, snr: nil, apKeyRaw: nil)])
    let rows = ReportBuilder.csv(for: session, registry: registry).split(separator: "\n")
    let row = csvCells(String(rows[1]))
    for column in 1...4 {
        expect("walkthrough text column \(column) cannot start a formula",
               !startsLikeFormula(row[column]))
    }
    expectEqual("signal readings stay plain numbers", row[5], "-50")
}

// MARK: Untrusted text

private func testUntrustedText() {
    expectEqual("control characters are removed",
                UntrustedText.clean("A\u{0007}B\u{001B}C", limit: 50), "ABC")
    expectEqual("newlines go unless allowed", UntrustedText.clean("a\nb", limit: 50), "ab")
    expectEqual("newlines stay where allowed",
                UntrustedText.clean("a\nb", limit: 50, allowNewlines: true), "a\nb")
    expectEqual("direction overrides are removed",
                UntrustedText.clean("invoice\u{202E}fdp.exe", limit: 50), "invoicefdp.exe")
    expectEqual("length is capped",
                UntrustedText.clean(String(repeating: "é", count: 300), limit: 256).count, 256)
    expectEqual("emoji survive", UntrustedText.clean("Living Room 📺", limit: 50), "Living Room 📺")
    expect("an IPv4 address is recognised", UntrustedText.isIPv4("192.168.1.1"))
    expect("an out-of-range octet is refused", !UntrustedText.isIPv4("999.1.1.1"))
    expect("three octets is refused", !UntrustedText.isIPv4("1.2.3"))
    expect("a MAC is recognised", UntrustedText.isMAC("aa:bb:cc:dd:ee:ff"))
    expect("short octets are allowed", UntrustedText.isMAC("0:1b:63:a:b:c"))
    expect("five octets is refused", !UntrustedText.isMAC("aa:bb:cc:dd:ee"))
    expect("non-hex is refused", !UntrustedText.isMAC("zz:bb:cc:dd:ee:ff"))
}

// MARK: Import checks

@MainActor
private func testImportChecks() {
    let folder = scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let registry = APRegistry(folder: folder)
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601

    func record(_ key: String, colour: Int? = nil) -> APRecord {
        var r = APRecord(keyRaw: key)
        r.nickname = "AP"
        r.colorOverride = colour
        return r
    }
    func key(_ suffix: String) -> APKey { APKey(raw: "bssid:aa:bb:cc:dd:ee:" + suffix) }

    let badColours = [-1, Int.min, APPalette.colors.count, Int.max]
    var list = badColours.enumerated().map { record("bssid:aa:bb:cc:dd:ee:0\($0.offset)", colour: $0.element) }
    list.append(record("bssid:aa:bb:cc:dd:ee:09", colour: 5))
    var long = record("bssid:aa:bb:cc:dd:ee:0a")
    long.nickname = String(repeating: "x", count: 10_000)
    long.notes = "keep\nlines\u{0007}"
    list.append(long)
    var spoof = record("bssid:aa:bb:cc:dd:ee:0b")
    spoof.nickname = "Office\u{202E}txt.exe"
    list.append(spoof)
    var impossible = record("bssid:aa:bb:cc:dd:ee:0c")
    impossible.bestRSSI = 0
    impossible.worstRSSI = -500
    list.append(impossible)
    var future = record("bssid:aa:bb:cc:dd:ee:0d")
    future.lastSeen = Date().addingTimeInterval(86_400 * 365)
    list.append(future)
    list.append(record("bssid:not-a-mac"))
    list.append(record("evil-key"))
    list.append(record("fp:Net|ch36|b2|p6|s4"))

    guard let data = try? enc.encode(list) else {
        expect("the import fixture encodes", false)
        return
    }
    expectEqual("malformed keys are dropped and the rest imported",
                registry.importJSON(data), list.count - 2)
    for offset in badColours.indices {
        expect("an out-of-palette colour is discarded",
               registry.record(for: key("0\(offset)"))?.colorOverride == nil)
        expect("the colour a report asks for is in range",
               APPalette.colors.indices.contains(registry.colorIndexHint(for: key("0\(offset)"))))
    }
    expectEqual("a valid colour survives", registry.record(for: key("09"))?.colorOverride, 5)
    expectEqual("names are capped", registry.record(for: key("0a"))?.nickname.count, ImportGuard.maxNameLength)
    expectEqual("notes keep line breaks and lose control characters",
                registry.record(for: key("0a"))?.notes, "keep\nlines")
    expectEqual("direction overrides are removed", registry.record(for: key("0b"))?.nickname, "Officetxt.exe")
    expect("impossible signal readings are discarded",
           registry.record(for: key("0c"))?.bestRSSI == nil && registry.record(for: key("0c"))?.worstRSSI == nil)
    expect("a date in the future is brought back to now",
           (registry.record(for: key("0d"))?.lastSeen ?? .distantFuture) <= Date())
    expect("a fingerprint key is accepted", registry.record(for: APKey(raw: "fp:Net|ch36|b2|p6|s4")) != nil)
    expect("a malformed key is refused", registry.record(for: APKey(raw: "evil-key")) == nil)

    // A bad colour already on disk is repaired when it is read back.
    let disk = scratchFolder()
    defer { try? FileManager.default.removeItem(at: disk) }
    if let raw = try? enc.encode([record("bssid:aa:bb:cc:dd:ee:ff", colour: -1)]) {
        try? raw.write(to: disk.appendingPathComponent("access-points.json"))
    }
    expect("a bad colour saved before this check is repaired on load",
           APRegistry(folder: disk).record(for: key("ff"))?.colorOverride == nil)

    // And one that reaches a report by any other route cannot crash it.
    let reportRegistry = APRegistry(folder: scratchFolder())
    let reading = sample(rssi: -55)
    reportRegistry.setColor(-1, for: reading.apKey)
    let session = SurveySession(
        name: "T", site: "", started: reading.time, ended: reading.time.addingTimeInterval(1),
        sampleInterval: 1, samples: [reading], roamEvents: [], waypoints: [])
    expect("a report with an out-of-palette colour is still written",
           ReportBuilder.html(for: session, registry: reportRegistry).count > 100)

    // Limits refuse a file before it can change anything.
    let before = registry.records.count
    expectEqual("a file that is not an export is refused", registry.importJSON(Data("not json".utf8)), nil)
    expectEqual("a refused import changes nothing", registry.records.count, before)

    let many = (0...ImportGuard.maxRecords).map { APRecord(keyRaw: String(format: "fp:n%05d", $0)) }
    if let raw = try? enc.encode(many) {
        var failure: ImportGuard.Failure?
        do { _ = try APRegistry.decodeImport(raw) } catch { failure = error as? ImportGuard.Failure }
        expectEqual("an import with too many records is refused",
                    failure, .tooManyRecords(ImportGuard.maxRecords + 1))
    }

    func sparseFile(_ name: String, bytes: Int) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(bytes))
            try? handle.close()
        }
        return url
    }
    var sizeFailure: ImportGuard.Failure?
    do { _ = try ImportGuard.read(sparseFile("big.json", bytes: ImportGuard.maxFileBytes + 1)) }
    catch { sizeFailure = error as? ImportGuard.Failure }
    expectEqual("a file over the size limit is refused unread",
                sizeFailure, .tooLarge(bytes: ImportGuard.maxFileBytes + 1))
    expectEqual("a file at the size limit is read",
                (try? ImportGuard.read(sparseFile("limit.json", bytes: ImportGuard.maxFileBytes)))?.count,
                ImportGuard.maxFileBytes)

    // Device labels get the same treatment.
    let labels = DeviceRegistry(folder: scratchFolder())
    let incoming = [
        DeviceRecord(macKey: "AA-BB-CC-DD-EE-01", nickname: "Printer\u{0000}", lastIP: "192.168.1.40"),
        DeviceRecord(macKey: "not-a-mac", nickname: "Nope"),
        DeviceRecord(macKey: "aa:bb:cc:dd:ee:02", nickname: "Cam", categoryRaw: "rocketship", lastIP: "999.1.1.1"),
        DeviceRecord(macKey: "aa:bb:cc:dd:ee:03", nickname: "\u{0007}\u{202E}")
    ]
    if let raw = try? enc.encode(incoming) {
        expectEqual("only well-formed labels with something to say are imported",
                    labels.importJSON(raw), 2)
    }
    expectEqual("a label's address is normalised", labels.nickname(forMAC: "aa:bb:cc:dd:ee:01"), "Printer")
    expectEqual("an unknown type becomes unlabelled", labels.category(forMAC: "aa:bb:cc:dd:ee:02"), .unlabelled)
    expect("an impossible IP address is dropped", labels.record(forMAC: "aa:bb:cc:dd:ee:02")?.lastIP == nil)
    expect("a label that is empty once cleaned is refused", labels.record(forMAC: "aa:bb:cc:dd:ee:03") == nil)
}

// MARK: Neighbour cache parsing

/// One routing message laid out the way the kernel writes it, with a knob for
/// breaking each part.
private func routeMessage(ip: [UInt8] = [192, 168, 1, 20],
                          mac: [UInt8] = [0x00, 0x1b, 0x63, 0x11, 0x22, 0x33],
                          inetLength: UInt8 = 16,
                          nameLength: UInt8 = 0,
                          fitName: Bool = true,
                          addressLength: UInt8 = 6,
                          claimedLength: Int? = nil) -> [UInt8] {
    let header = MemoryLayout<rt_msghdr>.size
    let dataField = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
    let total = header + 16 + dataField + (fitName ? Int(nameLength) : 0) + 6
    var bytes = [UInt8](repeating: 0, count: total)

    let claimed = UInt16(claimedLength ?? total)
    let lengthField = MemoryLayout<rt_msghdr>.offset(of: \.rtm_msglen)!
    bytes[lengthField] = UInt8(claimed & 0xff)
    bytes[lengthField + 1] = UInt8(claimed >> 8)

    bytes[header] = inetLength
    bytes[header + 1] = UInt8(AF_INET)
    let addressField = header + MemoryLayout<sockaddr_inarp>.offset(of: \.sin_addr)!
    for (i, b) in ip.enumerated() { bytes[addressField + i] = b }

    let link = header + 16
    bytes[link] = UInt8(min(255, dataField + Int(nameLength) + 6))
    bytes[link + 1] = UInt8(AF_LINK)
    bytes[link + MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen)!] = nameLength
    bytes[link + MemoryLayout<sockaddr_dl>.offset(of: \.sdl_alen)!] = addressLength
    let macStart = link + dataField + Int(nameLength)
    if macStart + 6 <= total {
        for (i, b) in mac.enumerated() { bytes[macStart + i] = b }
    }
    return bytes
}

private func parseRoutes(_ bytes: [UInt8]) -> [ARPEntry] {
    bytes.withUnsafeBytes { ARPTable.parse($0) }
}

private func testRouteParsing() {
    let good = parseRoutes(routeMessage())
    expectEqual("a well-formed message is read", good.count, 1)
    expectEqual("its IP address is read", good.first?.ip, "192.168.1.20")
    expectEqual("its hardware address is read", good.first?.mac, "00:1b:63:11:22:33")
    expectEqual("an interface name is stepped over",
                parseRoutes(routeMessage(nameLength: 3)).first?.mac, "00:1b:63:11:22:33")

    expect("an empty buffer yields nothing", parseRoutes([]).isEmpty)
    expect("a header alone yields nothing",
           parseRoutes([UInt8](repeating: 0, count: MemoryLayout<rt_msghdr>.size)).isEmpty)
    expect("a length past the buffer stops the read", parseRoutes(routeMessage(claimedLength: 4096)).isEmpty)
    expect("a length shorter than a header stops the read", parseRoutes(routeMessage(claimedLength: 4)).isEmpty)
    expect("an address running past its message is skipped", parseRoutes(routeMessage(inetLength: 255)).isEmpty)
    expect("an interface name running past its message is skipped",
           parseRoutes(routeMessage(nameLength: 200, fitName: false)).isEmpty)
    for length: UInt8 in [0, 5, 7, 20] {
        expect("a hardware address of \(length) bytes is skipped",
               parseRoutes(routeMessage(addressLength: length)).isEmpty)
    }
    let mixed = routeMessage(inetLength: 255) + routeMessage(ip: [10, 0, 0, 7])
    expectEqual("a bad message does not stop the next", parseRoutes(mixed).map(\.ip), ["10.0.0.7"])
    let truncatedTail = routeMessage() + Array(routeMessage().prefix(20))
    expectEqual("a truncated final message is ignored", parseRoutes(truncatedTail).count, 1)

    // Random buffers, half with a plausible length so the inner checks run.
    // Seeded, so a failure reproduces.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return seed >> 33
    }
    let lengthField = MemoryLayout<rt_msghdr>.offset(of: \.rtm_msglen)!
    var survived = 0
    for _ in 0..<20_000 {
        let count = Int(next() % 400)
        var bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
        if count >= lengthField + 2, next() % 2 == 0 {
            let claimed = UInt16(truncatingIfNeeded: next() % UInt64(count + 1))
            bytes[lengthField] = UInt8(claimed & 0xff)
            bytes[lengthField + 1] = UInt8(claimed >> 8)
        }
        _ = parseRoutes(bytes)
        survived += 1
    }
    expectEqual("twenty thousand malformed buffers are read without a fault", survived, 20_000)
}

// MARK: Signal extremes

@MainActor
private func testRSSIExtremes() {
    let registry = APRegistry(folder: scratchFolder())
    let key = sample(rssi: -50).apKey
    registry.observe(key: key, sample: sample(rssi: -50))
    registry.observe(key: key, sample: sample(rssi: -62))
    expectEqual("the strongest reading is kept", registry.record(for: key)?.bestRSSI, -50)
    expectEqual("the weakest reading is kept", registry.record(for: key)?.worstRSSI, -62)

    // Zero is the interface saying it has no reading, not a perfect signal.
    registry.observe(key: key, sample: sample(rssi: 0))
    expectEqual("a zero reading does not become the best ever",
                registry.record(for: key)?.bestRSSI, -50)
    expectEqual("nor does it disturb the worst",
                registry.record(for: key)?.worstRSSI, -62)
    registry.forgetAll()
}

// MARK: Device address keys

@MainActor
private func testDeviceKeys() {
    expectEqual("uppercase MAC normalises",
                DeviceRegistry.normalise("AA:BB:CC:DD:EE:FF"), "aa:bb:cc:dd:ee:ff")
    expectEqual("dashed MAC normalises",
                DeviceRegistry.normalise("aa-bb-cc-dd-ee-ff"), "aa:bb:cc:dd:ee:ff")
    expectEqual("short octets are padded",
                DeviceRegistry.normalise("a:b:c:d:e:f"), "0a:0b:0c:0d:0e:0f")
    expectEqual("a malformed address is left alone rather than corrupted",
                DeviceRegistry.normalise("not-a-mac"), "not-a-mac")
}

// MARK: Device roles

@MainActor
private func testDeviceRoles() {
    var config = IPConfig()
    config.ipv4 = "192.168.1.50"
    config.subnetMask = "255.255.255.0"
    config.router = "192.168.1.1"
    config.dhcpServer = "192.168.1.5"
    config.dnsServers = ["192.168.1.1", "192.168.1.9"]

    expectEqual("this Mac is identified before anything else",
                DeviceRoleResolver.role(forMAC: "aa:bb:cc:dd:ee:01", ip: "192.168.1.50",
                                        config: config, bssid: nil, isSelf: true),
                .thisMac)

    expectEqual("the gateway address is the router",
                DeviceRoleResolver.role(forMAC: "aa:bb:cc:dd:ee:10", ip: "192.168.1.1",
                                        config: config, bssid: nil),
                .router)

    // The BSSID sits in the same vendor block, two addresses along: one chassis.
    // The prefix must be a real burned-in one, since adjacency between
    // software-assigned addresses proves nothing about shared hardware.
    expectEqual("a gateway adjacent to the BSSID is one box doing both jobs",
                DeviceRoleResolver.role(forMAC: "00:1b:63:dd:ee:10", ip: "192.168.1.1",
                                        config: config, bssid: "00:1b:63:dd:ee:12"),
                .routerAndAccessPoint)

    expectEqual("a distant BSSID does not merge the router and the access point",
                DeviceRoleResolver.role(forMAC: "00:1b:63:dd:ee:10", ip: "192.168.1.1",
                                        config: config, bssid: "11:22:33:44:55:66"),
                .router)

    expectEqual("adjacency between locally administered addresses infers nothing",
                DeviceRoleResolver.role(forMAC: "aa:bb:cc:dd:ee:10", ip: "192.168.1.1",
                                        config: config, bssid: "aa:bb:cc:dd:ee:12"),
                .router)

    expectEqual("a host matching the BSSID exactly is the access point",
                DeviceRoleResolver.role(forMAC: "AA:BB:CC:DD:EE:20", ip: "192.168.1.20",
                                        config: config, bssid: "aa:bb:cc:dd:ee:20"),
                .accessPoint)

    expectEqual("the lease issuer is the DHCP server",
                DeviceRoleResolver.role(forMAC: "aa:bb:cc:dd:ee:05", ip: "192.168.1.5",
                                        config: config, bssid: nil),
                .dhcpServer)

    expectEqual("a listed name server is the DNS server",
                DeviceRoleResolver.role(forMAC: "aa:bb:cc:dd:ee:09", ip: "192.168.1.9",
                                        config: config, bssid: nil),
                .dnsServer)

    expectEqual("anything else is just an observed device",
                DeviceRoleResolver.role(forMAC: "aa:bb:cc:dd:ee:63", ip: "192.168.1.99",
                                        config: config, bssid: nil),
                .device)

    expect("infrastructure sorts above ordinary hosts",
           DeviceRole.router.sortRank < DeviceRole.device.sortRank)
    expect("this Mac sorts to the very top",
           DeviceRole.thisMac.sortRank < DeviceRole.router.sortRank)
}

// MARK: Arrivals and departures

@MainActor
private func testDevicePresence() {
    let presence = DevicePresence()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let a = ARPEntry(ip: "192.168.1.10", mac: "aa:bb:cc:00:00:01", interfaceName: "en0")
    let b = ARPEntry(ip: "192.168.1.11", mac: "aa:bb:cc:00:00:02", interfaceName: "en0")

    presence.note([a], now: base)
    expect("the first read is a baseline, not an arrival",
           presence.sighting(forMAC: a.mac)?.arrivedWhileWatching == false)
    expectEqual("nothing has arrived yet", presence.arrivedCount, 0)

    presence.note([a, b], now: base.addingTimeInterval(5))
    expect("a device seen only in a later read arrived while watching",
           presence.sighting(forMAC: b.mac)?.arrivedWhileWatching == true)
    expectEqual("one arrival is counted", presence.arrivedCount, 1)

    // One missing read is a gap, not a departure: the cache expires idle
    // entries on its own schedule.
    presence.note([a], now: base.addingTimeInterval(10))
    expect("a single miss does not declare a device gone",
           presence.sighting(forMAC: b.mac)?.isPresent == true)
    expectEqual("no departures after one miss", presence.departedCount, 0)

    presence.note([a], now: base.addingTimeInterval(15))
    expect("two consecutive misses declare a device gone",
           presence.sighting(forMAC: b.mac)?.isPresent == false)
    expectEqual("one departure is counted", presence.departedCount, 1)
    expectEqual("the departed device is still described", presence.departed.count, 1)

    // Case differences in the cache must not create a second identity.
    presence.note([ARPEntry(ip: "192.168.1.10", mac: "AA:BB:CC:00:00:01", interfaceName: "en0")],
                  now: base.addingTimeInterval(20))
    expectEqual("a re-cased address is the same device", presence.sightings.count, 2)

    presence.reset(now: base.addingTimeInterval(25))
    expectEqual("a network change clears the history", presence.sightings.count, 0)
    expectEqual("a network change clears the read count", presence.readCount, 0)

    // Moving to another network takes what is already cached as the new
    // baseline, rather than waiting for a change that may never come.
    presence.rebaseline([a, b], now: base.addingTimeInterval(30))
    expectEqual("a rebaseline records what is already there", presence.sightings.count, 2)
    expectEqual("and counts as the first read", presence.readCount, 1)
    expectEqual("so nothing is reported as having arrived", presence.arrivedCount, 0)
    expect("devices are present after a rebaseline",
           presence.sighting(forMAC: a.mac)?.isPresent == true)
}

// MARK: Device labels stay local and deliberate

@MainActor
private func testDeviceRegistry() {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wifihigh5-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let registry = DeviceRegistry(folder: folder)
    let file = folder.appendingPathComponent("observed-devices.json")
    let mac = "AA:BB:CC:11:22:33"

    registry.saveNow()
    expect("an unlabelled network leaves no file behind",
           !FileManager.default.fileExists(atPath: file.path))

    registry.setNickname("Reception printer", forMAC: mac, currentIP: "192.168.1.40")
    expectEqual("the name is stored against the normalised address",
                registry.nickname(forMAC: "aa-bb-cc-11-22-33"), "Reception printer")

    registry.setCategory(.printer, forMAC: mac)
    expectEqual("the type is kept", registry.category(forMAC: mac), .printer)

    registry.saveNow()
    expect("a labelled device is written to disk",
           FileManager.default.fileExists(atPath: file.path))

    let reloaded = DeviceRegistry(folder: folder)
    expectEqual("labels survive a relaunch",
                reloaded.nickname(forMAC: mac), "Reception printer")
    expectEqual("types survive a relaunch", reloaded.category(forMAC: mac), .printer)

    // Clearing every field forgets the device rather than leaving a husk.
    reloaded.setNickname("", forMAC: mac)
    expect("clearing the name alone keeps a device that still has a type",
           reloaded.record(forMAC: mac) != nil)
    reloaded.setCategory(.unlabelled, forMAC: mac)
    expect("a device with nothing said about it is forgotten",
           reloaded.record(forMAC: mac) == nil)

    reloaded.saveNow()
    expect("forgetting the last label removes the file",
           !FileManager.default.fileExists(atPath: file.path))

    // Import must never overwrite names already on this Mac.
    let mine = DeviceRegistry(folder: folder)
    mine.setNickname("Mine", forMAC: mac)
    let theirs = DeviceRegistry(
        folder: folder.appendingPathComponent("other", isDirectory: true))
    theirs.setNickname("Theirs", forMAC: mac)
    theirs.setNickname("New device", forMAC: "aa:bb:cc:99:99:99")
    if let data = theirs.exportJSON() {
        expectEqual("only the unseen device is imported", mine.importJSON(data), 1)
        expectEqual("an existing name is never overwritten by an import",
                    mine.nickname(forMAC: mac), "Mine")
        expectEqual("the new device arrives with its name",
                    mine.nickname(forMAC: "aa:bb:cc:99:99:99"), "New device")
    } else {
        expect("labels can be exported", false)
    }
    expectEqual("a rejected file is reported rather than throwing",
                mine.importJSON(Data("not json".utf8)), nil)
}

// MARK: Device CSV

@MainActor
private func testDeviceCSV() {
    let device = ObservedDevice(
        mac: "aa:bb:cc:dd:ee:ff",
        ip: "192.168.1.40",
        role: .device,
        record: DeviceRecord(macKey: "aa:bb:cc:dd:ee:ff",
                             nickname: "Reception, printer",
                             notes: "Says \"out of paper\"",
                             categoryRaw: DeviceCategory.printer.rawValue),
        vendor: .known("Example Corp"),
        sighting: nil,
        isLocallyAdministered: false,
        isPresent: true)

    let csv = ReportBuilder.deviceCSV([device], networkName: "Acme-Corp")
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

    expect("the export says how the data was gathered",
           csv.contains("Passive read of this Mac's neighbour cache"))
    expect("a comma in a name cannot break the columns",
           csv.contains("\"Reception, printer\""))
    expect("a quote in a note is escaped rather than ending the field",
           csv.contains("\"\"out of paper\"\""))
    expect("the manufacturer is carried through", csv.contains("Example Corp"))
    expect("the type the user chose is carried through", csv.contains("Printer"))
    expect("the export states that nothing was scanned",
           csv.contains("No address was scanned or swept"))
    expect("the export states that nothing was asked of any device",
           csv.contains("Discovery,None"))
    expect("a suggested type is marked as inferred, not measured",
           csv.contains("Inferred from the manufacturer only"))
    expectEqual("six comment lines, one header and one device row",
                lines.filter { !$0.isEmpty }.count, 8)
}

// MARK: Device type inference

@MainActor
private func testDeviceClassifier() {
    // A maker of one kind of device narrows it usefully.
    expectEqual("a printer maker suggests a printer",
                DeviceClassifier.guess(vendor: "Hewlett Packard")?.category, .printer)
    expectEqual("that inference is offered as likely",
                DeviceClassifier.guess(vendor: "Canon Inc")?.strength, .likely)
    expectEqual("a camera maker suggests a camera",
                DeviceClassifier.guess(vendor: "Axis Communications AB")?.category, .camera)
    expectEqual("a wireless module maker suggests a small smart device",
                DeviceClassifier.guess(vendor: "Espressif Inc")?.category, .iot)
    expectEqual("an access point maker suggests network equipment",
                DeviceClassifier.guess(vendor: "Ubiquiti Networks Inc")?.category, .accessPoint)
    expectEqual("a provider gateway maker suggests a router",
                DeviceClassifier.guess(vendor: "WNC Corporation")?.category, .router)

    // Order matters: the enterprise arm builds switches, not printers, and the
    // longer name must be tested before the shorter one it contains.
    expectEqual("Hewlett Packard Enterprise is not read as a printer",
                DeviceClassifier.guess(vendor: "Hewlett Packard Enterprise")?.category,
                .networkSwitch)

    // Makers of everything must not have a type invented for them.
    expect("Apple is named but not typed",
           DeviceClassifier.guess(vendor: "Apple, Inc")?.category == nil)
    expectEqual("Apple is still described",
                DeviceClassifier.guess(vendor: "Apple, Inc")?.summary, "An Apple device")
    expectEqual("that is offered only as possible",
                DeviceClassifier.guess(vendor: "Apple, Inc")?.strength, .possible)
    expect("a radio supplier is named but not typed",
           DeviceClassifier.guess(vendor: "AzureWave Technology Inc")?.category == nil)

    // Silence is better than a guess with nothing behind it.
    expect("an unrecognised maker yields nothing",
           DeviceClassifier.guess(vendor: "Wuah, Inc") == nil)
    expect("no manufacturer yields nothing",
           DeviceClassifier.guess(vendor: nil) == nil)
}

// MARK: Discovery findings

@MainActor
private func testDiscoveryFindings() {
    var finding = DeviceFinding()
    expect("an empty finding is empty", finding.isEmpty)
    expect("an empty finding offers no name", finding.bestName == nil)

    finding.hostname = "printer.example.com"
    expect("a DNS name alone is enough to be non-empty", !finding.isEmpty)
    expectEqual("a DNS name is used when nothing was advertised",
                finding.bestName, "printer.example.com")

    finding.advertisedName = "Reception LaserJet"
    expectEqual("a name the device published for itself wins over DNS",
                finding.bestName, "Reception LaserJet")

    // A row must show a discovered name over anything this Mac worked out,
    // but never over a name the user chose.
    let base = ObservedDevice(
        mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.1.40", role: .device,
        record: nil, vendor: .known("Example Corp"), sighting: nil,
        isLocallyAdministered: false, isPresent: true, guess: nil, finding: finding)
    expectEqual("a discovered name names the row", base.displayName, "Reception LaserJet")
    expect("the row declares that it was obtained by asking", base.wasDiscovered)

    var named = base
    named.record = DeviceRecord(macKey: "aa:bb:cc:dd:ee:ff", nickname: "Front desk printer")
    expectEqual("the user's own name still wins", named.displayName, "Front desk printer")

    var untouched = base
    untouched.finding = nil
    expect("a row nothing was asked of does not claim otherwise", !untouched.wasDiscovered)
    expectEqual("and it falls back to what this Mac worked out",
                untouched.displayName, "Observed device")
}

// MARK: Device type from what the device itself says

@MainActor
private func testDeviceEvidence() {
    func finding(model: String? = nil,
                 services: Set<String> = [],
                 advertised: String? = nil,
                 hostname: String? = nil) -> DeviceFinding {
        DeviceFinding(advertisedName: advertised, model: model,
                      services: services, hostname: hostname)
    }

    // A published model is exact, and works even on a randomised address.
    expectEqual("an iPhone model identifies a phone",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(model: "iPhone14,2"),
                                       isLocallyAdministered: true)?.category,
                .phone)
    expectEqual("a MacBook model identifies a laptop",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(model: "MacBookPro18,3"))?.category,
                .laptop)
    expectEqual("a HomePod reports itself as an audio accessory",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(model: "AudioAccessory5,1"))?.category,
                .speaker)

    // What a device offers is nearly as good.
    expectEqual("advertising printing identifies a printer",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(services: ["Printing"]))?.category,
                .printer)
    expectEqual("audio without video is a speaker",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(services: ["AirPlay audio"]))?.category,
                .speaker)
    expectEqual("AirPlay video is a display",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(services: ["AirPlay", "AirPlay audio"]))?.category,
                .television)

    // The name a device answers to is weaker, but usually plain.
    expectEqual("a device called iphone is a phone",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(hostname: "iphone"),
                                       isLocallyAdministered: true)?.category,
                .phone)
    expectEqual("a domain on the name does not hide it",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(hostname: "iphone.lan"))?.category,
                .phone)
    expectEqual("a name is offered only as possible",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(hostname: "iphone"))?.strength,
                .possible)

    // Order: the device's own account beats anything worked out from its address.
    expectEqual("a published model outranks the manufacturer",
                DeviceClassifier.guess(vendor: "Hewlett Packard",
                                       finding: finding(model: "iPhone14,2"))?.category,
                .phone)
    // A Mac advertises AirPlay exactly as an Apple TV does, so the name has to
    // win, or every MacBook on the network is filed as a television.
    expectEqual("a MacBook advertising AirPlay is still a laptop",
                DeviceClassifier.guess(
                    vendor: "Apple, Inc",
                    finding: finding(model: "Mac14,2",
                                     services: ["AirPlay", "AirPlay audio"],
                                     advertised: "Alex's MacBook Air"))?.category,
                .laptop)
    expectEqual("a television advertising AirPlay is a television",
                DeviceClassifier.guess(
                    vendor: nil,
                    finding: finding(model: "AFTDCT31",
                                     services: ["AirPlay"],
                                     advertised: "Alex's TV"))?.category,
                .television)
    expectEqual("a bare Mac model narrows no further than a computer",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(model: "Mac14,3"))?.category,
                .desktop)
    expectEqual("and says so, rather than claiming to be sure",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(model: "Mac14,3"))?.strength,
                .possible)
    expectEqual("an advertised service still outranks the manufacturer",
                DeviceClassifier.guess(vendor: "Apple, Inc",
                                       finding: finding(services: ["Printing"]))?.category,
                .printer)

    // A randomised address rules out the registry and nothing else.
    expect("a randomised address with nothing else yields no type",
           DeviceClassifier.guess(vendor: "Apple, Inc",
                                  finding: nil,
                                  isLocallyAdministered: true) == nil)
    expectEqual("but the manufacturer still counts on a burned-in address",
                DeviceClassifier.guess(vendor: "Hewlett Packard",
                                       finding: nil,
                                       isLocallyAdministered: false)?.category,
                .printer)

    // The row picks its icon from whatever the guess settled on.
    let phone = ObservedDevice(
        mac: "1a:18:6b:ee:77:da", ip: "192.168.1.175", role: .device,
        record: nil, vendor: .randomised, sighting: nil,
        isLocallyAdministered: true, isPresent: true,
        guess: DeviceClassifier.guess(vendor: nil,
                                      finding: finding(hostname: "iphone"),
                                      isLocallyAdministered: true),
        finding: finding(hostname: "iphone"))
    expectEqual("a phone gets the phone glyph", phone.symbol, "iphone")
    expectEqual("and the row records where that came from",
                phone.guess?.source, .name)
    expect("a guess drawn from the name is not printed back under the name",
           phone.displayName.range(of: phone.guess?.summary ?? "zzz",
                                   options: .caseInsensitive) != nil)
    expectEqual("a published model is recorded as the device's own account",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(model: "iPhone14,2"))?.source,
                .model)
    expectEqual("an advertised service is recorded as such",
                DeviceClassifier.guess(vendor: nil,
                                       finding: finding(services: ["Printing"]))?.source,
                .services)
    expectEqual("a manufacturer inference is recorded as such",
                DeviceClassifier.guess(vendor: "Hewlett Packard")?.source,
                .manufacturer)

    var labelled = phone
    labelled.record = DeviceRecord(macKey: "1a:18:6b:ee:77:da",
                                   categoryRaw: DeviceCategory.printer.rawValue)
    expectEqual("a type the user set outranks every guess", labelled.symbol, "printer")
}

@main
@MainActor
struct TestRunner {
    static func main() {
        testSignalQuality()
        testNoiseHandling()
        testAPIdentity()
        testFormatting()
        testSurveyLegs()
        testExports()
        testRoundTrip()
        testHelpIndex()
        testRSSIExtremes()
        testChartScale()
        testCSVEncoder()
        testUntrustedText()
        testImportChecks()
        testRouteParsing()
        testSmoothCurve()
        testDeviceKeys()
        testDeviceRoles()
        testDevicePresence()
        testDeviceRegistry()
        testDeviceCSV()
        testDeviceClassifier()
        testDiscoveryFindings()
        testDeviceEvidence()
        if CommandLine.arguments.count > 1 {
            let databaseURL = URL(fileURLWithPath: CommandLine.arguments[1])
            testVendorLookup(databaseURL: databaseURL)
            testTopology(databaseURL: databaseURL)
        }

        if failures.isEmpty {
            print("✓ all \(checks) checks passed")
        } else {
            print("✗ \(failures.count) of \(checks) checks failed:")
            for f in failures { print("   • \(f)") }
            exit(1)
        }
    }
}

// MARK: Vendor lookup

@MainActor
private func testVendorLookup(databaseURL: URL) {
    let db = VendorDatabase(url: databaseURL)
    // Loading is asynchronous; give it a moment before asserting.
    let deadline = Date().addingTimeInterval(10)
    while !db.isReady, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    expect("database loaded", db.isReady)
    expect("database has a realistic number of blocks", db.recordCount > 40_000)

    expectEqual("resolves a registered vendor", db.lookup("00:00:0c:11:22:33"), .known("Cisco Systems, Inc"))
    expectEqual("resolves an Apple address", db.lookup("00:1b:63:11:22:33"), .known("Apple, Inc"))
    expectEqual("case and separators do not matter",
                db.lookup("00-1B-63-11-22-33"), .known("Apple, Inc"))

    // The locally-administered bit must win before any table is consulted.
    // These are constructed, not observed: 0x0a and 0x9a both carry the
    // locally-administered bit and no real device is named by either.
    expectEqual("randomised address is not attributed",
                db.lookup("0a:00:5e:00:53:07"), .randomised)
    expectEqual("another randomised address", db.lookup("9a:00:5e:00:53:1c"), .randomised)

    // 02 is set on the first octet of every locally administered address.
    expectEqual("locally administered bit detected",
                db.lookup("02:00:00:00:00:01"), .randomised)

    // 00:00:5E is the IANA block used by VRRP and related addresses. This checks that
    // reserved assignments resolve rather than falling through as unknown.
    if case .known(let iana) = db.lookup("00:00:5e:00:00:01") {
        expect("IANA reserved block resolves", iana.uppercased().contains("IANA"))
    } else {
        expect("IANA reserved block resolves", false)
    }
    expectEqual("malformed input does not crash", db.lookup("nonsense"), .unregistered)
    expectEqual("nil input", db.lookup(nil), .unregistered)

    expectEqual("vendor prefix extracted", db.prefix(of: "00:00:0c:11:22:33"), "00:00:0c")
}

// MARK: Hover help lookup

@MainActor
private func testHelpIndex() {
    // Each supported interface label must resolve to a help topic.
    let expected: [(String, String)] = [
        ("SNR", "Signal clarity (SNR)"),
        ("Signal (RSSI)", "Signal strength (RSSI)"),
        ("Noise floor", "Noise floor"),
        ("TX rate", "Transmit rate"),
        ("TX power", "Transmit power"),
        ("Band", "Band (2.4, 5 and 6 GHz)"),
        ("Channel width", "Channel width"),
        ("PHY mode", "PHY mode (Wi-Fi generation)"),
        ("Security", "Security"),
        ("Country", "Country code"),
        ("BSSID", "SSID and BSSID"),
        ("Private address", "Private Wi-Fi address"),
        ("Packet loss", "Gateway reachability test"),
        ("Variation", "Variation (stability)"),
        ("Vendor", "Hardware vendors")
    ]
    for (label, term) in expected {
        expectEqual("hover help resolves \(label)",
                    HelpIndex.topic(forLabel: label)?.term, term)
    }

    // Case and stray punctuation should not matter.
    expectEqual("lookup is case-insensitive",
                HelpIndex.topic(forLabel: "snr")?.term, "Signal clarity (SNR)")
    expectEqual("lookup tolerates a trailing colon",
                HelpIndex.topic(forLabel: "Noise floor:")?.term, "Noise floor")

    // Labels without an exact match must resolve to nothing.
    expect("unmapped label has no tooltip", HelpIndex.topic(forLabel: "Site") == nil)
    expect("empty label has no tooltip", HelpIndex.topic(forLabel: "") == nil)

    // Every alias must point at a topic that exists.
    let terms = Set(HelpContent.topics.map(\.term))
    for (_, term) in expected {
        expect("topic \(term) exists", terms.contains(term))
    }
}
