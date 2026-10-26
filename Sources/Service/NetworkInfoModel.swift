import Foundation
import Combine

/// Keeps IP-layer details current without polling as fast as the radio.
@MainActor
final class NetworkInfoModel: ObservableObject {
    @Published private(set) var config = IPConfig()
    @Published private(set) var arpEntries: [ARPEntry] = []
    @Published private(set) var ipv6Neighbors: [IPv6Neighbor] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastARPRefresh: Date?
    @Published private(set) var isRefreshingARP = false
    @Published private(set) var isDiscoveringIPv6 = false

    private var timer: Timer?
    /// How many visible panes want the neighbour cache kept current. A view
    /// cannot own this timer: SwiftUI rebuilds the body far more often than
    /// every five seconds, and a Timer.publish written there is replaced on
    /// each rebuild, so it never survives long enough to fire.
    private var arpWatchers = 0
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
        ipv6Neighbors = []
        lastRefresh = nil
        lastARPRefresh = nil
        arpRefreshGeneration &+= 1
        isRefreshingARP = false
        isDiscoveringIPv6 = false
        refresh()
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if self.arpWatchers > 0 { self.refreshARP() }
            }
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

    /// Called by a pane that shows the neighbour cache while it is on screen.
    func beginARPPolling() {
        arpWatchers += 1
        refreshARP()
    }

    func endARPPolling() {
        arpWatchers = Swift.max(0, arpWatchers - 1)
    }

    /// Reads the passive neighbor cache only when a view that displays it asks.
    func refreshARP() {
        guard !isRefreshingARP else { return }
        arpRefreshGeneration &+= 1
        let generation = arpRefreshGeneration
        isRefreshingARP = true
        DispatchQueue.global(qos: .utility).async {
            let entries = ARPTable.read()
            let ipv6 = IPv6NeighborTable.read()
            Task { @MainActor in
                guard self.arpRefreshGeneration == generation else { return }
                self.arpEntries = entries
                self.ipv6Neighbors = ipv6
                self.lastARPRefresh = Date()
                self.isRefreshingARP = false
            }
        }
    }

    /// Actively asks all IPv6 nodes on the current link to answer once, then
    /// refreshes the passive neighbor tables. The scan options sheet obtains
    /// consent before this is called.
    func discoverIPv6Neighbors() {
        guard !isDiscoveringIPv6 else { return }
        let name = interfaceName
        isDiscoveringIPv6 = true
        DispatchQueue.global(qos: .utility).async {
            _ = IPv6NeighborTable.solicit(interface: name)
            let ipv6 = IPv6NeighborTable.read()
            Task { @MainActor in
                guard self.interfaceName == name else {
                    self.isDiscoveringIPv6 = false
                    return
                }
                self.ipv6Neighbors = ipv6
                self.isDiscoveringIPv6 = false
            }
        }
    }
}
