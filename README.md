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

**Access Points** — every AP this Mac has associated with, searchable, with the
signal range seen at each and the nickname, site and notes you gave it.

**Connection Changes** — every association, roam and reconnect, with the signal on both
sides of the change and the delta. A roam to a *weaker* radio is flagged, which
is the usual sticky-client signature.

**Nearby Networks** — an on-demand scan of everything in range, plus channel
crowding and a plain-language comparison of other radios serving the current
network. AP count is deliberately described as crowding, not measured airtime
utilization or interference. See the safety note below.

**Diagnostics** — permission state, sampling controls, where data is stored, CSV
export, and a plain-language statement of what the app does and does not do.

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

The result is `build/WiFi Signal Tester.app`. Drag it to `/Applications` if you
want it permanently installed.


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
  Model/      WiFiSample, AP identity and quality thresholds, nickname store
  Service/    CoreWLAN polling, IP/DHCP reads, ICMP pinger, scanner
  View/       Dashboard, chart, AP manager, roam log, scanner, diagnostics
Resources/    Info.plist, app icon
build.sh      Compile, bundle, sign
```
