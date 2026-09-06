import Foundation

/// Whether this is the screenshot build. Present in every build so the
/// interface can compile against it; the value is a compile-time constant, so
/// a shipping build folds every check away to false.
enum DemoBuild {
    static var isActive: Bool {
        #if DEMO_SCREENSHOTS
        true
        #else
        false
        #endif
    }
}

#if DEMO_SCREENSHOTS

/// Placeholder network identifiers for App Store screenshots.
///
/// Screenshots of this app necessarily show the network it was taken on, and a
/// BSSID can be resolved to a physical location through public databases. That
/// makes publishing a real one on a store page a genuine disclosure, so the
/// screenshot build substitutes invented identifiers at the point they enter
/// the app. Every view, export and report downstream then shows the same safe
/// values without knowing anything about it.
///
/// This is compiled in only when the DEMO_SCREENSHOTS flag is passed, which
/// only tools/screenshots.sh does. It is absent from every shipping build —
/// `build.sh` and `build-appstore.sh` never define it.
enum DemoIdentifiers {

    /// Documentation-range values, chosen so nothing here maps to real
    /// hardware or a real network.
    static let ssid = "Acme-Corp"
    /// 00:00:5E is IANA's block, reserved for documentation and examples.
    static let bssid = "00:00:5e:00:53:a1"
    static let routerMAC = "00:00:5e:00:53:9f"
    static let ipv4 = "10.0.4.182"
    static let subnetMask = "255.255.255.0"
    static let router = "10.0.4.1"
    static let dns = ["10.0.4.1"]
    static let searchDomains = ["acme.example"]

}

#endif
