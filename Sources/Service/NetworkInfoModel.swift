import Foundation
import Combine

/// Keeps IP-layer details current without polling as fast as the radio.
@MainActor
final class NetworkInfoModel: ObservableObject {
    @Published private(set) var config = IPConfig()
    @Published private(set) var arpEntries: [ARPEntry] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastARPRefresh: Date?
    @Published private(set) var isRefreshingARP = false

    private var timer: Timer?
    private var interfaceName = "en0"
    private var refreshGeneration: UInt = 0
    private var arpRefreshGeneration: UInt = 0

    init() { refresh() }

    func bind(interface: String) {
        guard interface != interfaceName else { return }
        interfaceName = interface
        // Do not display or ping the previous adapter's gateway while the new
        // interface read is in flight.
        config = IPConfig()
        arpEntries = []
        lastRefresh = nil
        lastARPRefresh = nil
        arpRefreshGeneration &+= 1
        isRefreshingARP = false
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
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let name = interfaceName
        DispatchQueue.global(qos: .utility).async {
            let cfg = SystemNetwork.read(interface: name)
            Task { @MainActor in
                guard self.refreshGeneration == generation,
                      self.interfaceName == name else { return }
                self.config = cfg
                self.lastRefresh = Date()
            }
        }
    }

    /// Reads the passive neighbor cache only when a view that displays it asks.
    func refreshARP() {
        guard !isRefreshingARP else { return }
        arpRefreshGeneration &+= 1
        let generation = arpRefreshGeneration
        isRefreshingARP = true
        DispatchQueue.global(qos: .utility).async {
            let entries = ARPTable.read()
            Task { @MainActor in
                guard self.arpRefreshGeneration == generation else { return }
                self.arpEntries = entries
                self.lastARPRefresh = Date()
                self.isRefreshingARP = false
            }
        }
    }
}
