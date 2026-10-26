import Foundation

struct SpeedTestResult: Identifiable {
    let id = UUID()
    var date: Date
    var latencyMS: Double
    var jitterMS: Double
    var downloadMbps: Double
    var uploadMbps: Double
    var edgeLocation: String?
    var networkName: String?
    var bytesDownloaded: Int64
    var bytesUploaded: Int64
}

enum SpeedTestMath {
    static func megabitsPerSecond(bytes: Int, seconds: TimeInterval) -> Double {
        guard bytes > 0, seconds > 0 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let bounded = min(1, max(0, fraction))
        let index = Int((Double(sorted.count - 1) * bounded).rounded())
        return sorted[index]
    }

    /// Stop growing transfers once the next one would take longer than this.
    static let transferBudget: TimeInterval = 12

    /// Whether to try the next, larger transfer: not once a sizeable one has
    /// run long enough to measure, nor when the next is unlikely to finish
    /// within the budget at the rate `size` bytes just achieved.
    static func shouldGrow(after elapsed: TimeInterval, size: Int, next: Int?) -> Bool {
        guard let next, size > 0 else { return false }
        if elapsed >= 1.5, size >= 5_000_000 { return false }
        return elapsed * Double(next) / Double(size) <= transferBudget
    }

    /// Milliseconds Cloudflare reports spending on a request itself, from its
    /// `Server-Timing` header ("cfSpeedEdge;dur=6, cfSpeedWorker;dur=27").
    /// The largest is taken, since the phases may nest. Nil when absent.
    static func serverMilliseconds(_ header: String?) -> Double? {
        guard let header else { return nil }
        let durations = header.split(separator: ",").compactMap { entry -> Double? in
            let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first?.hasPrefix("cfSpeed") == true else { return nil }
            return parts.dropFirst().first { $0.hasPrefix("dur=") }
                .flatMap { Double($0.dropFirst(4)) }
        }
        guard let longest = durations.max(), longest.isFinite, longest >= 0 else { return nil }
        return longest
    }

    static func jitter(_ latencyValues: [Double]) -> Double {
        guard latencyValues.count > 1 else { return 0 }
        let differences = zip(latencyValues, latencyValues.dropFirst()).map { abs($1 - $0) }
        return differences.reduce(0, +) / Double(differences.count)
    }
}
