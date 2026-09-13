import Foundation
import SwiftUI

/// Everything the app remembers about one access point, across launches.
struct APRecord: Codable, Identifiable {
    var keyRaw: String
    var nickname: String = ""
    var notes: String = ""
    var colorOverride: Int?
    var firstSeen: Date = Date()
    var lastSeen: Date = Date()
    var lastSSID: String?
    var lastChannel: Int?
    var lastBandRaw: Int?
    var bestRSSI: Int?
    var worstRSSI: Int?
    /// Site label, e.g. the client or floor where this AP lives.
    var site: String = ""

    var id: String { keyRaw }
    var key: APKey { APKey(raw: keyRaw) }

    var color: Color {
        if let i = colorOverride, APPalette.colors.indices.contains(i) { return APPalette.colors[i] }
        return key.color
    }

    var hasNickname: Bool { !nickname.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Local-only store of AP nicknames and history.
///
/// Stored as JSON under Application Support. The app does not transmit this data.
@MainActor
final class APRegistry: ObservableObject {
    @Published private(set) var records: [String: APRecord] = [:]
    @Published private(set) var persistenceError: String?

    private let fileURL: URL
    private var savePending = false
    private var lastSave = Date.distantPast
    private var canPersist = true
    /// Longest an unsaved change may sit before it is flushed.
    private let saveInterval: TimeInterval = 5

    static let folderURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WifiHigh5", isDirectory: true)
    }()

    /// The folder can be overridden so tests never touch the real registry.
    init(folder: URL? = nil) {
        let base = folder ?? Self.folderURL
        fileURL = base.appendingPathComponent("access-points.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            canPersist = false
            persistenceError = "The local data folder could not be created: \(error.localizedDescription)"
        }
        load()
    }

    // MARK: Reads

    func record(for key: APKey) -> APRecord? { records[key.raw] }

    func nickname(for key: APKey) -> String? {
        guard let r = records[key.raw], r.hasNickname else { return nil }
        return r.nickname
    }

    func color(for key: APKey) -> Color { records[key.raw]?.color ?? key.color }

    /// Name shown wherever this AP appears: nickname if set, otherwise a
    /// readable description of the radio it is using.
    func displayName(for key: APKey, fallbackChannel: Int? = nil, fallbackBand: Int? = nil) -> String {
        if let n = nickname(for: key) { return n }
        if let b = key.bssidValue { return Fmt.shortMAC(b) }
        let r = records[key.raw]
        let ch = fallbackChannel ?? r?.lastChannel
        let band = bandLabel(fallbackBand ?? r?.lastBandRaw ?? 0)
        if let ch { return "Ch \(ch) · \(band.short)" }
        return "Unknown AP"
    }

    /// Palette slot for an AP, so exports can reproduce the on-screen colour.
    func colorIndexHint(for key: APKey) -> Int {
        guard let index = records[key.raw]?.colorOverride,
              APPalette.colors.indices.contains(index) else { return key.colorIndex }
        return index
    }

    var allRecords: [APRecord] {
        records.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: Writes

    /// Records that we are currently associated with this AP.
    func observe(key: APKey, sample: WiFiSample) {
        var r = records[key.raw] ?? APRecord(keyRaw: key.raw, firstSeen: sample.time)
        r.lastSeen = sample.time
        r.lastSSID = sample.ssid ?? r.lastSSID
        r.lastChannel = sample.channel
        r.lastBandRaw = sample.bandRaw
        // A Wi-Fi RSSI is always negative. Zero is what the interface returns
        // when it has no reading at all, and recording that as a best-ever
        // figure claims a perfect signal that never happened.
        if sample.rssi < 0 {
            r.bestRSSI = max(r.bestRSSI ?? Int.min, sample.rssi)
            r.worstRSSI = min(r.worstRSSI ?? Int.max, sample.rssi)
        }
        records[key.raw] = r
        scheduleSave()
    }

    func setNickname(_ name: String, for key: APKey) {
        var r = records[key.raw] ?? APRecord(keyRaw: key.raw)
        r.nickname = name.trimmingCharacters(in: .whitespacesAndNewlines)
        records[key.raw] = r
        scheduleSave()
    }

    func setNotes(_ notes: String, for key: APKey) {
        var r = records[key.raw] ?? APRecord(keyRaw: key.raw)
        r.notes = notes
        records[key.raw] = r
        scheduleSave()
    }

    func setSite(_ site: String, for key: APKey) {
        var r = records[key.raw] ?? APRecord(keyRaw: key.raw)
        r.site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        records[key.raw] = r
        scheduleSave()
    }

    func setColor(_ index: Int?, for key: APKey) {
        var r = records[key.raw] ?? APRecord(keyRaw: key.raw)
        r.colorOverride = index
        records[key.raw] = r
        scheduleSave()
    }

    func forget(key: APKey) {
        records.removeValue(forKey: key.raw)
        scheduleSave()
    }

    func forgetAll() {
        records.removeAll()
        scheduleSave()
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: fileURL)
            let list = try dec.decode([APRecord].self, from: data)
            var loaded: [String: APRecord] = [:]
            for record in list {
                if let existing = loaded[record.keyRaw], existing.lastSeen > record.lastSeen { continue }
                loaded[record.keyRaw] = Self.repaired(record)
            }
            records = loaded
        } catch {
            // Do not overwrite a file we failed to understand. The Diagnostics
            // view points the user to it so it can be backed up or replaced.
            canPersist = false
            persistenceError = "Saved access point data could not be read: \(error.localizedDescription)"
        }
    }

    /// Throttles the frequent `observe` writes.
    ///
    /// This is not a debounce. `observe` fires on every poll, so a restarting
    /// timer would continue to move the save deadline and would never write.
    /// A pending save keeps its deadline no matter how many changes follow.
    private func scheduleSave() {
        guard canPersist else { return }
        guard !savePending else { return }
        savePending = true
        let delay = Swift.max(0, saveInterval - Date().timeIntervalSince(lastSave))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.savePending = false
            self.saveNow()
        }
    }

    func saveNow() {
        guard canPersist else { return }
        lastSave = Date()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(Array(records.values))
            try data.write(to: fileURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Access point data could not be saved: \(error.localizedDescription)"
        }
    }

    var storeLocation: String { fileURL.path }

    // MARK: Import / export of the nickname map

    func exportJSON() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(Array(records.values))
    }

    /// Decodes and checks an export without touching the registry, so it can
    /// run away from the main thread and a rejected file changes nothing.
    nonisolated static func decodeImport(_ data: Data) throws -> [APRecord] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([APRecord].self, from: data) else {
            throw ImportGuard.Failure.notAnExport
        }
        guard list.count <= ImportGuard.maxRecords else {
            throw ImportGuard.Failure.tooManyRecords(list.count)
        }
        return list.compactMap(validatedImport)
    }

    /// One imported record, corrected where it can be and dropped where it
    /// cannot. A file can hold any value its format allows, including ones
    /// this app would never write.
    nonisolated static func validatedImport(_ record: APRecord) -> APRecord? {
        guard APKey.isWellFormed(record.keyRaw) else { return nil }
        var r = repaired(record)
        r.nickname = UntrustedText.clean(r.nickname, limit: ImportGuard.maxNameLength)
        r.site = UntrustedText.clean(r.site, limit: ImportGuard.maxSiteLength)
        r.notes = UntrustedText.clean(r.notes, limit: ImportGuard.maxNotesLength, allowNewlines: true)
        r.lastSSID = r.lastSSID.map { UntrustedText.clean($0, limit: 64) }
        return r
    }

    /// Values that are wrong whatever their source. Applied to what is read
    /// back from disk as well, so a bad value saved before this check existed
    /// cannot go on crashing a report.
    nonisolated static func repaired(_ record: APRecord) -> APRecord {
        var r = record
        if let index = r.colorOverride, !APPalette.colors.indices.contains(index) {
            r.colorOverride = nil
        }
        let plausible = -120...(-1)
        if let v = r.bestRSSI, !plausible.contains(v) { r.bestRSSI = nil }
        if let v = r.worstRSSI, !plausible.contains(v) { r.worstRSSI = nil }
        if let c = r.lastChannel, !(1...233).contains(c) { r.lastChannel = nil }
        let now = Date()
        if r.firstSeen > now { r.firstSeen = now }
        if r.lastSeen > now { r.lastSeen = now }
        return r
    }

    /// Imports a file already read and decoded. Returns nil for a file that is
    /// not an export.
    @discardableResult
    func importJSON(_ data: Data) -> Int? {
        guard let list = try? Self.decodeImport(data) else { return nil }
        return merge(list)
    }

    /// Merges checked records in. Existing user-entered fields win, while empty
    /// auto-created records are filled from the import.
    @discardableResult
    func merge(_ list: [APRecord]) -> Int {
        var changed = 0
        for incoming in list {
            guard var existing = records[incoming.keyRaw] else {
                records[incoming.keyRaw] = incoming
                changed += 1
                continue
            }

            var didChange = false
            if !existing.hasNickname && incoming.hasNickname {
                existing.nickname = incoming.nickname; didChange = true
            }
            if existing.site.isEmpty && !incoming.site.isEmpty {
                existing.site = incoming.site; didChange = true
            }
            if existing.notes.isEmpty && !incoming.notes.isEmpty {
                existing.notes = incoming.notes; didChange = true
            }
            if existing.colorOverride == nil, incoming.colorOverride != nil {
                existing.colorOverride = incoming.colorOverride; didChange = true
            }

            existing.firstSeen = Swift.min(existing.firstSeen, incoming.firstSeen)
            if incoming.lastSeen > existing.lastSeen {
                existing.lastSeen = incoming.lastSeen
                existing.lastSSID = incoming.lastSSID ?? existing.lastSSID
                existing.lastChannel = incoming.lastChannel ?? existing.lastChannel
                existing.lastBandRaw = incoming.lastBandRaw ?? existing.lastBandRaw
            }
            if let incomingBest = incoming.bestRSSI {
                existing.bestRSSI = Swift.max(existing.bestRSSI ?? Int.min, incomingBest)
            }
            if let incomingWorst = incoming.worstRSSI {
                existing.worstRSSI = Swift.min(existing.worstRSSI ?? Int.max, incomingWorst)
            }

            records[incoming.keyRaw] = existing
            if didChange { changed += 1 }
        }
        canPersist = true
        saveNow()
        return changed
    }
}
