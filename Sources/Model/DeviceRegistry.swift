import Foundation
import SwiftUI

/// What a technician has decided a device on the client network actually is.
///
/// Nothing here is detected. The app cannot tell a printer from a camera
/// without probing them, which it does not do, so this is a label the person
/// using the app applies from their own knowledge of the site.
enum DeviceCategory: String, Codable, CaseIterable, Identifiable {
    case unlabelled
    case router
    case accessPoint
    case networkSwitch
    case printer
    case camera
    case phone
    case tablet
    case laptop
    case desktop
    case television
    case server
    case storage
    case voip
    case iot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unlabelled:    return "Unlabelled"
        case .router:        return "Router"
        case .accessPoint:   return "Access point"
        case .networkSwitch: return "Switch"
        case .printer:       return "Printer"
        case .camera:        return "Camera"
        case .phone:         return "Phone"
        case .tablet:        return "Tablet"
        case .laptop:        return "Laptop"
        case .desktop:       return "Desktop"
        case .television:    return "TV or display"
        case .server:        return "Server"
        case .storage:       return "Storage"
        case .voip:          return "Desk phone"
        case .iot:           return "Sensor or controller"
        }
    }

    var symbol: String {
        switch self {
        case .unlabelled:    return "questionmark.circle"
        case .router:        return "wifi.router"
        case .accessPoint:   return "dot.radiowaves.up.forward"
        case .networkSwitch: return "rectangle.connected.to.line.below"
        case .printer:       return "printer"
        case .camera:        return "video"
        case .phone:         return "iphone"
        case .tablet:        return "ipad"
        case .laptop:        return "laptopcomputer"
        case .desktop:       return "desktopcomputer"
        case .television:    return "tv"
        case .server:        return "server.rack"
        case .storage:       return "externaldrive"
        case .voip:          return "phone"
        case .iot:           return "sensor"
        }
    }
}

/// A label the user has deliberately attached to one device.
struct DeviceRecord: Codable, Identifiable {
    var macKey: String
    var nickname: String = ""
    var notes: String = ""
    var categoryRaw: String = DeviceCategory.unlabelled.rawValue
    /// Kept only so a renamed device can still be recognised after its lease
    /// changes. Never used to contact anything.
    var lastIP: String?
    var lastSeen: Date = Date()
    var created: Date = Date()

    var id: String { macKey }

    var category: DeviceCategory {
        DeviceCategory(rawValue: categoryRaw) ?? .unlabelled
    }

    var hasNickname: Bool {
        !nickname.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True when the user has actually said something about this device.
    ///
    /// The store writes only these. A device the user never labelled leaves no
    /// trace on disk after the app quits.
    var isDeliberate: Bool {
        hasNickname
            || !notes.trimmingCharacters(in: .whitespaces).isEmpty
            || category != .unlabelled
    }
}

/// Local-only store of device labels, keyed by hardware address.
///
/// This is the device equivalent of `APRegistry`, with one deliberate
/// difference: it persists a record only once the user has named, categorised
/// or annotated it. Merely observing a client's device never writes anything
/// about that device to disk.
@MainActor
final class DeviceRegistry: ObservableObject {
    @Published private(set) var records: [String: DeviceRecord] = [:]
    @Published private(set) var persistenceError: String?

    private let fileURL: URL
    private var savePending = false
    private var lastSave = Date.distantPast
    private var canPersist = true
    private let saveInterval: TimeInterval = 5

    /// The default folder is resolved inside the initialiser rather than as a
    /// default argument, because that expression would be evaluated outside
    /// this type's actor.
    init(folder: URL? = nil) {
        let base = folder ?? APRegistry.folderURL
        fileURL = base.appendingPathComponent("observed-devices.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            canPersist = false
            persistenceError = "The local data folder could not be created: \(error.localizedDescription)"
        }
        load()
    }

    // MARK: Keys

    /// Lower-cased, colon-separated form, so a label survives a MAC that is
    /// read back in a different case or with a different separator.
    nonisolated static func normalise(_ mac: String) -> String {
        let parts = mac.lowercased().split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return mac.lowercased() }
        return parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
    }

    // MARK: Reads

    func record(forMAC mac: String) -> DeviceRecord? {
        records[Self.normalise(mac)]
    }

    func nickname(forMAC mac: String) -> String? {
        guard let r = record(forMAC: mac), r.hasNickname else { return nil }
        return r.nickname
    }

    func category(forMAC mac: String) -> DeviceCategory {
        record(forMAC: mac)?.category ?? .unlabelled
    }

    func notes(forMAC mac: String) -> String {
        record(forMAC: mac)?.notes ?? ""
    }

    var labelledCount: Int {
        records.values.filter(\.isDeliberate).count
    }

    // MARK: Writes

    func setNickname(_ name: String, forMAC mac: String, currentIP: String? = nil) {
        update(mac, currentIP: currentIP) {
            $0.nickname = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func setNotes(_ notes: String, forMAC mac: String, currentIP: String? = nil) {
        update(mac, currentIP: currentIP) { $0.notes = notes }
    }

    func setCategory(_ category: DeviceCategory, forMAC mac: String, currentIP: String? = nil) {
        update(mac, currentIP: currentIP) { $0.categoryRaw = category.rawValue }
    }

    private func update(_ mac: String, currentIP: String?, _ change: (inout DeviceRecord) -> Void) {
        let key = Self.normalise(mac)
        var record = records[key] ?? DeviceRecord(macKey: key)
        change(&record)
        record.lastSeen = Date()
        if let currentIP { record.lastIP = currentIP }
        // A record stripped back to nothing is removed rather than persisted
        // as an empty shell, so "clear the name" really does forget the device.
        if record.isDeliberate {
            records[key] = record
        } else {
            records.removeValue(forKey: key)
        }
        scheduleSave()
    }

    func forget(mac: String) {
        records.removeValue(forKey: Self.normalise(mac))
        scheduleSave()
    }

    func forgetAll() {
        records.removeAll()
        scheduleSave()
    }

    // MARK: Transfer

    func exportJSON() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(records.values.filter(\.isDeliberate).sorted { $0.macKey < $1.macKey })
    }

    /// Merges an exported file. Existing labels win on conflict, so importing a
    /// colleague's file cannot silently overwrite your own naming.
    @discardableResult
    func importJSON(_ data: Data) -> Int? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([DeviceRecord].self, from: data) else { return nil }
        var added = 0
        for incoming in list where incoming.isDeliberate {
            let key = Self.normalise(incoming.macKey)
            guard records[key] == nil else { continue }
            var copy = incoming
            copy.macKey = key
            records[key] = copy
            added += 1
        }
        if added > 0 { scheduleSave() }
        return added
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: fileURL)
            let list = try dec.decode([DeviceRecord].self, from: data)
            var loaded: [String: DeviceRecord] = [:]
            for record in list where record.isDeliberate {
                let key = Self.normalise(record.macKey)
                if let existing = loaded[key], existing.lastSeen > record.lastSeen { continue }
                var copy = record
                copy.macKey = key
                loaded[key] = copy
            }
            records = loaded
        } catch {
            canPersist = false
            persistenceError = "Saved device labels could not be read: \(error.localizedDescription)"
        }
    }

    /// Throttle rather than debounce, for the reason given in `APRegistry`.
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
        let keep = records.values.filter(\.isDeliberate)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            if keep.isEmpty {
                // Nothing is labelled any more; remove the file rather than
                // leaving an empty list behind on a client's machine.
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } else {
                try enc.encode(Array(keep)).write(to: fileURL, options: .atomic)
            }
            persistenceError = nil
        } catch {
            persistenceError = "Device labels could not be saved: \(error.localizedDescription)"
        }
    }
}
