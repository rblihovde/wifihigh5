import Foundation
import Combine

/// A completed walkthrough: every reading taken, the transitions seen, and the
/// places the operator marked along the way.
struct SurveySession: Identifiable, Codable {
    var id = UUID()
    var name: String
    var site: String
    var started: Date
    var ended: Date
    var sampleInterval: Double
    var samples: [WiFiSample]
    var roamEvents: [RoamEvent]
    var waypoints: [Waypoint]
    var notes: String = ""

    var duration: TimeInterval { ended.timeIntervalSince(started) }

    /// Distinct access points that served the link during the walk.
    var apKeys: [APKey] {
        var seen = Set<String>()
        var out: [APKey] = []
        for s in samples where !seen.contains(s.apKey.raw) {
            seen.insert(s.apKey.raw)
            out.append(s.apKey)
        }
        return out
    }

    var index: SurveyIndexEntry {
        let values = samples.map(\.rssi)
        return SurveyIndexEntry(
            id: id, name: name, site: site, started: started, ended: ended,
            sampleCount: samples.count,
            waypointCount: waypoints.count,
            apCount: apKeys.count,
            worstRSSI: values.min(),
            averageRSSI: values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        )
    }

    /// Readings taken between one waypoint and the next, which is how a
    /// Reports group these readings by place instead of by second.
    func leg(for waypoint: Waypoint) -> [WiFiSample] {
        let ordered = waypoints.sorted { $0.time < $1.time }
        guard let i = ordered.firstIndex(where: { $0.id == waypoint.id }) else { return [] }
        let start = waypoint.time
        let end = i + 1 < ordered.count ? ordered[i + 1].time : ended
        return samples.filter { $0.time >= start && $0.time < end }
    }
}

/// Lightweight summary so the survey list never loads full sample data.
struct SurveyIndexEntry: Identifiable, Codable {
    var id: UUID
    var name: String
    var site: String
    var started: Date
    var ended: Date
    var sampleCount: Int
    var waypointCount: Int
    var apCount: Int
    var worstRSSI: Int?
    var averageRSSI: Int?

    var duration: TimeInterval { ended.timeIntervalSince(started) }
}

/// Saved walkthroughs on disk. Local-only, like everything else this app keeps.
@MainActor
final class SurveyStore: ObservableObject {
    @Published private(set) var entries: [SurveyIndexEntry] = []

    private let folder: URL
    private let indexURL: URL

    init() {
        folder = APRegistry.folderURL.appendingPathComponent("Surveys", isDirectory: true)
        indexURL = folder.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        loadIndex()
    }

    var storeLocation: String { folder.path }

    private func fileURL(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? Self.decoder().decode([SurveyIndexEntry].self, from: data) else { return }
        entries = list.sorted { $0.started > $1.started }
    }

    private func saveIndex() {
        guard let data = try? Self.encoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    @discardableResult
    func save(_ session: SurveySession) -> Bool {
        guard let data = try? Self.encoder().encode(session) else { return false }
        do {
            try data.write(to: fileURL(for: session.id), options: .atomic)
        } catch {
            return false
        }
        entries.removeAll { $0.id == session.id }
        entries.append(session.index)
        entries.sort { $0.started > $1.started }
        saveIndex()
        return true
    }

    func load(id: UUID) -> SurveySession? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.decoder().decode(SurveySession.self, from: data)
    }

    /// Reads and decodes off the main thread. A long walkthrough holds tens of
    /// thousands of samples, and decoding that inline visibly stalls the window.
    func load(id: UUID) async -> SurveySession? {
        let url = fileURL(for: id)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil); return
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                continuation.resume(returning: try? decoder.decode(SurveySession.self, from: data))
            }
        }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        entries.removeAll { $0.id == id }
        saveIndex()
    }

    func rename(id: UUID, to name: String) {
        guard var session = load(id: id) else { return }
        session.name = name
        save(session)
    }
}
