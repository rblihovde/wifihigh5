import Foundation
import CoreWLAN
import CoreLocation
import Combine

/// State of the Wi-Fi link at the last poll.
enum LinkStatus: Equatable {
    case connected
    case disconnected
    case poweredOff
    case noInterface

    var label: String {
        switch self {
        case .connected:   return "Connected"
        case .disconnected: return "Not associated"
        case .poweredOff:  return "Wi-Fi is off"
        case .noInterface: return "No Wi-Fi interface"
        }
    }
}

/// Publishes the Location Services state that macOS requires before it will
/// reveal the SSID and BSSID of the current network.
@MainActor
final class LocationGate: NSObject, ObservableObject {
    @Published var status: CLAuthorizationStatus = .notDetermined
    /// Set when the system refuses the request outright rather than prompting,
    /// which happens when Location Services is off or restricted by policy.
    @Published var deniedWithoutPrompt = false

    private var manager: CLLocationManager?

    override init() {
        super.init()
        let m = CLLocationManager()
        m.delegate = self
        manager = m
        status = m.authorizationStatus
    }

    var isAuthorized: Bool {
        status == .authorizedAlways || status == .authorized
    }

    func request() {
        deniedWithoutPrompt = false
        guard status == .notDetermined else {
            openSettings()
            return
        }
        manager?.requestWhenInUseAuthorization()

        // CoreWLAN gates the SSID on the authorization status alone, so this app
        // never needs a location fix and never keeps one. The single start/stop
        // below exists only to force the system to evaluate the request now: when
        // it refuses without prompting it reports kCLErrorDenied straight away,
        // which is what lets the UI say "blocked by policy" rather than leaving
        // the operator waiting for a prompt that is never coming. Once access is
        // granted this is skipped entirely.
        guard status == .notDetermined else { return }
        manager?.startUpdatingLocation()
        manager?.stopUpdatingLocation()
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        NSWorkspace.shared.open(url)
    }
}

extension LocationGate: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.status = s
            self.deniedWithoutPrompt = s == .restricted
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as NSError).code == CLError.denied.rawValue else { return }
        let s = manager.authorizationStatus
        Task { @MainActor in
            // A denial while still "not determined" means no prompt was shown.
            if s == .notDetermined { self.deniedWithoutPrompt = true }
        }
    }
}

import AppKit

/// Polls the Wi-Fi interface and keeps the rolling history the UI graphs.
///
/// Reads only the state of the link this Mac has already joined. It sends no
/// frames of its own and does not scan unless explicitly asked to.
@MainActor
final class WiFiMonitor: ObservableObject {
    @Published private(set) var samples: [WiFiSample] = []
    @Published private(set) var current: WiFiSample?
    @Published private(set) var roamEvents: [RoamEvent] = []
    @Published private(set) var status: LinkStatus = .disconnected
    @Published private(set) var sessionStart = Date()
    @Published private(set) var currentAPSince: Date?

    /// Places marked during the current session.
    @Published private(set) var waypoints: [Waypoint] = []
    /// Non-nil while a walkthrough is being recorded for later export.
    @Published private(set) var recording: Recording?

    /// Audible warning while walking, so the operator can watch the building
    /// instead of the screen.
    @Published var alertEnabled = false
    @Published var alertThreshold = -70
    private var alertLatched = false

    @Published var isRunning = true
    @Published var interval: Double = 1.0 {
        didSet { if isRunning { restartTimer() } }
    }

    private let historyDuration: TimeInterval = 3600
    /// Safety ceiling for the fastest supported interval, plus some headroom.
    private let maximumSampleCount = 7500

    private var timer: Timer?
    private var currentKey: APKey?
    private var lastConnectedKey: APKey?
    private var lastConnectedSample: WiFiSample?
    private var disconnectedSince: Date?
    private var pollInFlight = false
    private let pollQueue = DispatchQueue(label: "wifi.poll", qos: .utility)
    private unowned let registry: APRegistry

    init(registry: APRegistry) {
        self.registry = registry
        start()
        observeSleepWake()
    }

    /// Sampling stops while the Mac is asleep. The timer recovers on its own,
    /// but waiting up to a full interval after wake leaves an avoidable hole in
    /// a walkthrough, so resume immediately instead. The resulting gap in the
    /// series is detected from the sample timestamps and drawn as a break.
    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.timer?.invalidate()
                self.timer = nil
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.restartTimer()
                self.poll()
            }
        }
    }

    // MARK: Control

    func start() {
        isRunning = true
        restartTimer()
        poll()
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func toggle() { isRunning ? pause() : start() }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Common mode keeps sampling steady while menus or scrollers are tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// An in-progress walkthrough.
    ///
    /// Kept separate from the live buffer because that one is deliberately
    /// capped for chart performance, while a recording must retain every
    /// reading taken for the whole walk.
    struct Recording {
        var name: String
        var site: String
        var started: Date
        var samples: [WiFiSample] = []
        var roamEvents: [RoamEvent] = []
    }

    /// Twelve hours at one second, an upper bound so a forgotten recording
    /// cannot grow without limit.
    private let maximumRecordedSamples = 43_200
    /// Transitions are far rarer than samples, but a client flapping between
    /// two access points can produce them steadily for hours, and this is the
    /// one series that had no ceiling.
    private let maximumRoamEvents = 2_000

    var isRecording: Bool { recording != nil }

    func startRecording(name: String, site: String) {
        recording = Recording(name: name, site: site, started: Date())
    }

    func cancelRecording() { recording = nil }

    /// Ends the walkthrough and returns it for saving. Waypoints dropped during
    /// the recording window travel with it.
    func finishRecording() -> SurveySession? {
        guard let r = recording else { return nil }
        recording = nil
        let ended = Date()
        guard !r.samples.isEmpty else { return nil }
        return SurveySession(
            name: r.name,
            site: r.site,
            started: r.started,
            ended: ended,
            sampleInterval: interval,
            samples: r.samples,
            roamEvents: r.roamEvents,
            waypoints: waypoints.filter { $0.time >= r.started && $0.time <= ended }
        )
    }

    // MARK: Waypoints

    /// Marks the current moment. The caller supplies the label afterwards, but
    /// the timestamp and reading are captured here so they describe where the
    /// operator actually was when the shortcut fired.
    @discardableResult
    func addWaypoint(label: String, note: String = "", at time: Date = Date()) -> Waypoint {
        let nearest = samples.last
        let w = Waypoint(time: time, label: label, note: note,
                         rssi: nearest?.rssi, snr: nearest?.snr,
                         apKeyRaw: nearest?.apKey.raw)
        waypoints.append(w)
        waypoints.sort { $0.time < $1.time }
        return w
    }

    func updateWaypoint(_ waypoint: Waypoint) {
        guard let i = waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
        waypoints[i] = waypoint
    }

    func removeWaypoint(id: UUID) {
        waypoints.removeAll { $0.id == id }
    }

    /// Labels used recently, offered for one-click reuse while walking.
    var recentWaypointLabels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for w in waypoints.reversed() where !w.label.isEmpty && !seen.contains(w.label) {
            seen.insert(w.label)
            out.append(w.label)
            if out.count == 6 { break }
        }
        return out
    }

    func clearSession() {
        samples.removeAll()
        roamEvents.removeAll()
        waypoints.removeAll()
        recording = nil
        alertLatched = false
        sessionStart = Date()
        currentKey = nil
        lastConnectedKey = nil
        lastConnectedSample = nil
        disconnectedSince = nil
        currentAPSince = nil
        if isRunning { poll() }
    }

    #if DEBUG
    /// Deterministic input for previews and visual regression checks. This is
    /// excluded from release builds and never appears in the shipped app.
    func seedPreview(_ previewSamples: [WiFiSample]) {
        timer?.invalidate()
        timer = nil
        isRunning = true
        samples.removeAll()
        roamEvents.removeAll()
        current = nil
        currentKey = nil
        lastConnectedKey = nil
        lastConnectedSample = nil
        disconnectedSince = nil
        sessionStart = previewSamples.first?.time ?? Date()
        for sample in previewSamples {
            ingest(Reading(status: .connected, sample: sample))
        }
    }
    #endif

    // MARK: Polling

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        pollQueue.async { [weak self] in
            let reading = Self.readInterface()
            Task { @MainActor in
                guard let self else { return }
                self.pollInFlight = false
                self.ingest(reading)
            }
        }
    }

    private struct Reading {
        var status: LinkStatus
        var sample: WiFiSample?
    }

    /// Reads CoreWLAN off the main thread; every call here is a driver query.
    private nonisolated static func readInterface() -> Reading {
        guard let i = CWWiFiClient.shared().interface() else {
            return Reading(status: .noInterface, sample: nil)
        }
        guard i.powerOn() else { return Reading(status: .poweredOff, sample: nil) }
        guard let channel = i.wlanChannel(), i.interfaceMode() == .station else {
            return Reading(status: .disconnected, sample: nil)
        }
        let s = WiFiSample(
            time: Date(),
            ssid: i.ssid(),
            bssid: i.bssid(),
            rssi: i.rssiValue(),
            noise: i.noiseMeasurement(),
            txRate: i.transmitRate(),
            txPower: i.transmitPower(),
            channel: channel.channelNumber,
            channelWidthRaw: channel.channelWidth.rawValue,
            bandRaw: channel.channelBand.rawValue,
            phyRaw: i.activePHYMode().rawValue,
            securityRaw: i.security().rawValue,
            countryCode: i.countryCode(),
            interfaceName: i.interfaceName ?? "en0",
            hardwareAddress: i.hardwareAddress()
        )
        return Reading(status: .connected, sample: s)
    }

    private func ingest(_ reading: Reading) {
        let wasConnected = status == .connected
        status = reading.status

        guard let sample = reading.sample else {
            if wasConnected { disconnectedSince = Date() }
            current = nil
            currentKey = nil
            currentAPSince = nil
            return
        }

        let key = sample.apKey
        if currentKey != key {
            let reason: RoamEvent.Reason
            let fromKey: APKey?
            let previous: WiFiSample?
            if currentKey == nil, disconnectedSince != nil, let lastConnectedKey {
                reason = .reconnect
                fromKey = lastConnectedKey
                previous = lastConnectedSample
            } else if currentKey == nil {
                reason = .initialAssociation
                fromKey = nil
                previous = nil
            } else if let current, !current.apKey.isPreciseIdentity,
                      key.isPreciseIdentity, current.channel == sample.channel,
                      current.bandRaw == sample.bandRaw {
                // Location access can reveal the BSSID between two polls. That
                // is an identity upgrade, not evidence that the Mac roamed.
                reason = .identityResolved
                fromKey = currentKey
                previous = current
            } else if key.isPreciseIdentity {
                reason = .bssidChange
                fromKey = currentKey
                previous = current
            } else {
                reason = .channelChange
                fromKey = currentKey
                previous = current
            }
            let event = RoamEvent(
                time: sample.time,
                fromKey: fromKey,
                toKey: key,
                fromRSSI: previous?.rssi,
                toRSSI: sample.rssi,
                fromChannel: previous?.channel,
                toChannel: sample.channel,
                reason: reason
            )
            roamEvents.append(event)
            if roamEvents.count > maximumRoamEvents {
                roamEvents.removeFirst(roamEvents.count - maximumRoamEvents)
            }
            recording?.roamEvents.append(event)
            if let count = recording?.roamEvents.count, count > maximumRoamEvents {
                recording?.roamEvents.removeFirst(count - maximumRoamEvents)
            }
            currentKey = key
            currentAPSince = sample.time
        }

        registry.observe(key: key, sample: sample)
        disconnectedSince = nil
        lastConnectedKey = key
        lastConnectedSample = sample
        current = sample
        samples.append(sample)
        captureForRecording(sample)
        evaluateAlert(for: sample)
        let cutoff = sample.time.addingTimeInterval(-historyDuration)
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        if samples.count > maximumSampleCount {
            samples.removeFirst(samples.count - maximumSampleCount)
        }
    }

    private func captureForRecording(_ sample: WiFiSample) {
        guard recording != nil else { return }
        recording?.samples.append(sample)
        if let count = recording?.samples.count, count > maximumRecordedSamples {
            recording?.samples.removeFirst(count - maximumRecordedSamples)
        }
    }

    /// Sounds once when the signal drops through the threshold, and re-arms
    /// only after it recovers by a few dB. Without that margin a reading
    /// hovering on the line would chirp continuously.
    private func evaluateAlert(for sample: WiFiSample) {
        guard alertEnabled else { alertLatched = false; return }
        if sample.rssi < alertThreshold, !alertLatched {
            alertLatched = true
            NSSound(named: "Submarine")?.play()
        } else if sample.rssi > alertThreshold + 3 {
            alertLatched = false
        }
    }

    // MARK: Derived statistics

    var currentKeyValue: APKey? { currentKey }

    /// Samples inside the trailing window, used by the chart and the stats strip.
    func samples(inLast window: TimeInterval?) -> [WiFiSample] {
        guard let window else { return samples }
        let cutoff = historyReferenceDate.addingTimeInterval(-window)
        guard let idx = samples.firstIndex(where: { $0.time >= cutoff }) else { return [] }
        return Array(samples[idx...])
    }

    /// Pausing freezes the visible history instead of letting it slide offscreen.
    var historyReferenceDate: Date {
        isRunning ? Date() : (samples.last?.time ?? Date())
    }

    struct Stats {
        var min: Int, max: Int, avg: Int, count: Int
        var jitter: Int
    }

    func stats(inLast window: TimeInterval?) -> Stats? {
        let s = samples(inLast: window)
        guard !s.isEmpty else { return nil }
        let values = s.map(\.rssi)
        let mn = values.min()!, mx = values.max()!
        let avg = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        // Mean absolute deviation: a readable stand-in for signal steadiness.
        let jitter = Int((values.map { abs(Double($0 - avg)) }.reduce(0, +) / Double(values.count)).rounded())
        return Stats(min: mn, max: mx, avg: avg, count: values.count, jitter: jitter)
    }

    var sessionDuration: TimeInterval { Date().timeIntervalSince(sessionStart) }

    var timeOnCurrentAP: TimeInterval? {
        currentAPSince.map { Date().timeIntervalSince($0) }
    }

    /// Distinct APs seen during this session, most recent first.
    var sessionAPKeys: [APKey] {
        var seen = Set<String>()
        var out: [APKey] = []
        for e in roamEvents.reversed() where !seen.contains(e.toKey.raw) {
            seen.insert(e.toKey.raw)
            out.append(e.toKey)
        }
        return out
    }

    // MARK: Export

    func exportCSV() -> String {
        var rows = ["timestamp,ssid,bssid,ap_nickname,rssi_dbm,noise_dbm,snr_db,channel,band,width,phy_mode,security,tx_rate_mbps,quality"]
        for s in samples {
            let name = registry.nickname(for: s.apKey) ?? ""
            let cols: [String] = [
                Fmt.stamp.string(from: s.time),
                csvEscape(s.ssid ?? ""),
                s.bssid ?? "",
                csvEscape(name),
                String(s.rssi), s.validNoise.map(String.init) ?? "", s.snr.map(String.init) ?? "",
                String(s.channel), s.band.label, channelWidthLabel(s.channelWidthRaw),
                phyModeLabel(s.phyRaw), csvEscape(securityLabel(s.securityRaw)),
                String(format: "%.0f", s.txRate), s.quality.label
            ]
            rows.append(cols.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func csvEscape(_ input: String) -> String {
        var s = input
        // SSIDs and nicknames are untrusted text. Prevent spreadsheet apps from
        // treating a leading character as a formula when the CSV is opened.
        if let first = s.first, "=+-@\t\r".contains(first) { s = "'" + s }
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else {
            return s
        }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
