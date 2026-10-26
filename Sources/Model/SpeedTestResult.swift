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

    static func jitter(_ latencyValues: [Double]) -> Double {
        guard latencyValues.count > 1 else { return 0 }
        let differences = zip(latencyValues, latencyValues.dropFirst()).map { abs($1 - $0) }
        return differences.reduce(0, +) / Double(differences.count)
    }
}
