import Foundation
import Combine

struct SpeedTestUpdate: Sendable {
    var stage: String
    var progress: Double
    var latencyMS: Double?
    var downloadMbps: Double?
    var uploadMbps: Double?
}

@MainActor
final class InternetSpeedTester: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var stage = "Ready"
    @Published private(set) var progress = 0.0
    @Published private(set) var latencyMS: Double?
    @Published private(set) var jitterMS: Double?
    @Published private(set) var downloadMbps: Double?
    @Published private(set) var uploadMbps: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var history: [SpeedTestResult] = []

    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(networkName: String?) {
        guard !isRunning else { return }
        generation = UUID()
        let run = generation
        isRunning = true
        stage = "Preparing test…"
        progress = 0
        latencyMS = nil
        jitterMS = nil
        downloadMbps = nil
        uploadMbps = nil
        errorMessage = nil

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await SpeedTestEngine.run(networkName: networkName) { update in
                    await MainActor.run {
                        guard self.generation == run else { return }
                        self.stage = update.stage
                        self.progress = update.progress
                        if let value = update.latencyMS { self.latencyMS = value }
                        if let value = update.downloadMbps { self.downloadMbps = value }
                        if let value = update.uploadMbps { self.uploadMbps = value }
                    }
                }
                guard self.generation == run else { return }
                self.latencyMS = result.latencyMS
                self.jitterMS = result.jitterMS
                self.downloadMbps = result.downloadMbps
                self.uploadMbps = result.uploadMbps
                self.history.insert(result, at: 0)
                if self.history.count > 10 { self.history.removeLast(self.history.count - 10) }
                self.stage = "Complete"
                self.progress = 1
                self.isRunning = false
                self.task = nil
            } catch is CancellationError {
                guard self.generation == run else { return }
                self.stage = "Cancelled"
                self.isRunning = false
                self.task = nil
            } catch {
                guard self.generation == run else { return }
                self.stage = "Couldn’t complete test"
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.isRunning = false
                self.task = nil
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        stage = "Cancelled"
    }
}

private enum SpeedTestFailure: LocalizedError {
    case invalidResponse
    case server(Int)
    case emptyTransfer
    case noMeasurement

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The test server returned an invalid response."
        case .server(let code): return "The test server refused the request (HTTP \(code)). Try again later."
        case .emptyTransfer: return "The test server returned no measurement data."
        case .noMeasurement: return "The connection ended before a usable speed measurement was completed."
        }
    }
}

private enum SpeedTestEngine {
    /// Monotonic seconds, so a clock change mid-test cannot skew a reading.
    private static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// A timeout or refusal after at least one good sample ends that phase
    /// rather than the whole test, so slow links still get a result.
    private static func isRecoverable(_ error: Error) -> Bool {
        if (error as? URLError)?.code == .timedOut { return true }
        if case .server = error as? SpeedTestFailure { return true }
        return false
    }

    private struct ThroughputSample {
        var mbps: Double
        var duration: TimeInterval
    }

    static func run(networkName: String?,
                    update: @escaping @Sendable (SpeedTestUpdate) async -> Void) async throws -> SpeedTestResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        configuration.httpAdditionalHeaders = ["User-Agent": "WifiHigh5/\(version) SpeedTest"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var edgeLocation: String?
        var latencyValues: [Double] = []
        for index in 0..<9 {
            try Task.checkCancellation()
            await update(SpeedTestUpdate(stage: "Measuring latency…", progress: 0.02 + Double(index) * 0.012,
                                         latencyMS: latencyValues.count < 2 ? nil : SpeedTestMath.median(Array(latencyValues.dropFirst())),
                                         downloadMbps: nil, uploadMbps: nil))
            let request = try downloadRequest(bytes: 0)
            let started = now()
            let (_, response) = try await session.data(for: request)
            let elapsed = (now() - started) * 1_000
            let http = try validate(response)
            edgeLocation = edgeLocation ?? edgeCode(http)
            // Time Cloudflare spent serving the request is not network latency.
            let server = SpeedTestMath.serverMilliseconds(http.value(forHTTPHeaderField: "Server-Timing")) ?? 0
            latencyValues.append(max(elapsed - server, 0))
        }
        // The first request also opens the connection and negotiates TLS, so
        // it is a warm-up rather than a latency sample.
        let settled = Array(latencyValues.dropFirst())
        let latency = SpeedTestMath.median(settled)
        let jitter = SpeedTestMath.jitter(settled)
        await update(SpeedTestUpdate(stage: "Measuring download…", progress: 0.14,
                                     latencyMS: latency, downloadMbps: nil, uploadMbps: nil))

        // Cloudflare's endpoint refuses some sizes (12 and 15 MB return 403),
        // so these are sizes its own speed test requests.
        let downloadSizes = [1_000_000, 10_000_000, 25_000_000, 50_000_000]
        var downloadSamples: [ThroughputSample] = []
        var downloaded: Int64 = 0
        for (index, size) in downloadSizes.enumerated() {
            try Task.checkCancellation()
            let request = try downloadRequest(bytes: size)
            let started = now()
            let data: Data, http: HTTPURLResponse
            do {
                let (body, response) = try await session.data(for: request)
                (data, http) = (body, try validate(response))
            } catch where isRecoverable(error) && !downloadSamples.isEmpty {
                break
            }
            let elapsed = now() - started
            edgeLocation = edgeLocation ?? edgeCode(http)
            guard !data.isEmpty else { throw SpeedTestFailure.emptyTransfer }
            downloaded += Int64(data.count)
            let sample = ThroughputSample(
                mbps: SpeedTestMath.megabitsPerSecond(bytes: data.count, seconds: elapsed),
                duration: elapsed)
            downloadSamples.append(sample)
            let current = representative(downloadSamples)
            await update(SpeedTestUpdate(stage: "Measuring download…",
                                         progress: 0.18 + Double(index + 1) / Double(downloadSizes.count) * 0.38,
                                         latencyMS: latency, downloadMbps: current, uploadMbps: nil))
            let next = downloadSizes.indices.contains(index + 1) ? downloadSizes[index + 1] : nil
            if !SpeedTestMath.shouldGrow(after: elapsed, size: size, next: next) { break }
        }
        guard !downloadSamples.isEmpty else { throw SpeedTestFailure.noMeasurement }
        let download = representative(downloadSamples)

        await update(SpeedTestUpdate(stage: "Measuring upload…", progress: 0.61,
                                     latencyMS: latency, downloadMbps: download, uploadMbps: nil))
        let uploadSizes = [1_000_000, 5_000_000, 10_000_000, 20_000_000]
        var uploadSamples: [ThroughputSample] = []
        var uploaded: Int64 = 0
        for (index, size) in uploadSizes.enumerated() {
            try Task.checkCancellation()
            // Random bytes, because a compressing proxy or VPN would make
            // zeros look far faster than the link really is.
            var payload = Data(count: size)
            payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!)
            request.httpMethod = "POST"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
            let started = now()
            let http: HTTPURLResponse
            do {
                let (_, response) = try await session.upload(for: request, from: payload)
                http = try validate(response)
            } catch where isRecoverable(error) && !uploadSamples.isEmpty {
                break
            }
            let elapsed = now() - started
            edgeLocation = edgeLocation ?? edgeCode(http)
            uploaded += Int64(size)
            let sample = ThroughputSample(
                mbps: SpeedTestMath.megabitsPerSecond(bytes: size, seconds: elapsed),
                duration: elapsed)
            uploadSamples.append(sample)
            let current = representative(uploadSamples)
            await update(SpeedTestUpdate(stage: "Measuring upload…",
                                         progress: 0.64 + Double(index + 1) / Double(uploadSizes.count) * 0.31,
                                         latencyMS: latency, downloadMbps: download, uploadMbps: current))
            let next = uploadSizes.indices.contains(index + 1) ? uploadSizes[index + 1] : nil
            if !SpeedTestMath.shouldGrow(after: elapsed, size: size, next: next) { break }
        }
        guard !uploadSamples.isEmpty else { throw SpeedTestFailure.noMeasurement }
        let upload = representative(uploadSamples)

        return SpeedTestResult(date: Date(), latencyMS: latency, jitterMS: jitter,
                               downloadMbps: download, uploadMbps: upload,
                               edgeLocation: edgeLocation, networkName: networkName,
                               bytesDownloaded: downloaded, bytesUploaded: uploaded)
    }

    private static func representative(_ samples: [ThroughputSample]) -> Double {
        let stable = samples.filter { $0.duration >= 0.25 }.map(\.mbps)
        return SpeedTestMath.percentile(stable.isEmpty ? samples.map(\.mbps) : stable, 0.9)
    }

    private static func downloadRequest(bytes: Int) throws -> URLRequest {
        var components = URLComponents(string: "https://speed.cloudflare.com/__down")!
        components.queryItems = [
            URLQueryItem(name: "bytes", value: String(bytes)),
            URLQueryItem(name: "cacheBust", value: UUID().uuidString)
        ]
        guard let url = components.url else { throw SpeedTestFailure.invalidResponse }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private static func validate(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw SpeedTestFailure.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw SpeedTestFailure.server(http.statusCode) }
        return http
    }

    private static func edgeCode(_ response: HTTPURLResponse) -> String? {
        guard let ray = response.value(forHTTPHeaderField: "CF-Ray"),
              let suffix = ray.split(separator: "-").last, suffix.count == 3 else { return nil }
        return String(suffix).uppercased()
    }
}
