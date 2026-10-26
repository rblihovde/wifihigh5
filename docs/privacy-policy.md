# WifiHigh5 Privacy Policy

**Last updated: 24 October 2026**

WifiHigh5 does not collect or share personal data. There are no accounts,
analytics, crash reporting or advertising. An Internet speed test you start
transfers generated test traffic to Cloudflare as described below.

## What the app reads

Everything the app shows is read from the Mac it is running on:

- The state of the current Wi-Fi link, including signal strength, noise, channel,
  band, transmit rate, network name and access point identifier.
- The assigned IP address, subnet, router, DNS servers and DHCP lease.
- The kernel's existing ARP and IPv6 neighbour caches, which list hosts this Mac has already
  exchanged traffic with in the normal course of being connected. Nothing is
  scanned or probed to produce them. The Observed Devices view displays these
  existing entries, and stores nothing about a device unless you give that
  device a name, type or note.

## What the app stores

Three things, all on your Mac only, inside the app's sandbox container:

- **Access point names.** Any nickname, site label, note or colour you choose.
- **Device labels.** A name, type or note you give a device on the Observed
  Devices tab, and only for devices you have labelled.
- **Saved walkthroughs.** Recordings you explicitly start, including the
  readings taken and the places you marked.

You can delete any of them at any time from within the app. Neither is uploaded
anywhere, and the developer has no access to them.

## Location

macOS classifies Wi-Fi network names as location data and withholds the network
name (SSID) and access point identifier (BSSID) from any app that has not been
granted Location Services. The app requests that permission solely to read
those two values.

The app never requests your position. No coordinate is ever obtained, stored or
transmitted. If you decline the permission, the app still works. Only the
network name and access point identifier are unavailable.

## Network activity

The app performs no network communication on its own. Active features transmit
only after you invoke them, and each is labelled where it appears:

- **Scanning for nearby access points** sends standard Wi-Fi probe requests,
  the same frames any device sends when joining a network.
- **The gateway check** sends ICMP echo requests to your own default router and
  to no other address.
- **Asking devices to identify themselves** sends Bonjour queries on the local
  network and resolves the services devices advertise, to learn the names they
  publish for themselves.
- **Looking up names in DNS** sends one reverse lookup for each observed local
  address to the name servers your network gave your Mac.
- **Scanning the LAN or a custom range** sends ICMP echo and fallback TCP
  connection attempts to the IPv4 addresses you select. The optional full scan
  checks the TCP ports you enter and can browse Bonjour, look up DNS, and ask
  for Windows/SMB computer and domain names. An optional link-local IPv6 echo
  asks active IPv6 neighbors to populate the system cache. It sends no
  credentials, fetches no pages, and performs no vulnerability tests.
- **Running an Internet speed test** sends requests to Cloudflare's nearest
  edge. The test downloads disposable data and uploads only generated
  random bytes, up to about 120 MB in total. It does not send files,
  network names, BSSIDs, saved labels, notes or walkthroughs. Cloudflare sees
  the public IP address and ordinary request metadata needed to serve the test.

LAN scanning and the two identification actions ask for confirmation first,
saying what will be sent and where it may be logged. The speed-test disclosure
is shown beside its Start button.

These are direct diagnostics between this Mac and the devices, ranges, and
name services you select. Bonjour remains on the local link; a custom IPv4
range can be routed beyond it. None sends anything to the developer.

The hardware manufacturer database is embedded in the app and is never fetched
at runtime.

## Data the developer receives

None. The developer cannot see your networks, your saved data or your usage.

## Children

The app collects no data from anyone, including children.

## Changes

Any change to this policy will be published at this address with an updated
date.

## Contact

Questions about this policy can be submitted through the
[project support page](https://github.com/rblihovde/wifihigh5/issues).
