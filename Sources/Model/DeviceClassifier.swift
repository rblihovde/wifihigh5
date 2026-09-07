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
    /// Which evidence produced this. The row uses it to avoid printing the
    /// same fact twice in different words.
    var source: Source

    enum Source: Equatable {
        case model
        case services
        case name
        case manufacturer
    }

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

    // MARK: Entry point

    /// Works out what a device is from everything known about it.
    ///
    /// Evidence is taken in order of how directly it comes from the device
    /// itself. A model string the device published beats a service it offers,
    /// which beats the name it answers to, which beats an inference from
    /// whoever manufactured the address. The first one that says anything wins,
    /// so a weak signal never overrides a strong one.
    static func guess(vendor: String?,
                      finding: DeviceFinding? = nil,
                      isLocallyAdministered: Bool = false) -> DeviceGuess? {
        if let exact = exactModelGuess(finding?.model) { return exact }
        // The name comes before the services on purpose. A Mac advertises
        // AirPlay exactly as an Apple TV does, so "offers AirPlay" cannot tell
        // the two apart, whereas a device called "MacBook Air" can.
        if let fromName = nameGuess(finding?.advertisedName ?? finding?.hostname) {
            return fromName
        }
        if let fromServices = serviceGuess(finding?.services) { return fromServices }
        if let looseModel = looseModelGuess(finding?.model) { return looseModel }
        // A randomised address belongs to no manufacturer, so the registry can
        // say nothing about it. Everything above still applies, because those
        // come from the device rather than from its address.
        guard !isLocallyAdministered else { return nil }
        return vendorGuess(vendor)
    }

    // MARK: Evidence

    /// Apple publishes a model identifier over Bonjour, and it is exact.
    private static let appleModels: [(prefix: String, category: DeviceCategory, name: String)] = [
        ("iphone",         .phone,      "iPhone"),
        ("ipad",           .tablet,     "iPad"),
        ("ipod",           .phone,      "iPod"),
        ("macbook",        .laptop,     "MacBook"),
        ("imac",           .desktop,    "iMac"),
        ("macmini",        .desktop,    "Mac mini"),
        ("macpro",         .desktop,    "Mac Pro"),
        ("macstudio",      .desktop,    "Mac Studio"),
        ("appletv",        .television, "Apple TV"),
        ("audioaccessory", .speaker,    "HomePod"),
        ("homepod",        .speaker,    "HomePod"),
        ("watch",          .phone,      "Apple Watch")
    ]

    /// Model identifiers that name one kind of device and nothing else.
    private static func exactModelGuess(_ model: String?) -> DeviceGuess? {
        guard let model, !model.isEmpty else { return nil }
        let name = model.lowercased()
        for entry in appleModels where name.hasPrefix(entry.prefix) {
            return DeviceGuess(
                category: entry.category,
                summary: entry.name,
                basis: "The device published its model as \(model).",
                strength: .likely,
                source: .model)
        }
        return nil
    }

    /// Model strings that narrow a device without pinning it down. Apple's
    /// newer Macs all report "Mac<n>,<n>" whether they are a laptop, a mini or
    /// an iMac, so this runs only after the device's name has had its say.
    private static let looseModels: [(prefix: String, category: DeviceCategory, name: String)] = [
        ("aft", .television, "Fire TV"),
        ("mac", .desktop,    "Mac")
    ]

    private static func looseModelGuess(_ model: String?) -> DeviceGuess? {
        guard let model, !model.isEmpty else { return nil }
        let name = model.lowercased()

        for entry in looseModels where name.hasPrefix(entry.prefix) {
            return DeviceGuess(
                category: entry.category,
                summary: entry.name,
                basis: "The device published its model as \(model), which narrows it no further.",
                strength: .possible,
                source: .model)
        }
        if let keyword = keywordGuess(name) {
            return DeviceGuess(category: keyword.category,
                               summary: keyword.summary,
                               basis: "The device published its model as \(model).",
                               strength: .likely,
                               source: .model)
        }
        return nil
    }

    /// What a device offers says a good deal about what it is. These are the
    /// friendly labels recorded against a finding, not the raw service types.
    private static func serviceGuess(_ services: Set<String>?) -> DeviceGuess? {
        guard let services, !services.isEmpty else { return nil }

        func offering(_ label: String) -> Bool { services.contains(label) }

        if offering("Printing") || offering("Scanning") {
            return DeviceGuess(category: .printer, summary: "Printer",
                               basis: "The device advertises printing.", strength: .likely,
                               source: .services)
        }
        if offering("Camera") {
            return DeviceGuess(category: .camera, summary: "Camera",
                               basis: "The device advertises a video stream.", strength: .likely,
                               source: .services)
        }
        if offering("Chromecast") {
            return DeviceGuess(category: .television, summary: "Chromecast or Google TV",
                               basis: "The device advertises Chromecast.", strength: .likely,
                               source: .services)
        }
        if offering("AirPlay") {
            return DeviceGuess(category: .television, summary: "AirPlay display",
                               basis: "The device advertises AirPlay video.", strength: .likely,
                               source: .services)
        }
        if offering("AirPlay audio") || offering("Speaker") {
            return DeviceGuess(category: .speaker, summary: "Speaker",
                               basis: "The device advertises audio playback and nothing visual.",
                               strength: .likely,
                               source: .services)
        }
        if offering("HomeKit accessory") {
            return DeviceGuess(category: .iot, summary: "HomeKit accessory",
                               basis: "The device advertises itself as a HomeKit accessory.",
                               strength: .likely,
                               source: .services)
        }
        if offering("Computer") || offering("Screen sharing") {
            return DeviceGuess(category: .desktop, summary: "A computer",
                               basis: "The device advertises services that only a computer offers.",
                               strength: .possible,
                               source: .services)
        }
        if offering("File sharing") {
            return DeviceGuess(category: .storage, summary: "Shares files",
                               basis: "The device advertises file sharing, which a computer or a storage box may do.",
                               strength: .possible,
                               source: .services)
        }
        return nil
    }

    /// Names people and vendors give devices are informal but often plain.
    private static func nameGuess(_ rawName: String?) -> DeviceGuess? {
        guard let rawName else { return nil }
        // Drop any domain, so "iphone.lan" is read as "iphone".
        let name = rawName.lowercased().split(separator: ".").first.map(String.init) ?? rawName.lowercased()
        guard let keyword = keywordGuess(name) else { return nil }
        return DeviceGuess(category: keyword.category,
                           summary: keyword.summary,
                           basis: "Its name, \(rawName), says so.",
                           strength: .possible,
                           source: .name)
    }

    /// Distinctive words only. Short or ambiguous fragments are deliberately
    /// absent, because "cam" and "ap" match far too much.
    private static let keywords: [(needle: String, category: DeviceCategory, summary: String)] = [
        ("iphone",     .phone,         "iPhone"),
        ("ipad",       .tablet,        "iPad"),
        ("macbook air", .laptop,       "MacBook Air"),
        ("macbook pro", .laptop,       "MacBook Pro"),
        ("macbook",    .laptop,        "MacBook"),
        ("imac",       .desktop,       "iMac"),
        ("appletv",    .television,    "Apple TV"),
        ("apple-tv",   .television,    "Apple TV"),
        ("homepod",    .speaker,       "HomePod"),
        ("android",    .phone,         "Android phone"),
        ("pixel",      .phone,         "Pixel phone"),
        ("galaxy",     .phone,         "Galaxy phone"),
        ("laserjet",   .printer,       "Printer"),
        ("officejet",  .printer,       "Printer"),
        ("deskjet",    .printer,       "Printer"),
        ("printer",    .printer,       "Printer"),
        ("scanner",    .printer,       "Scanner"),
        ("doorbell",   .camera,        "Doorbell camera"),
        ("camera",     .camera,        "Camera"),
        ("synology",   .storage,       "Network storage"),
        ("qnap",       .storage,       "Network storage"),
        ("chromecast", .television,    "Chromecast"),
        ("firetv",     .television,    "Fire TV"),
        ("roku",       .television,    "Roku"),
        ("shield",     .television,    "NVIDIA Shield"),
        ("sonos",      .speaker,       "Sonos speaker"),
        ("echo",       .speaker,       "Amazon Echo"),
        ("thermostat", .iot,           "Thermostat"),
        ("ecobee",     .iot,           "Thermostat"),
        ("switch",     .networkSwitch, "Switch"),
        ("unifi",      .accessPoint,   "Ubiquiti equipment"),
        ("gateway",    .router,        "Gateway")
    ]

    private static func keywordGuess(_ text: String)
        -> (category: DeviceCategory, summary: String)? {
        for entry in keywords where text.contains(entry.needle) {
            return (entry.category, entry.summary)
        }
        return nil
    }

    // MARK: Manufacturer

    /// What the manufacturer alone implies, when it implies anything.
    private static func vendorGuess(_ vendor: String?) -> DeviceGuess? {
        guard let vendor else { return nil }
        let name = vendor.lowercased()

        for rule in rules {
            if rule.needles.contains(where: { name.contains($0) }) {
                return DeviceGuess(category: rule.category,
                                   summary: rule.summary,
                                   basis: rule.basis,
                                   strength: rule.strength,
                                   source: .manufacturer)
            }
        }

        if unrevealing.contains(where: { name.contains($0) }) {
            return DeviceGuess(
                category: nil,
                summary: "Made by \(vendor)",
                basis: "This company builds many kinds of hardware, or supplies the wireless part inside someone else's product, so the address does not say what the device is.",
                strength: .possible,
                source: .manufacturer)
        }
        return nil
    }
}
