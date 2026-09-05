import Foundation
import Combine

/// Keeps IP-layer details current without polling as fast as the radio.
@MainActor
final class NetworkInfoModel: ObservableObject {
    @Published private(set) var config = IPConfig()
    @Published private(set) var lastRefresh: Date?

    private var timer: Timer?
    private var interfaceName = "en0"

    init() { refresh() }

    func bind(interface: String) {
        guard interface != interfaceName else { return }
        interfaceName = interface
        refresh()
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let name = interfaceName
        DispatchQueue.global(qos: .utility).async {
            let cfg = SystemNetwork.read(interface: name)
            Task { @MainActor in
                self.config = cfg
                self.lastRefresh = Date()
            }
        }
    }
}
