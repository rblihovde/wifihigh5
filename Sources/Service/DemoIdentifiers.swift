import Foundation

/// Indicates whether the app was compiled for App Store screenshots.
/// Shipping builds set this compile-time constant to false.
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
/// A screenshot can show the source network. Public databases can associate a
/// BSSID with a physical location. The screenshot build substitutes placeholder
/// identifiers before the data reaches a view, export, or report.
///
/// This code is available only when tools/screenshots.sh sets the
/// DEMO_SCREENSHOTS flag. Shipping build scripts do not set the flag.
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
