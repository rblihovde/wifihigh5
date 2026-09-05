#!/bin/bash
# Builds, bundles and signs WiFi Signal Tester.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="WiFi Signal Tester"
BINARY="WiFiSignalTester"
BUILD_DIR="build"
BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
STAGING_ROOT="${BUILD_DIR}/.staging-$$"
STAGING_BUNDLE="${STAGING_ROOT}/${APP_NAME}.app"
CACHE_ROOT="${BUILD_DIR}/.module-cache"
DEFAULT_IDENTITY="Developer ID Application: Ryan Blihovde (A826N9S2WM)"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="${CODESIGN_IDENTITY}"
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq "${DEFAULT_IDENTITY}"; then
    IDENTITY="${DEFAULT_IDENTITY}"
else
    IDENTITY="-"
    echo "==> Developer ID not available; using an ad-hoc signature for this local build"
fi

cleanup() { rm -rf "${STAGING_ROOT}"; }
trap cleanup EXIT

echo "==> Preparing"
mkdir -p "${STAGING_BUNDLE}/Contents/MacOS" "${STAGING_BUNDLE}/Contents/Resources"
mkdir -p "${CACHE_ROOT}/clang" "${CACHE_ROOT}/swift"
plutil -lint Resources/Info.plist >/dev/null

SOURCE_FILES=()
while IFS= read -r file; do SOURCE_FILES+=("${file}"); done < <(find Sources -name '*.swift' -print)

echo "==> Compiling"
CLANG_MODULE_CACHE_PATH="${CACHE_ROOT}/clang" \
SWIFT_MODULECACHE_PATH="${CACHE_ROOT}/swift" \
swiftc \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -O \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework SystemConfiguration \
    -o "${STAGING_BUNDLE}/Contents/MacOS/${BINARY}" \
    "${SOURCE_FILES[@]}"

echo "==> Bundling"
cp Resources/Info.plist "${STAGING_BUNDLE}/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "${STAGING_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [ -f Resources/OUI.txt ]; then
    cp Resources/OUI.txt "${STAGING_BUNDLE}/Contents/Resources/OUI.txt"
else
    echo "    note: Resources/OUI.txt missing — run tools/update-oui.sh for vendor names"
fi
printf 'APPL????' > "${STAGING_BUNDLE}/Contents/PkgInfo"

echo "==> Signing as: ${IDENTITY}"
SIGN_ARGS=(--force --sign "${IDENTITY}" --options runtime
           --entitlements Resources/WiFiSignalTester.entitlements)
if [ "${IDENTITY}" != "-" ]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "${STAGING_BUNDLE}"

codesign --verify --strict --verbose=2 "${STAGING_BUNDLE}" 2>&1 | sed 's/^/    /'

echo "==> Installing verified build"
rm -rf "${BUNDLE}"
mv "${STAGING_BUNDLE}" "${BUNDLE}"

# The Location Services grant is bound to the installed bundle's path, so the
# app is installed to a stable location rather than run out of ./build. Set
# SKIP_INSTALL=1 to build only.
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
    INSTALLED="/Applications/${APP_NAME}.app"
    echo "==> Installing to ${INSTALLED}"
    rm -rf "${INSTALLED}"
    cp -R "${BUNDLE}" "/Applications/"
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "${LSREGISTER}" -f "${INSTALLED}"
    echo "    registered with LaunchServices"
fi

echo "==> Built ${BUNDLE}"
