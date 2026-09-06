#!/bin/bash
# Builds a sandboxed, Apple-Distribution-signed package for the Mac App Store.
#
# This is a separate target from build.sh on purpose. build.sh produces the
# Developer ID build you run at client sites; it is not sandboxed and is
# notarised rather than reviewed. The App Store build is sandboxed, signed with
# a different certificate, and wrapped in a signed installer package.
#
# Run with --check to see what is still missing without building.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WifiHigh5"
BINARY="WifiHigh5"
TEAM_ID="A826N9S2WM"
OUT_DIR="build/appstore"
BUNDLE="${OUT_DIR}/${APP_NAME}.app"
PKG="${OUT_DIR}/${BINARY}.pkg"
PROFILE="${PROVISION_PROFILE:-Resources/WifiHigh5.provisionprofile}"

APP_CERT="${APPSTORE_APP_IDENTITY:-Apple Distribution: Ryan Blihovde (${TEAM_ID})}"
PKG_CERT="${APPSTORE_PKG_IDENTITY:-3rd Party Mac Developer Installer: Ryan Blihovde (${TEAM_ID})}"

missing=0
note() { echo "    $1"; }

echo "==> Checking prerequisites"

CODESIGN_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if grep -Fq "${APP_CERT}" <<<"${CODESIGN_IDENTITIES}"; then
    note "app signing certificate: found"
else
    note "MISSING app signing certificate: ${APP_CERT}"
    note "  Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Apple Distribution"
    missing=1
fi

ALL_IDENTITIES=$(security find-identity -v 2>/dev/null || true)
if grep -Fq "${PKG_CERT}" <<<"${ALL_IDENTITIES}"; then
    note "installer certificate: found"
else
    note "MISSING installer certificate: ${PKG_CERT}"
    note "  developer.apple.com ▸ Certificates ▸ + ▸ Mac Installer Distribution"
    missing=1
fi

if [ -f "${PROFILE}" ]; then
    note "provisioning profile: ${PROFILE}"
else
    note "MISSING provisioning profile at ${PROFILE}"
    note "  developer.apple.com ▸ Profiles ▸ + ▸ Mac App Store Connect"
    note "  Register bundle ID com.rblihovde.wifihigh5 first, then download"
    note "  the profile and save it to that path."
    missing=1
fi

if [ "${1:-}" = "--check" ]; then
    [ "$missing" -eq 0 ] && echo "==> Ready to build." || echo "==> Not ready yet; see above."
    exit 0
fi

if [ "$missing" -ne 0 ]; then
    echo "!! Cannot build for the App Store until the items above exist." >&2
    exit 1
fi

echo "==> Compiling"
rm -rf "${OUT_DIR}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
plutil -lint Resources/Info.plist >/dev/null

SOURCE_FILES=()
while IFS= read -r file; do SOURCE_FILES+=("${file}"); done < <(find Sources -name '*.swift' -print)

swiftc \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -O \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework SystemConfiguration \
    -o "${BUNDLE}/Contents/MacOS/${BINARY}" \
    "${SOURCE_FILES[@]}"

echo "==> Bundling"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/"
[ -f Resources/OUI.txt ] && cp Resources/OUI.txt "${BUNDLE}/Contents/Resources/"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"
cp "${PROFILE}" "${BUNDLE}/Contents/embedded.provisionprofile"

echo "==> Signing (sandboxed, Apple Distribution)"
codesign --force \
    --sign "${APP_CERT}" \
    --entitlements Resources/WifiHigh5-AppStore.entitlements \
    --options runtime \
    --timestamp \
    "${BUNDLE}"

codesign --verify --strict --verbose=2 "${BUNDLE}" 2>&1 | sed 's/^/    /'

# The sandbox entitlement must actually be present, or the upload is rejected
# after the fact rather than here.
BUNDLE_ENTITLEMENTS=$(codesign -d --entitlements - "${BUNDLE}" 2>/dev/null || true)
if ! grep -q "app-sandbox" <<<"${BUNDLE_ENTITLEMENTS}"; then
    echo "!! The signed bundle has no app-sandbox entitlement; App Store will reject it." >&2
    exit 1
fi

# The application identifier must be signed into the bundle, not merely present
# in the profile, or the upload is accepted but the build cannot go to
# TestFlight (warning 90886).
PROFILE_APP_ID=$(security cms -D -i "${PROFILE}" 2>/dev/null \
    | plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - - 2>/dev/null || true)
if [ -n "${PROFILE_APP_ID}" ] && ! grep -Fq "${PROFILE_APP_ID}" <<<"${BUNDLE_ENTITLEMENTS}"; then
    echo "!! The signed bundle is missing com.apple.application-identifier" >&2
    echo "   (${PROFILE_APP_ID}); it would be ineligible for TestFlight." >&2
    exit 1
fi

echo "==> Building installer package"
productbuild --component "${BUNDLE}" /Applications \
    --sign "${PKG_CERT}" \
    "${PKG}"

echo
echo "==> Built ${PKG}"
echo
echo "    Validate:  xcrun altool --validate-app -f \"${PKG}\" -t macos \\"
echo "                   -u <your-apple-id> -p @keychain:AC_PASSWORD"
echo "    Upload:    xcrun altool --upload-app  -f \"${PKG}\" -t macos \\"
echo "                   -u <your-apple-id> -p @keychain:AC_PASSWORD"
echo
echo "    Or drag the .pkg into Transporter.app from the Mac App Store."
