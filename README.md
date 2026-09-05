# WiFi Signal Tester

A macOS menu-bar and window app for reading the Wi-Fi link this Mac is on, built
to be defensible to run on a client's network while you're onsite.

![Live Monitor](docs/live-monitor.png)

## What it shows

**Live Monitor** — starts with a plain-language verdict such as “The connection
looks solid,” “Noise is overpowering the signal,” or “The connection is losing
router replies,” plus the most useful next step. Raw signal, SNR and negotiated
rate remain visible alongside a rolling graph and deeper radio, AP, IP and
interface details.

The graph is the main instrument. The trace is drawn in the colour of whichever
access point was serving the link at that moment, so a roam appears as a colour
change rather than something you have to dig out of a log. Dashed vertical
markers show each transition. Hovering anywhere gives a readout for that instant.
Optional overlays put the noise floor and the transmit rate on the same plot.

**Network Map** — a vector schematic of the current Wi-Fi path, from this Mac
through the access point to the local router and an explicitly untested
upstream, plus clearly bounded local evidence. It is not presented as a full
network inventory. Pan and zoom; each node reveals more as you get closer,
clicking one shows its facts, sources and ages, and Jump To keeps a large
drawing navigable. See below.

**Access Points** — every AP this Mac has associated with, searchable, with the
signal range seen at each and the nickname, site and notes you gave it.

**Connection Changes** — every association, roam and reconnect, with the signal on both
sides of the change and the delta. A roam to a *weaker* radio is flagged, which
is the usual sticky-client signature.

**Nearby Networks** — an on-demand scan of everything in range, plus channel
crowding and a plain-language comparison of other radios serving the current
network. AP count is deliberately described as crowding, not measured airtime
utilization or interference. See the safety note below.

**Walkthroughs** — record a walk through a building, mark rooms as you go, and
export a report. See below.

**Diagnostics** — permission state, sampling controls, where data is stored, CSV
export, and a plain-language statement of what the app does and does not do.

Every reading in the app is explained in **Help ▸ WiFi Signal Tester Help**
(⌘?): what each number is, what a good value looks like, and what to do when it
isn't. It's a searchable reference kept out of the main window.

## Naming access points

Signal readings are only actionable once you know *which* radio you were on.
Click the **+** next to the AP name on the Live Monitor to give it a nickname, a
site or floor, free-form notes, and a fixed colour for the graph.

Nicknames are keyed to the AP's BSSID and stored locally as JSON at:

```
~/Library/Application Support/WiFi Signal Tester/access-points.json
```

They persist across launches and never leave the machine. Export and import from
the Access Points tab if you want to move a site's names to another Mac.

## The network map

A schematic, not a floor plan — it shows signal and traffic paths, which is what
the app can actually know. Physical placement it cannot.

What makes it useful is what it refuses to guess. Line style carries confidence:

| Style | Meaning |
|---|---|
| Solid blue | Measured — read directly from the system |
| Solid amber | Inferred — derived from measured facts, reasoning shown on the node |
| Grey dashed | Not observable — genuinely invisible from here |

If a VPN, Ethernet adapter or another service owns the default route, the map
calls that out rather than claiming all Internet traffic follows the Wi-Fi
gateway. It still shows the local Wi-Fi path that matters for onsite diagnosis.

So the internet node is always dashed: the app only ever talks to your own
router, and it will not imply it tested anything upstream. Because switches work
below the layer this Mac can see, the map inserts an explicit unobserved segment
between access point and router. That gap is where switching or controller
infrastructure may live; it is not invented as known equipment.

One inference it does make: when the router's MAC and the access point's BSSID
share a vendor prefix and sit within a few addresses of each other, they are
likely one physical box. The logical router and access-point roles remain
separate, joined by a solid amber Inferred link, and the inspector shows the
evidence so you can judge the reasoning. Software-assigned and multicast
addresses are excluded because adjacency there is not hardware evidence.

Hardware vendors are resolved against the IEEE MAC registry, which ships inside
the app. That is what lets the map say your gateway is a WNC Corporation box
rather than just showing a hex prefix — and it corroborates the same-chassis
inference independently, since both radios come back as the same manufacturer.

The database is embedded, never fetched at runtime. This tool is meant to run on
client networks, so it must not reach the network to answer a question about a
client's own hardware. Refresh it when you like:

```bash
./tools/update-oui.sh
```

That pulls the MA-L, MA-M and MA-S registries from `standards-oui.ieee.org`,
sanity-checks them, and regenerates `Resources/OUI.txt`; rebuild to embed. The
current copy holds 53,189 blocks. Lookups take the longest matching prefix, so a
company holding a 36-bit assignment inside another organisation's block is named
correctly rather than being attributed to the block holder.

Randomised addresses are never given a vendor. Where the second bit of the first
octet is set, the address was assigned by software rather than burned in, and
the map says so instead of naming a manufacturer that would be meaningless.

"Other IPv4 devices" comes from this Mac's own ARP cache, restricted to the
active Wi-Fi interface and local subnet so Ethernet, VPN and bridge entries do
not get mixed in. It is a bounded recent cache rather than an inventory; quiet
or IPv6-only hosts may be absent. Reading it is passive — no address is probed
and the subnet is never swept.

## Walking a site

The live graph answers "how is Wi-Fi right now". A walkthrough answers "how is
Wi-Fi across this building, and here's the evidence".

Start a recording from the **Walkthroughs** tab and every reading is kept for the
whole walk rather than the rolling hour the live view holds. Then, as you reach
each room, press **⌘M** and name it.

Waypoints are what make the result readable. Without them a walkthrough is an
unlabelled squiggle you reconstruct from memory; with them the report reads back
per place — *Reception −42 on the reception AP, east stairwell −78, roamed
twice*. The timestamp is captured the instant you press ⌘M rather than when you
finish typing, so the label lands on the reading that describes where you
actually were. Labels you've already used are offered for one-click reuse.

Turn on the **low-signal alert** and the app sounds once when signal drops
through your chosen threshold, so you can watch ceilings and floor plans instead
of the screen. It re-arms only after the signal recovers by a few dB, so a
reading sitting on the line won't chirp continuously.

Finished walkthroughs are saved to disk and can be reopened later. **Export
Report** produces a single self-contained HTML file — chart, per-room table, AP
inventory, and a statement of method — with no external dependencies, so it
opens anywhere and prints to PDF from any browser. **Export CSV** attributes
every reading to the room you were in when it was taken.

Gaps in sampling — the Mac slept, or you paused — are shaded on the graph and
break the trace rather than being drawn across, which would assert data that was
never measured.

## Safe to run onsite

The app is passive by default. It reads the state of the link this Mac has
already joined, from the OS, plus the IP settings this Mac was assigned. It does
not capture or inspect traffic, probe or scan other hosts, touch credentials, or
send anything off the machine — no telemetry, no cloud, no accounts.

Two features transmit, both off until you turn them on and both labelled where
they appear:

- **Scan Now** sends probe requests — the same frames as joining a network.
- **Gateway ping** sends one ICMP echo per second to your own default router,
  and to nothing else.

The Diagnostics tab states all of this in the app, so you can show it to whoever
asks what you're running.

## The Location Services requirement

macOS classifies Wi-Fi network names as location data. Without Location Services
the system withholds the **SSID**, the **BSSID** and the **country code** from
every app, including this one. Everything else — signal, noise, SNR, channel,
band, width, PHY mode, transmit rate, and all IP details — reads normally.

Grant it from the banner on the Live Monitor, or in System Settings ▸ Privacy &
Security ▸ Location Services. The app waits for you to use that banner instead
of showing a context-free permission prompt at launch.

If the app reports that the request was refused *without a prompt appearing*,
Location Services is either off for the whole Mac or blocked by a policy — Screen
Time's Content & Privacy restrictions is the usual culprit. Check both:

- System Settings ▸ Privacy & Security ▸ Location Services
- System Settings ▸ Screen Time ▸ Content & Privacy ▸ Location Services

Without a BSSID the app falls back to identifying APs by a radio fingerprint of
SSID, channel, band and security. That catches most roams, but two APs sharing a
channel look identical to it — so anywhere a fingerprint is in use the UI marks
it `FINGERPRINT` rather than quietly pretending it is certain.

## Building

Requires Xcode command line tools. The build script compiles, bundles and signs:

```bash
./build.sh
```

The result is `build/WiFi Signal Tester.app`, which is then installed to
`/Applications`. That install step matters: the Location Services grant is bound
to the installed bundle's path, so running out of `build/` means re-granting
each time. Pass `SKIP_INSTALL=1` to build without installing.

Run the tests with:

```bash
./run-tests.sh
```

They cover the arithmetic and topology claims that end up in front of a client:
quality thresholds, missing noise, access-point identity, waypoint attribution,
export escaping, no-permission paths, same-chassis confidence, subnet scoping,
stable map identities, and explicit grouping of large result sets.


## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘P` | Pause / resume sampling |
| `⌘K` | Review and clear the session history |
| `⌘R` | Scan nearby networks |

## Notes

- Sampling runs at 1 s by default; 0.5–5 s is selectable in Diagnostics.
- History is held in memory as a rolling one-hour window at every sampling rate,
  and starts fresh each launch.
  Export to CSV before quitting if you need to keep a walkthrough.
- Closing the window leaves the app running in the menu bar, which shows live
  signal while you walk a site. Quit from the menu bar panel.

## Layout

```
Sources/
  Model/      WiFiSample, AP identity, quality thresholds, nickname store,
              saved walkthroughs
  Service/    CoreWLAN polling, IP/DHCP reads, ICMP pinger, scanner, reports
  View/       Dashboard, chart, AP manager, change log, walkthroughs, scanner,
              diagnostics, help
Tests/        Model and export checks
Resources/    Info.plist, entitlements, app icon
build.sh      Compile, bundle, sign, install
run-tests.sh  Compile and run the checks
```
