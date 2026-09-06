#!/bin/bash
# Compiles the model and export layers together with the test harness and runs it.
set -euo pipefail
cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$OUT/module-cache/clang" "$OUT/module-cache/swift"

CLANG_MODULE_CACHE_PATH="$OUT/module-cache/clang" \
SWIFT_MODULECACHE_PATH="$OUT/module-cache/swift" \
swiftc \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -framework SwiftUI \
    Sources/Model/Model.swift \
    Sources/Model/Survey.swift \
    Sources/Model/APRegistry.swift \
    Sources/Model/Topology.swift \
    Sources/Model/DeviceRegistry.swift \
    Sources/Model/DeviceRole.swift \
    Sources/Model/ObservedDevice.swift \
    Sources/Service/DevicePresence.swift \
    Sources/Service/ARPTable.swift \
    Sources/Service/ReportBuilder.swift \
    Sources/Service/VendorDatabase.swift \
    Sources/View/HoverHelp.swift \
    Sources/View/HelpView.swift \
    Sources/View/HelpContent.swift \
    Sources/View/Components.swift \
    Tests/TopologyTestSupport.swift \
    Tests/ModelTests.swift \
    -o "$OUT/tests"

# The vendor table is passed in so the checks run without an app bundle.
"$OUT/tests" Resources/OUI.txt
