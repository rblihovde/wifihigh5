# WifiHigh5 Privacy Policy

**Last updated: 5 September 2026**

WifiHigh5 does not collect, transmit or share any data. There are no
accounts, no analytics, no crash reporting and no advertising.

## What the app reads

Everything the app shows is read from the Mac it is running on:

- The state of the current Wi-Fi link, including signal strength, noise, channel,
  band, transmit rate, network name and access point identifier.
- The assigned IP address, subnet, router, DNS servers and DHCP lease.
- The kernel's existing ARP cache, which lists hosts this Mac has already
  exchanged traffic with in the normal course of being connected. Nothing is
  scanned or probed to produce it.

## What the app stores

Two things, both on your Mac only, inside the app's sandbox container:

- **Access point names.** Any nickname, site label, note or colour you choose.
- **Saved walkthroughs.** Recordings you explicitly start, including the
  readings taken and the places you marked.

You can delete either at any time from within the app. Neither is uploaded
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

The app makes no network connections on its own. Two features communicate, both
switched off until you enable them and both labelled in the interface:

- **Scanning for nearby access points** sends probe requests, the same frames
  any device sends when joining a network.
- **The gateway check** sends ICMP echo requests to your own default router and
  to no other address.

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
