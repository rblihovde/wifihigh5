#!/bin/bash
# Refreshes the hardware-vendor database from the IEEE registry.
#
# Run this on a machine with network access, then commit the generated file.
# The app itself never downloads anything: the database ships inside the bundle
# so that nothing reaches the network while the tool is on a client site.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading IEEE registries"
curl -fsSL --max-time 180 -o "$WORK/oui.csv"   "https://standards-oui.ieee.org/oui/oui.csv"
curl -fsSL --max-time 180 -o "$WORK/mam.csv"   "https://standards-oui.ieee.org/oui28/mam.csv"
curl -fsSL --max-time 180 -o "$WORK/oui36.csv" "https://standards-oui.ieee.org/oui36/oui36.csv"

for f in oui.csv mam.csv oui36.csv; do
    lines=$(wc -l < "$WORK/$f")
    if [ "$lines" -lt 1000 ]; then
        echo "!! $f looks truncated ($lines lines); aborting rather than shipping bad data" >&2
        exit 1
    fi
done

echo "==> Building Resources/OUI.txt"
python3 tools/build-oui.py "$WORK/oui.csv" "$WORK/mam.csv" "$WORK/oui36.csv" Resources/OUI.txt
echo "==> Done. Rebuild the app to embed the new database."
