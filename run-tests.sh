#!/bin/bash
# Compiles the model and export layers together with the test harness and runs it.
set -euo pipefail
cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    Sources/Model/Model.swift \
    Sources/Model/Survey.swift \
    Sources/Model/APRegistry.swift \
    Sources/Service/ReportBuilder.swift \
    Sources/Service/VendorDatabase.swift \
    Tests/ModelTests.swift \
    -o "$OUT/tests"

# The vendor table is passed in so the checks run without an app bundle.
"$OUT/tests" Resources/OUI.txt
