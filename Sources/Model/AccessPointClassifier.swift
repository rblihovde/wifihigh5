import Foundation

/// A deliberately cautious description of an access point.
///
/// The IEEE registry identifies the organisation that owns a BSSID block, not
/// necessarily the logo on the enclosure. Likewise, a scan proves that a radio
/// is an access point but usually cannot read its product model. Every subtype
/// below is therefore phrased as an inference and carries its explanation.
struct AccessPointProfile: Equatable {
    var manufacturer: String
    var manufacturerDetail: String
    var kind: String
    var kindDetail: String

    static func identify(bssid: String?, ssid: String?, securityRaw: Int?,
                         vendor: VendorResult) -> AccessPointProfile {
        let maker: String
        let makerDetail: String
        if bssid == nil {
            maker = "Manufacturer unavailable"
            makerDetail = "macOS did not reveal the BSSID, so there is no hardware prefix to look up."
        } else {
            switch vendor {
            case .known(let name):
                maker = name
                makerDetail = "Registered owner of this BSSID block in the embedded IEEE registry. It may be the radio or board maker rather than the enclosure brand."
            case .randomised:
                maker = "Software-assigned BSSID"
                makerDetail = "This address is locally administered, so its prefix cannot identify a manufacturer."
            case .unregistered:
                maker = "Manufacturer not found"
                makerDetail = "The BSSID is not matched by the embedded IEEE registry."
            case .loading:
                maker = "Looking up manufacturer…"
                makerDetail = "The embedded IEEE registry is still loading."
            }
        }

        let lowerMaker = maker.lowercased()
        let lowerSSID = (ssid ?? "").lowercased()
        let enterpriseSecurity = [7, 8, 9, 10, 12].contains(securityRaw ?? -1)

        let kind: String
        let kindDetail: String
        if lowerSSID.hasSuffix("_ext") || lowerSSID.hasSuffix("-ext")
            || lowerSSID.contains("extender") || lowerSSID.contains("repeater") {
            kind = "Likely range extender"
            kindDetail = "Inferred from the network name. SSIDs are editable, so this is a clue rather than proof."
        } else if lowerSSID.contains("iphone") || lowerSSID == "androidap"
                    || lowerSSID.hasPrefix("pixel ") {
            kind = "Possible personal hotspot"
            kindDetail = "Inferred from a common hotspot network name. SSIDs are editable, so this is not certain."
        } else if enterpriseSecurity {
            kind = "Enterprise access point"
            kindDetail = "Inferred from the enterprise authentication mode advertised by the radio."
        } else if containsAny(lowerMaker, ["eero", "plume", "airties"]) {
            kind = "Likely mesh Wi-Fi node"
            kindDetail = "Inferred from a manufacturer strongly associated with managed mesh Wi-Fi systems."
        } else if containsAny(lowerMaker, [
            "aruba", "ruckus", "meraki", "ubiquiti", "cambium", "fortinet",
            "extreme networks", "juniper", "mist systems", "aerohive", "engenius"
        ]) {
            kind = "Likely managed access point"
            kindDetail = "Inferred from a manufacturer focused on managed Wi-Fi and network infrastructure."
        } else if containsAny(lowerMaker, [
            "arris", "technicolor", "commscope", "sagemcom", "actiontec", "askey",
            "ubee", "calix", "adtran", "humax", "zte"
        ]) {
            kind = "Likely Wi-Fi gateway"
            kindDetail = "Inferred from a manufacturer commonly used for combined modem, router, and Wi-Fi gateways."
        } else if containsAny(lowerMaker, [
            "netgear", "tp-link", "d-link", "linksys", "zyxel", "tenda", "asus",
            "mikrotik", "belkin"
        ]) {
            kind = "Likely router or access point"
            kindDetail = "Inferred from a manufacturer that makes routers, access points, and related Wi-Fi equipment."
        } else {
            kind = "Wi-Fi access point"
            kindDetail = "The scan confirms an access-point radio, but its BSSID and beacon do not reveal a reliable chassis subtype or model."
        }

        return AccessPointProfile(manufacturer: maker, manufacturerDetail: makerDetail,
                                  kind: kind, kindDetail: kindDetail)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
