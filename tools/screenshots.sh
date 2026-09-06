#!/bin/bash
# Builds a screenshot-only copy of the app that shows invented network
# identifiers, so store screenshots never disclose the network they were taken
# on. The DEMO_SCREENSHOTS flag is defined here and nowhere else; build.sh and
# build-appstore.sh never set it, so shipping builds cannot contain this path.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WifiHigh5 (Screenshots)"
BINARY="WifiHigh5"
OUT="build/screenshots"
BUNDLE="${OUT}/${APP_NAME}.app"

echo "==> Building screenshot copy"
rm -rf "${OUT}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

SOURCE_FILES=()
while IFS= read -r file; do SOURCE_FILES+=("${file}"); done < <(find Sources -name '*.swift' -print)

swiftc \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -O \
    -D DEMO_SCREENSHOTS \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework SystemConfiguration \
    -o "${BUNDLE}/Contents/MacOS/${BINARY}" \
    "${SOURCE_FILES[@]}"

# A separate bundle identifier so this never disturbs the real app's
# preferences, its saved data or its Location Services grant.
sed -e 's/com\.rblihovde\.wifihigh5/com.rblihovde.wifihigh5.screenshots/' \
    -e 's/<string>WifiHigh5<\/string>/<string>WifiHigh5 (Screenshots)<\/string>/g' \
    Resources/Info.plist > "${BUNDLE}/Contents/Info.plist"
# CFBundleExecutable must keep matching the binary on disk.
plutil -replace CFBundleExecutable -string "${BINARY}" "${BUNDLE}/Contents/Info.plist"
plutil -lint "${BUNDLE}/Contents/Info.plist" >/dev/null

[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/"
[ -f Resources/OUI.txt ] && cp Resources/OUI.txt "${BUNDLE}/Contents/Resources/"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

codesign --force --sign - "${BUNDLE}" >/dev/null 2>&1

echo "==> Built ${BUNDLE}"
echo "    Open it, arrange the panes you want, and capture."
echo "    It shows invented identifiers, so the captures are safe to publish."
