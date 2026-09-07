import Foundation

/// A guess at what a device is, made only from its manufacturer.
///
/// Nothing here is measured. The IEEE registry says who built the hardware, and
/// for many manufacturers that narrows what the hardware is: a company that
/// only makes printers is not likely to be on the network as anything else.
/// For companies that make everything, no type is claimed at all.
struct DeviceGuess: Equatable {
    /// The type this suggests, or nil when the manufacturer implies no single
    /// kind of device.
    var category: DeviceCategory?
    /// One line for the row, always hedged, because this is an inference.
    var summary: String
    /// Why, in the words the help uses.
    var basis: String
    var strength: Strength

    enum Strength: Equatable {
        /// The manufacturer makes essentially one kind of network device.
        case likely
        /// The manufacturer makes several kinds, so this narrows it a little
        /// and no further.
        case possible
    }
}

enum DeviceClassifier {

    private struct Rule {
        var needles: [String]
        var category: DeviceCategory?
        var summary: String
        var basis: String
        var strength: DeviceGuess.Strength
    }

    /// Ordered, and the first match wins, so put the specific before the
    /// general. "Hewlett Packard Enterprise" builds switches while "HP Inc"
    /// builds printers, and the two must not be collapsed.
    private static let rules: [Rule] = [
        Rule(needles: ["hewlett packard enterprise", "aruba", "juniper", "extreme networks",
                       "arista", "brocade"],
             category: .networkSwitch,
             summary: "Likely network equipment",
             basis: "This manufacturer builds switching and routing hardware for networks.",
             strength: .likely),

        Rule(needles: ["hewlett packard", "hp inc", "canon", "brother industries", "seiko epson",
                       "epson", "lexmark", "xerox", "zebra technologies", "ricoh", "kyocera",
                       "konica", "oki electric", "dymo", "star micronics"],
             category: .printer,
             summary: "Likely a printer",
             basis: "This manufacturer builds printing and imaging hardware.",
             strength: .likely),

        Rule(needles: ["axis communications", "hikvision", "dahua", "amcrest", "reolink",
                       "vivotek", "mobotix", "arlo", "wyze"],
             category: .camera,
             summary: "Likely a camera",
             basis: "This manufacturer builds video surveillance hardware.",
             strength: .likely),

        Rule(needles: ["ubiquiti", "ruckus", "cambium", "mikrotik", "meraki", "cisco systems",
                       "cisco-linksys", "netgear", "tp-link", "d-link", "zyxel", "linksys",
                       "engenius", "tenda", "edgecore"],
             category: .accessPoint,
             summary: "Likely network equipment",
             basis: "This manufacturer builds routers, access points and switches.",
             strength: .likely),

        Rule(needles: ["wistron neweb", "wnc corporation", "arris", "technicolor", "commscope", "sagemcom",
                       "actiontec", "askey", "humax", "ubee", "zte corporation", "calix",
                       "adtran", "airties"],
             category: .router,
             summary: "Likely a router or gateway supplied by an internet provider",
             basis: "This manufacturer builds the gateways that internet providers hand out.",
             strength: .likely),

        Rule(needles: ["espressif", "tuya", "shelly", "sonoff", "itead", "particle industries",
                       "tasmota", "shenzhen heiman", "aqara", "lumi united"],
             category: .iot,
             summary: "Likely a sensor, smart plug or controller",
             basis: "This manufacturer builds the wireless modules used in small smart-home hardware.",
             strength: .likely),

        Rule(needles: ["signify", "philips lighting", "lifx", "nanoleaf"],
             category: .iot,
             summary: "Likely a light or lighting bridge",
             basis: "This manufacturer builds connected lighting.",
             strength: .likely),

        Rule(needles: ["ecobee", "nest labs", "resideo", "honeywell", "emerson electric"],
             category: .iot,
             summary: "Likely a thermostat or building control",
             basis: "This manufacturer builds heating, cooling and building controls.",
             strength: .likely),

        Rule(needles: ["sonos", "roku", "vizio", "bose", "denon", "yamaha", "harman",
                       "spotify", "bang & olufsen", "sonance"],
             category: .television,
             summary: "Likely a speaker, TV or media player",
             basis: "This manufacturer builds audio and video playback hardware.",
             strength: .likely),

        Rule(needles: ["polycom", "yealink", "grandstream", "snom", "mitel", "avaya",
                       "cisco spa", "fanvil"],
             category: .voip,
             summary: "Likely a desk phone or conferencing unit",
             basis: "This manufacturer builds telephony hardware.",
             strength: .likely),

        Rule(needles: ["synology", "qnap", "western digital", "seagate", "drobo", "buffalo.inc"],
             category: .storage,
             summary: "Likely network storage",
             basis: "This manufacturer builds network-attached storage.",
             strength: .likely),

        Rule(needles: ["supermicro", "dell emc", "hewlett-packard company", "ibm", "lenovo global"],
             category: .server,
             summary: "Likely a server",
             basis: "This manufacturer builds server hardware.",
             strength: .possible),

        Rule(needles: ["raspberry pi"],
             category: .desktop,
             summary: "Likely a small single-board computer",
             basis: "Raspberry Pi hardware is usually running as a small always-on computer.",
             strength: .likely),

        // Companies that make many kinds of device. Naming the maker is useful;
        // claiming a type would not be.
        Rule(needles: ["apple"],
             category: nil,
             summary: "An Apple device",
             basis: "Apple builds phones, tablets, computers, watches, TV boxes and speakers, so the address alone does not say which.",
             strength: .possible),

        Rule(needles: ["samsung"],
             category: nil,
             summary: "A Samsung device",
             basis: "Samsung builds phones, televisions and appliances, so the address alone does not say which.",
             strength: .possible),

    ]

    /// Makers whose products span too many categories, or who supply the radio
    /// inside someone else's product. Their name is worth showing; a type is not.
    private static let unrevealing: [String] = [
        "google", "amazon technologies", "microsoft", "sony", "lg electronics",
        "intel corporate", "dell inc", "asustek", "hon hai", "murata", "liteon",
        "quanta", "compal", "texas instruments", "realtek", "broadcom",
        "qualcomm", "mediatek", "azurewave", "wistron", "pegatron", "foxconn"
    ]

    /// Works out what a manufacturer implies. Returns nil when it implies
    /// nothing worth saying.
    static func guess(vendor: String?) -> DeviceGuess? {
        guard let vendor else { return nil }
        let name = vendor.lowercased()

        for rule in rules {
            if rule.needles.contains(where: { name.contains($0) }) {
                return DeviceGuess(category: rule.category,
                                   summary: rule.summary,
                                   basis: rule.basis,
                                   strength: rule.strength)
            }
        }

        if unrevealing.contains(where: { name.contains($0) }) {
            return DeviceGuess(
                category: nil,
                summary: "Made by \(vendor)",
                basis: "This company builds many kinds of hardware, or supplies the wireless part inside someone else's product, so the address does not say what the device is.",
                strength: .possible)
        }
        return nil
    }
}
