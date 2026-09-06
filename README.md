# WifiHigh5

A macOS app for monitoring the current Wi-Fi connection. It runs in a standard
window and in the menu bar.

![Live Monitor](docs/live-monitor.png)

## What it shows

**Live Monitor** shows signal strength, noise, SNR, transmit rate, and a rolling
chart. It also gives a short status summary and a recommended next step.

The chart uses a separate colour for each access point. A colour change marks a
roam. Dashed vertical lines mark each connection change. Point to the chart to
see the reading at that time. Optional overlays show noise and transmit rate.

**Network Map** shows the path from this Mac to the access point and router. It
labels each item as measured, inferred, or unobserved. The map does not claim to
be a complete network inventory. Pan, zoom, or select a node to inspect its data.

**Observed Devices** lists IPv4 devices already present in the Mac's ARP cache.
It is passive and sends no packets. Quiet, isolated, and IPv6-only devices may
be absent.

**Access Points** lists each AP that served the connection. Search the list or
add a nickname, site, colour, and notes.

**Connection Changes** lists each association, roam, and reconnect. It shows the
signal before and after the change. It also flags roams to a weaker AP.

**Nearby Networks** runs an on-demand Wi-Fi scan. It shows nearby APs, channel
crowding, and other radios that serve the current network. AP count does not
measure airtime use or interference.

**Walkthroughs** records signal data while you walk through a site. Mark rooms
as you go, then export an HTML or CSV report.

**Diagnostics** shows permission status, sampling controls, storage paths, and
CSV export. It also explains the app's network activity.

Open **Help > WifiHigh5 Help** (Command-?) for definitions, useful ranges, and
troubleshooting steps.

## Naming access points

Select the **+** next to an AP name to add a nickname, site, notes, and chart
colour.

Nicknames are keyed to the AP's BSSID and stored locally as JSON at:

```
~/Library/Application Support/WifiHigh5/access-points.json
```

The app keeps this file on the Mac. Use the Access Points tab to export or import
names.

## The network map

The map shows signal and traffic paths. It does not show physical AP placement.
Line style shows the source of each connection:

| Style | Meaning |
|---|---|
| Solid blue | Measured from a system API |
| Solid amber | Inferred from measured data. The node shows the evidence. |
| Grey dashed | Not observable from this Mac |

If another service owns the default route, the map identifies that service. It
still shows the local Wi-Fi path.

The internet node is always dashed because the app does not test upstream
connectivity. The app cannot see switches between the AP and router. It marks
that part of the path as unobserved.

The app can infer that the router and AP are one device. It makes this inference
when their hardware addresses have the same vendor prefix and are close in
value. The inspector shows the evidence. The check excludes software-assigned
and multicast addresses.

The app identifies hardware vendors with an embedded copy of the IEEE MAC
registry. Vendor results also support the single-device inference.

The app does not download the database at runtime. To update the embedded copy,
run:

```bash
./tools/update-oui.sh
```

The script downloads the MA-L, MA-M, and MA-S registries from IEEE. It validates
the files and rebuilds `Resources/OUI.txt`. The current file contains 53,183
blocks. Vendor lookup uses the longest matching prefix.

The app does not assign a vendor to a randomized address. It reports that the
address was assigned by software.

"Observed Devices" comes from the Mac's ARP cache. The app limits results to the
active Wi-Fi interface and local subnet. The list is not a network inventory.
It can omit quiet, isolated, or IPv6-only hosts. The app does not probe these
addresses.

## Walking a site

The live chart shows current conditions. A walkthrough records conditions across
a site.

Start a recording from the **Walkthroughs** tab. Press **Command-M** and enter a
name when you reach each room.

Each room marker creates a waypoint. The app records its timestamp when you
press Command-M, before you enter the label. Reports group later readings by
waypoint. The app also offers recent labels for reuse.

The optional low-signal alert sounds when signal drops below the selected
threshold. It resets after the signal recovers by several dB.

The app saves completed walkthroughs on the Mac. **Export Report** creates one
self-contained HTML file. It includes a chart, room table, AP list, and method.
**Export CSV** assigns each reading to its waypoint.

The chart shades gaps caused by sleep or a paused session. It does not draw a
line across missing readings.

## Safe to run onsite

The app reads the current Wi-Fi link and assigned IP settings. It does not
capture traffic, probe other hosts, access credentials, or send telemetry.

Two optional features transmit network traffic:

- **Scan Now** sends standard Wi-Fi probe requests.
- **Gateway ping** sends one ICMP echo per second to the default router.

Both features are off by default. The Diagnostics tab describes their activity.

## The Location Services requirement

macOS classifies Wi-Fi network names as location data. Without Location Services,
the system hides the **SSID**, **BSSID**, and **country code**. Signal, noise,
SNR, channel, band, width, PHY mode, rate, and IP details remain available.

Grant access from the Live Monitor banner or from System Settings. The app does
not show the permission request at launch.

If macOS refuses access without a prompt, check these settings:

- System Settings ▸ Privacy & Security ▸ Location Services
- System Settings ▸ Screen Time ▸ Content & Privacy ▸ Location Services

Without a BSSID, the app uses SSID, channel, band, and security as an AP
fingerprint. Two APs can share this fingerprint. The interface marks these
results as `FINGERPRINT`.

## Building

Requires Xcode command line tools. The build script compiles, bundles and signs:

```bash
./build.sh
```

The result is `build/WifiHigh5.app`, which is then installed to
`/Applications`. That install step matters: the Location Services grant is bound
to the installed bundle's path, so running out of `build/` means re-granting
each time. Pass `SKIP_INSTALL=1` to build without installing.

Run the tests with:

```bash
./run-tests.sh
```

The tests cover signal calculations, AP identity, waypoints, export escaping,
permission states, subnet limits, topology, and large result sets.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌘P` | Pause / resume sampling |
| `⌘K` | Review and clear the session history |
| `⌘R` | Scan nearby networks |

## Notes

- Sampling runs at 1 s by default. You can select 0.5–5 s in Diagnostics.
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
