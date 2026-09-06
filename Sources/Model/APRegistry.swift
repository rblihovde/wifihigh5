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

    init() {
        fileURL = Self.folderURL.appendingPathComponent("access-points.json")
        do {
            try FileManager.default.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)
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
        records[key.raw]?.colorOverride ?? key.colorIndex
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
        r.bestRSSI = max(r.bestRSSI ?? Int.min, sample.rssi)
        r.worstRSSI = min(r.worstRSSI ?? Int.max, sample.rssi)
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
                loaded[record.keyRaw] = record
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

    /// Merges an exported map in. Existing user-entered fields win, while empty
    /// auto-created records are filled from the import.
    @discardableResult
    func importJSON(_ data: Data) -> Int? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([APRecord].self, from: data) else { return nil }
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
