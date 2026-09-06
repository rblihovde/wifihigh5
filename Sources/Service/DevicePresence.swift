import Foundation
import Combine

/// Tracks when each device appeared in, and disappeared from, the Mac's
/// neighbour cache while the app has been watching.
///
/// This is derived entirely from repeated reads of a cache the system already
/// maintains. Nothing is sent to any device to establish presence, and nothing
/// here is written to disk: the history lasts as long as the app is running.
///
/// The practical value is arrival and departure. A technician who opens this
/// view on arriving at a site can see which devices joined the network while
/// they were there, which is the question a cache snapshot cannot answer.
@MainActor
final class DevicePresence: ObservableObject {

    struct Sighting: Equatable {
        var firstSeen: Date
        var lastSeen: Date
        var lastIP: String
        /// False for everything in the first read, which is the baseline: those
        /// devices were already on the network before the app started looking.
        var arrivedWhileWatching: Bool
        /// False once the device stops appearing in the cache.
        var isPresent: Bool
        /// Consecutive reads that have not contained this device.
        var missedReads: Int
    }

    @Published private(set) var sightings: [String: Sighting] = [:]
    @Published private(set) var readCount = 0
    @Published private(set) var watchingSince = Date()

    /// Reads after which an absent device is treated as gone rather than as a
    /// gap. The cache drops idle entries on its own schedule, so a single miss
    /// means very little.
    private let absenceThreshold = 2

    /// Folds one read of the on-subnet neighbour cache into the history.
    func note(_ entries: [ARPEntry], now: Date = Date()) {
        readCount += 1
        let isBaseline = readCount == 1

        var present = Set<String>()
        for entry in entries {
            let key = DeviceRegistry.normalise(entry.mac)
            present.insert(key)
            if var existing = sightings[key] {
                existing.lastSeen = now
                existing.lastIP = entry.ip
                existing.isPresent = true
                existing.missedReads = 0
                sightings[key] = existing
            } else {
                sightings[key] = Sighting(
                    firstSeen: now,
                    lastSeen: now,
                    lastIP: entry.ip,
                    arrivedWhileWatching: !isBaseline,
                    isPresent: true,
                    missedReads: 0
                )
            }
        }

        for (key, var sighting) in sightings where !present.contains(key) {
            guard sighting.isPresent || sighting.missedReads < absenceThreshold else { continue }
            sighting.missedReads += 1
            if sighting.missedReads >= absenceThreshold { sighting.isPresent = false }
            sightings[key] = sighting
        }
    }

    func sighting(forMAC mac: String) -> Sighting? {
        sightings[DeviceRegistry.normalise(mac)]
    }

    /// Devices that have stopped appearing in the cache but were seen earlier.
    var departed: [(mac: String, sighting: Sighting)] {
        sightings
            .filter { !$0.value.isPresent }
            .map { (mac: $0.key, sighting: $0.value) }
            .sorted { $0.sighting.lastSeen > $1.sighting.lastSeen }
    }

    var arrivedCount: Int {
        sightings.values.filter { $0.arrivedWhileWatching && $0.isPresent }.count
    }

    var departedCount: Int {
        sightings.values.filter { !$0.isPresent }.count
    }

    /// Called when the network changes underneath us, so arrivals are not
    /// reported against a subnet the readings no longer belong to.
    func reset(now: Date = Date()) {
        sightings.removeAll()
        readCount = 0
        watchingSince = now
    }
}
