import Foundation

/// The reference text behind the Help window.
///
/// Each topic defines a value, gives a useful range, and lists relevant actions.
enum HelpContent {

    static let topics: [HelpTopic] = signal + radio + accessPoints + walkthroughs + networkMap + network + permissions + shortcuts

    // MARK: Signal & quality

    private static let signal: [HelpTopic] = [
        HelpTopic(
            term: "Signal strength (RSSI)",
            category: .signal,
            short: "How loud the access point sounds to this Mac, in dBm. Closer to zero is stronger.",
            body: [
                "RSSI is measured in dBm, or decibels relative to one milliwatt. Wi-Fi values are negative. −40 dBm is strong, while −85 dBm is very weak.",
                "The scale is logarithmic, not linear. Every 3 dB is roughly a doubling or halving of power, and every 10 dB is a factor of ten. That is why the difference between −50 and −60 matters far more than the single digit change suggests.",
                "Signal strength alone does not determine whether the connection works well. A strong signal on a congested or noisy channel can still perform poorly. Check signal clarity with signal strength."
            ],
            scale: [
                ("Excellent", "−50 dBm and up", "Full performance. Anything works, including large transfers."),
                ("Good", "−50 to −60 dBm", "Solid. Video calls and sustained transfers are reliable."),
                ("Fair", "−60 to −67 dBm", "Usable, with reduced throughput. Watch for retries under load."),
                ("Weak", "−67 to −75 dBm", "Marginal. Expect stalls, slow transfers and dropped calls."),
                ("Poor", "below −75 dBm", "Unreliable. Likely to disconnect or fail outright.")
            ]
        ),
        HelpTopic(
            term: "Noise floor",
            category: .signal,
            short: "Background radio energy on your channel. Lower (more negative) is better.",
            body: [
                "The noise floor is everything on the channel that is not your signal: other networks, Bluetooth, microwave ovens, cordless phones, poorly shielded equipment, and general electrical noise.",
                "A clean environment typically sits around −90 to −95 dBm. Readings of −80 dBm or higher suggest real interference nearby, and that raised floor eats into the headroom your signal has to work with.",
                "Some Wi-Fi drivers do not report a noise floor at all. When that happens the app shows “Not reported” rather than inventing a value, and signal clarity cannot be graded."
            ],
            scale: [
                ("Clean", "−90 dBm or lower", "Little interference. Your signal has full headroom."),
                ("Typical", "−85 to −90 dBm", "Normal office environment."),
                ("Elevated", "−80 to −85 dBm", "Noticeable interference. Throughput may suffer."),
                ("Noisy", "above −80 dBm", "Significant interference. Investigate the source or change channel.")
            ]
        ),
        HelpTopic(
            term: "Signal clarity (SNR)",
            category: .signal,
            short: "The gap between your signal and the background noise. The best single predictor of real speed.",
            body: [
                "Signal-to-noise ratio is signal strength minus the noise floor. A signal of −55 dBm with a −90 dBm noise floor gives 35 dB of clarity.",
                "This matters more than raw signal strength because Wi-Fi radios choose their data rate based on how cleanly they can hear each other. A weak signal in a quiet room often outperforms a strong signal in a noisy one.",
                "If signal strength looks acceptable but performance is poor, low clarity is the usual explanation. The fix is usually a different channel or removing the interference source, not moving closer."
            ],
            scale: [
                ("Excellent", "40 dB and up", "Maximum data rates available."),
                ("Good", "25 to 40 dB", "Reliable for video calls and large transfers."),
                ("Fair", "15 to 25 dB", "Works, but limited headroom under load."),
                ("Weak", "10 to 15 dB", "Frequent retries. Calls will suffer."),
                ("Poor", "below 10 dB", "The link struggles to carry data at all.")
            ]
        ),
        HelpTopic(
            term: "Variation (stability)",
            category: .signal,
            short: "How much the signal moved over the last minute. Steady is better than strong-but-swinging.",
            body: [
                "This is the average distance between each reading and the mean for the selected period. It measures signal variation.",
                "Under about ±3 dB is steady. Above roughly ±7 dB the signal is changing quickly, which usually means you are walking, standing at the edge of a coverage cell, or something is intermittently blocking the path.",
                "Investigate high variation while standing still. It often points to intermittent interference or to a client between two access points with similar signal strength."
            ]
        ),
        HelpTopic(
            term: "Transmit rate",
            category: .signal,
            short: "The last rate negotiated by the radios. This is not measured throughput.",
            body: [
                "This is the physical-layer rate the Mac and the access point agreed on for the most recent frames. It is not a speed test and does not tell you what a file transfer will achieve.",
                "Real throughput is typically somewhere between a third and a half of this figure once protocol overhead, airtime shared with other clients, and retries are accounted for.",
                "A falling rate while you walk indicates that the link is degrading. The rate can fall before signal strength changes enough to show a problem."
            ]
        ),
        HelpTopic(
            term: "Transmit power",
            category: .signal,
            short: "How hard this Mac's own radio is driving, in milliwatts.",
            body: [
                "This reflects the Mac's transmit power, not the access point's. macOS adjusts it based on the regulatory domain and power-saving state.",
                "This value is informational. A low value with weak signal can mean that the Mac is conserving power."
            ]
        )
    ]

    // MARK: Radio & channels

    private static let radio: [HelpTopic] = [
        HelpTopic(
            term: "Band (2.4, 5 and 6 GHz)",
            category: .radio,
            short: "Which slice of spectrum you are on. Each trades range against speed and congestion.",
            body: [
                "2.4 GHz travels furthest and penetrates walls best, but has only three non-overlapping channels and shares its spectrum with Bluetooth, microwaves and cordless phones. It is almost always the most congested band.",
                "5 GHz offers far more channels and much higher speeds, at the cost of shorter range and weaker wall penetration. It is the right default for most office coverage.",
                "6 GHz (Wi-Fi 6E) adds a large block of clean spectrum with very little legacy congestion, but the shortest range of the three. It requires WPA3 and a client that supports it.",
                "A Mac on 2.4 GHz when 5 GHz is available can indicate a connection to a distant access point. Check this during a walkthrough."
            ]
        ),
        HelpTopic(
            term: "Channel",
            category: .radio,
            short: "The specific frequency your access point is using within its band.",
            body: [
                "On 2.4 GHz only channels 1, 6 and 11 avoid overlapping each other. Any other choice bleeds into its neighbours, so a site using channels 3 and 8 is interfering with itself.",
                "On 5 GHz there are many more channels, but some are shared with weather and military radar. Those DFS channels must be vacated immediately if radar is detected, which shows up as an abrupt channel change and a brief interruption.",
                "The Nearby Networks tab counts how many access points share each channel, which is the quickest way to spot a congested one."
            ]
        ),
        HelpTopic(
            term: "Channel width",
            category: .radio,
            short: "How much spectrum each transmission uses. Wider is faster but less resilient.",
            body: [
                "Doubling the width can double the theoretical speed. A 20 MHz channel is the narrowest and most resistant to interference. Wider channels can provide more throughput.",
                "Wider channels also collide with more neighbours and are more vulnerable to interference. In a dense environment a 40 MHz channel frequently outperforms an 80 MHz one in practice.",
                "On 2.4 GHz, channels wider than 20 MHz overlap more of the available spectrum."
            ]
        ),
        HelpTopic(
            term: "PHY mode (Wi-Fi generation)",
            category: .radio,
            short: "The Wi-Fi standard negotiated for the current link.",
            body: [
                "802.11n is Wi-Fi 4, 802.11ac is Wi-Fi 5, 802.11ax is Wi-Fi 6 and 6E, and 802.11be is Wi-Fi 7. The mode shown is what this link negotiated, not the best the hardware supports.",
                "An 802.11n connection can mean that the Mac uses 2.4 GHz or an older access point. It can also indicate a coverage gap."
            ]
        ),
        HelpTopic(
            term: "Security",
            category: .radio,
            short: "How the link is encrypted. Open networks carry no link-layer encryption at all.",
            body: [
                "WPA3 is current. WPA2 remains common and acceptable. WPA and WEP are obsolete and should be treated as findings if you encounter them on a client site.",
                "An Open network has no link-layer encryption. Anyone in range can read unencrypted traffic. The app flags this in red because it requires attention.",
                "Enhanced Open (OWE) encrypts traffic without a password. It provides more protection than an open guest network."
            ]
        ),
        HelpTopic(
            term: "Country code",
            category: .radio,
            short: "The regulatory domain the radio is operating under.",
            body: [
                "This determines which channels and power levels are legal. It is normally set automatically from the access point's beacons.",
                "A country code that does not match where you are standing can restrict available channels and is occasionally the explanation for an access point that cannot be seen on certain frequencies."
            ]
        )
    ]

    // MARK: Access points

    private static let accessPoints: [HelpTopic] = [
        HelpTopic(
            term: "SSID and BSSID",
            category: .accessPoints,
            short: "The SSID is the network name. The BSSID is the individual radio you are talking to.",
            body: [
                "A single SSID such as “Acme-Corp” may be broadcast by dozens of access points across a building. The BSSID is the MAC address of the one specific radio serving you right now.",
                "This distinction is important during a walkthrough. “Signal is poor” does not identify the affected radio. “Signal is poor on the radio ending :8e:fa in the north corridor” does.",
                "macOS treats network names as location data, so both values are withheld unless Location Services is granted. Without them the app falls back to identifying access points by their radio characteristics."
            ]
        ),
        HelpTopic(
            term: "Nicknames",
            category: .accessPoints,
            short: "Your own name for an access point, stored only on this Mac.",
            body: [
                "A name such as “Reception ceiling” is easier to recognize than a BSSID. The app uses this name in charts, logs, exports, and reports.",
                "You can also record a site, floor, and notes. Assign a colour to identify the same access point on the graph.",
                "Nicknames are written to a JSON file in Application Support on this Mac and are never transmitted. They can be exported and imported if you want to move a site's names to another machine."
            ]
        ),
        HelpTopic(
            term: "Fingerprint identity",
            category: .accessPoints,
            short: "A fallback used when macOS withholds the BSSID. Less precise, and labelled as such.",
            body: [
                "Without Location Services there is no BSSID, so the app identifies access points by a fingerprint of network name, channel, band and security instead.",
                "This catches most transitions, because neighbouring access points are normally placed on different channels to avoid interfering with each other. But two access points sharing a channel are indistinguishable to it, and one access point that changes channel looks like a new one.",
                "Anywhere a fingerprint is in use the interface marks it rather than implying certainty it does not have. Granting Location Services replaces it with true BSSID identity."
            ]
        ),
        HelpTopic(
            term: "Connection changes and roaming",
            category: .accessPoints,
            short: "Every time the Mac switched access points, with the signal on both sides.",
            body: [
                "Roaming is the Mac deciding to hand off from one access point to another. Healthy roaming happens promptly and moves you to a stronger radio.",
                "A change that lands on a weaker signal is flagged. That is the classic sticky-client pattern: the Mac held on to a distant access point too long and only let go once the connection had already degraded.",
                "Identity resolved is not a roam. It appears when Location Services is granted mid-session and the app learns the BSSID of the access point it was already on."
            ]
        )
    ]

    // MARK: Walkthroughs

    private static let walkthroughs: [HelpTopic] = [
        HelpTopic(
            term: "Recording a walkthrough",
            category: .walkthroughs,
            short: "Captures every reading for a whole walk, not just the recent window.",
            body: [
                "The live graph keeps a rolling window in memory and starts fresh each launch, which suits a quick check but loses a walk.",
                "A recording keeps every reading from start to stop, along with the transitions and the spots you marked, and saves it to disk so you can reopen it later or export a report.",
                "Recordings are stored on this Mac only. Bear in mind that a named recording of a client's site is a record of their infrastructure, so delete them when an engagement ends if that matters to you."
            ]
        ),
        HelpTopic(
            term: "Marked spots (waypoints)",
            category: .walkthroughs,
            short: "Press ⌘M to label where you are. This is what makes a walk readable afterwards.",
            body: [
                "Without labels a walkthrough is an unlabelled squiggle you have to reconstruct from memory. With them the report reads back per place: “Reception −42, east stairwell −78, roamed twice”.",
                "The app records the timestamp when you press ⌘M. It does not wait until you finish entering the name.",
                "Labels you have already used are offered for one-click reuse, which matters when the same names repeat on every floor.",
                "In reports and CSV exports, every reading is attributed to the most recent spot marked before it, so the data groups by place automatically."
            ]
        ),
        HelpTopic(
            term: "Low-signal alert",
            category: .walkthroughs,
            short: "An audible warning when signal drops below a threshold, so you can watch the building.",
            body: [
                "While walking a site you want to be looking at ceilings, walls and floor plans, not at a laptop screen. The alert sounds once when the signal crosses below your chosen level.",
                "It re-arms only after the signal recovers by a few dB, so a reading hovering on the threshold does not chirp continuously.",
                "−67 dBm is the usual choice, since that is the practical floor for voice and video."
            ]
        ),
        HelpTopic(
            term: "Sampling gaps",
            category: .walkthroughs,
            short: "Shaded areas on the graph where nothing was measured.",
            body: [
                "If the Mac sleeps, sampling is paused, or the app is suspended, no readings exist for that period.",
                "The graph breaks the trace and shades the gap. It does not draw a line across a period with no readings."
            ]
        )
    ]

    // MARK: Network map

    private static let networkMap: [HelpTopic] = [
        HelpTopic(
            term: "Reading the network map",
            category: .networkMap,
            short: "A schematic of the current Wi-Fi path, drawn only from what this Mac can see.",
            body: [
                "The map runs from this Mac at the bottom, through the access point serving it, to the Wi-Fi subnet's router and then to an explicitly untested upstream. It is the current Wi-Fi path plus local evidence, not a complete network inventory. Zoom in to reveal more, click a node to see all of its facts and sources, or use Jump To when the drawing is large.",
                "If a VPN, Ethernet adapter or another service owns the Mac's default route, the map calls that out. It continues to show the local Wi-Fi path for onsite diagnosis without claiming that all Internet traffic follows it.",
                "Line style identifies measured, inferred, and unobserved connections. The map includes an unobserved segment when this Mac cannot read part of the path.",
                "Facts gathered at different times show their source and age in the inspector. Nearby access-point readings are snapshots from the last user-requested scan. Refresh them after moving around a site."
            ],
            scale: [
                ("Measured", "solid blue", "Read directly from the system. This is fact."),
                ("Inferred", "solid amber", "Derived from measured facts, with the reasoning shown on the node."),
                ("Not observable", "grey dashed", "This Mac cannot observe this part of the path.")
            ]
        ),
        HelpTopic(
            term: "Router and access point in one box",
            category: .networkMap,
            short: "A likely shared chassis is an inference from the MAC addresses.",
            body: [
                "Manufacturers assign consecutive hardware addresses to the interfaces of a single chassis. When the router's MAC and the access point's BSSID share a vendor prefix and sit within a few addresses of each other, they are almost certainly the same physical device.",
                "Router and access point remain separate logical nodes so their measured roles stay clear. The link between them is solid amber and labelled Inferred, and the access-point inspector shows the addresses and method so you can judge the reasoning yourself.",
                "Software-assigned and multicast addresses are excluded from this inference because adjacency in those address ranges says nothing reliable about physical hardware.",
                "On a larger site, the map shows an unobserved path between these roles. Switches or controller infrastructure can exist in this segment."
            ]
        ),
        HelpTopic(
            term: "Why the switching path is unknown",
            category: .networkMap,
            short: "Switches work below the layer this Mac can see.",
            body: [
                "Switches can forward frames without an IP address in the path. Detection requires LLDP, CDP, or management access. This app does not use those sources.",
                "Rather than drawing a tidy line straight from access point to router and implying there is nothing between, the map inserts an explicit unobserved segment. Anything in that gap is real but invisible from here."
            ]
        ),
        HelpTopic(
            term: "Observed devices",
            category: .networkMap,
            short: "Hosts already in this Mac's neighbour cache. Nothing was scanned.",
            body: [
                "These are IPv4 neighbours from the cache macOS already keeps for hosts this Mac has exchanged traffic with. The app limits the list to the active Wi-Fi interface and subnet. Refresh Cache reads that cache again. It never probes an address, sweeps a range, or opens a port.",
                "This is a recent cache, not a device inventory. A device that has been quiet, is isolated by client isolation, or speaks only IPv6 will not appear. Absence from this list is not evidence that a device is absent from the network.",
                "Roles are taken from settings this Mac already holds: the gateway it was told to use, the DHCP server that issued its lease, the name servers it was given, and the BSSID of the radio it is associated with. When the gateway's address sits in the same vendor block and within a few addresses of that BSSID, one box is doing both jobs and the row says so.",
                "Arrived and dropped out are worked out by comparing successive reads. Everything in the first read is treated as already present; anything appearing later arrived while you were watching. A device is only called gone after it has been missing from two consecutive reads, because the cache expires idle entries on its own schedule.",
                "This history lives in memory and lasts as long as the app is running. It is never written to disk."
            ]
        ),
        HelpTopic(
            term: "Naming devices",
            category: .networkMap,
            short: "Your own labels for client hardware, stored on this Mac only.",
            body: [
                "Double-click any row, or use its context menu, to give a device a name, a type and a note. A named device keeps that name wherever it appears, and the name follows the hardware address rather than the IP, so it survives a new DHCP lease.",
                "The type is a label you apply, not something the app detects. Telling a printer from a camera would mean probing the device, which this app does not do.",
                "Labels are written to this Mac's Application Support folder, and only for devices you have actually named, typed or annotated. A device you merely looked at leaves nothing on disk after the app quits. Forget This Label removes one; Forget All Labels removes every one.",
                "Export Labels writes a file you can carry to another Mac. Import keeps your existing names when the two files disagree."
            ]
        ),
        HelpTopic(
            term: "Suggested device type",
            category: .networkMap,
            short: "What a device most likely is, and which evidence said so.",
            body: [
                "The row icon and the line beneath the name come from the strongest evidence available, in this order: a model the device published, the name it answers to, the services it offers, and finally the company that made its address.",
                "A published model is exact, so \u{201C}iPhone14,2\u{201D} settles it. A name is next, because people name things plainly and a device called \u{201C}MacBook Air\u{201D} is one. Services come after names rather than before, because a Mac advertises AirPlay exactly as an Apple TV does: what a device offers often cannot tell two devices apart, but what it is called usually can.",
                "The IEEE registry is last. It says which company owns a hardware address, and for many companies that narrows what the device is: a firm that only builds printers is unlikely to be on the network as anything else, so the row says \u{201C}Likely a printer\u{201D}.",
                "The manufacturer step needs nothing from the device and is always on. The other three need a name or a model, which only arrive if you have run Identify, so a device you have not asked about is typed from its maker or not at all.",
                "None of this is a measurement, which is why it is worded as a likelihood and sits below the name rather than replacing it.",
                "Companies that build many kinds of product, or that supply the wireless module inside someone else\u{2019}s product, get no type at all. Apple builds phones, tablets, computers, watches and speakers, so the address cannot say which, and the app declines to guess rather than guessing badly.",
                "A randomised address is never typed, because the prefix belongs to no manufacturer.",
                "Your own label always wins. Once you set a type on a device, the suggestion is gone."
            ]
        ),
        HelpTopic(
            term: "Asking devices to identify themselves",
            category: .networkMap,
            short: "Optional Bonjour queries that collect the names devices publish.",
            body: [
                "Everything else in this tab reads a cache your Mac already had. This is different: it transmits. It sends Bonjour queries on the local subnet and asks anything that answers to describe itself, which is how the app learns names like \u{201C}Reception LaserJet\u{201D} and services like printing, AirPlay or file sharing.",
                "It is off until you run it, it asks first and says what it will send, and it stops on its own after a few seconds. It is never triggered by opening the tab.",
                "What it costs: the queries are visible to anything watching the network. Ordinary Macs, phones and printers send them constantly, so one is unremarkable, but a burst from a single machine can be logged as network discovery, and some monitoring treats discovery as reconnaissance. Use it on a network you have been asked to work on.",
                "Many networks isolate clients from one another, which blocks this entirely. Getting nothing back is a normal result and says nothing about the devices.",
                "Rows carrying anything obtained this way are marked Asked, and the CSV export records which rows those were."
            ]
        ),
        HelpTopic(
            term: "Looking up names in DNS",
            category: .networkMap,
            short: "Optional reverse lookups. The most visible thing the app can do.",
            body: [
                "This sends one reverse lookup for each address to the name servers this network gave your Mac, and returns the hostnames the network holds for its own clients.",
                "Home and small-office networks usually keep no such records and will return nothing. Managed networks often do, which is where this earns its place.",
                "What it costs: the DNS server logs every lookup, recording your Mac as the source alongside each internal address you asked about. DNS logs are reviewed far more often than Wi-Fi traffic, and a run of reverse lookups across one subnet reads plainly as someone enumerating the network. This is the most visible thing this app can do, and it asks before doing it.",
                "Use it on a managed network where you have been asked to document what is connected."
            ]
        ),
        HelpTopic(
            term: "IP address",
            category: .network,
            short: "The address a device holds on this subnet, issued by DHCP or set by hand.",
            body: [
                "An IPv4 address identifies a device on one network. The subnet mask decides which part is the network and which part is the host, and the app uses it to keep neighbours from other interfaces, VPNs and bridges out of this list.",
                "An address is not a permanent name for a device. A DHCP lease can hand the same address to different hardware over time, which is why names in this app follow the hardware address instead."
            ]
        ),
        HelpTopic(
            term: "MAC address",
            category: .network,
            short: "The hardware address of a network interface, and the key names are stored against.",
            body: [
                "A MAC address identifies one network interface. The first three octets are the manufacturer's registered prefix, which is how the app names the vendor without asking the device anything.",
                "The second-lowest bit of the first octet marks an address as locally administered, meaning software chose it rather than the manufacturer burning it in. Modern phones and laptops do this per network, and virtual interfaces do it too. The app flags those as private, because the prefix identifies nothing.",
                "This app stores your device names against the MAC address, so a device keeps its name when its IP changes."
            ]
        ),
        HelpTopic(
            term: "Hardware vendors",
            category: .networkMap,
            short: "Resolved from the IEEE registry, which ships inside the app.",
            body: [
                "Every manufacturer registers blocks of MAC addresses with the IEEE, so the first part of an address identifies who built the hardware. The app carries a copy of that registry and resolves router, access point and neighbour addresses against it.",
                "The registry assigns blocks in three sizes, and a small block sits inside a larger shared one. The app always takes the longest match, so a company holding a 36-bit assignment inside another organisation's prefix is named correctly rather than being attributed to the block holder.",
                "The database is embedded in the app. The app does not download it at runtime. Run tools/update-oui.sh and rebuild to update the database.",
                "A randomised address has no manufacturer to find. Where the second bit of the first octet is set, the address was assigned by software rather than burned in, and the app says so instead of naming a vendor that would be meaningless."
            ]
        ),
        HelpTopic(
            term: "Randomised addresses",
            category: .networkMap,
            short: "Software-assigned MACs that identify nothing about the hardware.",
            body: [
                "Phones and laptops increasingly present a different MAC address to every network they join, and virtual interfaces invent addresses too. These are flagged as locally administered by a bit in the address itself.",
                "A software-assigned address does not identify a hardware vendor. DHCP logs show this address instead of the permanent hardware address.",
                "Many randomized addresses can indicate a guest network or a group of modern client devices."
            ]
        )
    ]

    // MARK: Network & IP

    private static let network: [HelpTopic] = [
        HelpTopic(
            term: "Gateway reachability test",
            category: .network,
            short: "Optional ping to your own router, measuring latency, jitter and packet loss.",
            body: [
                "This sends one ICMP echo per second to the default gateway and nowhere else. It is off until you turn it on, and it never contacts anything beyond your own router.",
                "Latency under about 10 ms to the gateway is normal on a healthy wireless link. Rising latency with a strong signal usually points at congestion rather than coverage.",
                "Packet loss to the gateway is the strongest evidence that a problem is real rather than cosmetic. Loss with a strong signal generally means interference, a saturated channel, or a problem on the access point's wired uplink.",
                "Jitter is the variation in round-trip time. High jitter is what makes calls choppy even when average latency looks acceptable."
            ]
        ),
        HelpTopic(
            term: "Private Wi-Fi address",
            category: .network,
            short: "macOS presents a different MAC address per network unless you disable it.",
            body: [
                "By default macOS rotates a private MAC address for each network it joins, so the address on the wire differs from the adapter's real hardware address.",
                "This matters onsite: if a client is filtering by MAC address, or looking you up in their DHCP or RADIUS logs, they need the active address, not the hardware one. The app shows both and flags when they differ."
            ]
        ),
        HelpTopic(
            term: "DHCP lease",
            category: .network,
            short: "The address you were assigned, who assigned it, and when it expires.",
            body: [
                "A very short lease can indicate a constrained address pool, which on a busy guest network sometimes explains intermittent connection failures.",
                "The DHCP server address is often the same device as your default gateway. Check a mismatch on an unfamiliar network."
            ]
        )
    ]

    // MARK: Permissions & privacy

    private static let permissions: [HelpTopic] = [
        HelpTopic(
            term: "Why Location Services is required",
            category: .permissions,
            short: "macOS classifies Wi-Fi network names as location data.",
            body: [
                "Access points can be looked up in public databases that map them to physical locations, which is how Wi-Fi positioning works. Because of that, macOS treats the SSID and BSSID as revealing your position and withholds both from any app without Location Services.",
                "The gate is about your position, not the client's data. Granting it lets the app read the network name and the access point identifier of the link this Mac has already joined.",
                "This app never requests a location fix. It asks for the authorisation once, and after that only reads the network identifiers. Nothing about your position is recorded, stored or transmitted.",
                "Signal, noise, clarity, channel, band, width, transmit rate, and IP details remain available without permission."
            ]
        ),
        HelpTopic(
            term: "What this app does on a client network",
            category: .permissions,
            short: "It listens. Two features transmit, both off until you switch them on.",
            body: [
                "By default the app only reads the state of the link this Mac has already joined, plus the IP settings this Mac was assigned. It captures no traffic, probes no other hosts, touches no credentials, and sends nothing off the machine.",
                "A nearby-network scan sends standard Wi-Fi probe requests. The scan starts only when you press the button.",
                "The gateway test sends ICMP echo to your own default router and to nothing else. It is off by default.",
                "The Diagnostics tab states all of this inside the app, so you can show it to whoever asks what you are running."
            ]
        ),
        HelpTopic(
            term: "Where your data is stored",
            category: .permissions,
            short: "Access point nicknames and saved walkthroughs, on this Mac only.",
            body: [
                "Both live in Application Support on this Mac. Nothing is uploaded, and there are no accounts or telemetry.",
                "Access point names can identify client infrastructure. Saved walkthroughs can contain the same type of information. Delete individual records when an engagement ends."
            ]
        )
    ]

    // MARK: Shortcuts

    private static let shortcuts: [HelpTopic] = [
        HelpTopic(
            term: "Keyboard shortcuts",
            category: .shortcuts,
            short: "Shortcuts for a site walkthrough.",
            body: [
                "⌘M marks the current location and records the time.",
                "⌘P pauses or resumes sampling. A paused chart does not scroll.",
                "⌘K clears the current session and starts fresh.",
                "⌘R scans nearby networks. Remember that scanning transmits.",
                "⌘? opens this help window."
            ]
        )
    ]
}

// MARK: - Label lookup

/// Maps the short labels the interface uses onto the help topic that explains
/// them, so hover help and the Help window never drift apart.
///
/// Labels with no exact match do not receive a help topic.
enum HelpIndex {

    private static let aliases: [String: String] = [
        "signal (rssi)":   "Signal strength (RSSI)",
        "signal":          "Signal strength (RSSI)",
        "current":         "Signal strength (RSSI)",
        "average":         "Signal strength (RSSI)",
        "best":            "Signal strength (RSSI)",
        "worst":           "Signal strength (RSSI)",
        "range seen":      "Signal strength (RSSI)",
        "noise floor":     "Noise floor",
        "snr":             "Signal clarity (SNR)",
        "signal clarity":  "Signal clarity (SNR)",
        "clarity (snr)":   "Signal clarity (SNR)",
        "variation":       "Variation (stability)",
        "stability":       "Variation (stability)",
        "tx rate":         "Transmit rate",
        "rate":            "Transmit rate",
        "negotiated rate": "Transmit rate",
        "tx power":        "Transmit power",
        "band":            "Band (2.4, 5 and 6 GHz)",
        "channel":         "Channel",
        "channel width":   "Channel width",
        "width":           "Channel width",
        "phy mode":        "PHY mode (Wi-Fi generation)",
        "standard":        "PHY mode (Wi-Fi generation)",
        "security":        "Security",
        "country":         "Country code",
        "regulatory domain": "Country code",
        "ssid":            "SSID and BSSID",
        "bssid":           "SSID and BSSID",
        "network":         "SSID and BSSID",
        "nickname":        "Nicknames",
        "private address": "Private Wi-Fi address",
        "active mac":      "Private Wi-Fi address",
        "hardware mac":    "Private Wi-Fi address",
        "mac on the wire": "Private Wi-Fi address",
        "dhcp server":     "DHCP lease",
        "lease expires":   "DHCP lease",
        "latency":         "Gateway reachability test",
        "jitter":          "Gateway reachability test",
        "packet loss":     "Gateway reachability test",
        "gateway":         "Gateway reachability test",
        "target":          "Gateway reachability test",
        "changes":         "Connection changes and roaming",
        "roams":           "Connection changes and roaming",
        "spots":           "Marked spots (waypoints)",
        "vendor":          "Hardware vendors",
        "vendor database": "Hardware vendors",
        "vendor prefix":   "Hardware vendors",
        "access points":   "SSID and BSSID",
        "observed devices": "Observed devices",
        "ip address":      "IP address",
        "ip":              "IP address",
        "mac address":     "MAC address",
        "mac":             "MAC address",
        "manufacturer":    "Hardware vendors",
        "arrived":         "Observed devices",
        "dropped out":     "Observed devices",
        "departed":        "Observed devices",
        "seen":            "Observed devices",
        "naming devices":  "Naming devices",
        "suggested type":  "Suggested device type",
        "likely a printer": "Suggested device type",
        "identify":        "Asking devices to identify themselves",
        "bonjour":         "Asking devices to identify themselves",
        "asked":           "Asking devices to identify themselves",
        "advertised name": "Asking devices to identify themselves",
        "reverse dns":     "Looking up names in DNS",
        "dns name":        "Looking up names in DNS",
        "device name":     "Naming devices",
        "other devices":   "Observed devices",
        "saved aps":       "Where your data is stored"
    ]

    /// Resolves a label to its topic, tolerating case and trailing colons.
    static func topic(forLabel label: String) -> HelpTopic? {
        let key = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()
        guard let term = aliases[key] else { return nil }
        return HelpContent.topics.first { $0.term == term }
    }
}
