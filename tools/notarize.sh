#!/bin/bash
# Notarises the built app with Apple and staples the ticket to it.
#
# One-time setup, using an app-specific password from appleid.apple.com:
#
#   xcrun notarytool store-credentials "WiFiSignalTester" \
#       --apple-id "you@example.com" \
#       --team-id "A826N9S2WM" \
#       --password "abcd-efgh-ijkl-mnop"
#
# Then just run this script. Requires a build signed with a Developer ID and
# the hardened runtime, which build.sh already produces.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WiFi Signal Tester"
APP="build/${APP_NAME}.app"
ARCHIVE="build/${APP_NAME// /}-notarize.zip"
PROFILE="${NOTARY_PROFILE:-WiFiSignalTester}"

if [ ! -d "${APP}" ]; then
    echo "!! ${APP} not found. Run ./build.sh first." >&2
    exit 1
fi

# Ad-hoc signatures cannot be notarised, so fail early rather than after upload.
if ! codesign -dvv "${APP}" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "!! ${APP} is not signed with a Developer ID certificate." >&2
    echo "   Rebuild with: CODESIGN_IDENTITY='Developer ID Application: ...' ./build.sh" >&2
    exit 1
fi

if ! codesign -dvv "${APP}" 2>&1 | grep -q "Timestamp="; then
    echo "!! ${APP} has no secure timestamp; Apple will reject it." >&2
    exit 1
fi

echo "==> Packaging for submission"
# notarytool takes a .zip, .pkg or .dmg — never a bare .app bundle. ditto is
# used rather than zip because it preserves the bundle's symlinks and metadata.
rm -f "${ARCHIVE}"
ditto -c -k --keepParent "${APP}" "${ARCHIVE}"

echo "==> Submitting to Apple (this usually takes a few minutes)"
if ! xcrun notarytool submit "${ARCHIVE}" --keychain-profile "${PROFILE}" --wait; then
    echo >&2
    echo "!! Submission failed. If the profile is missing, create it with:" >&2
    echo "   xcrun notarytool store-credentials \"${PROFILE}\" --apple-id <id> --team-id A826N9S2WM --password <app-specific-password>" >&2
    echo "   For rejection details: xcrun notarytool log <submission-id> --keychain-profile \"${PROFILE}\"" >&2
    exit 1
fi

echo "==> Stapling the ticket"
xcrun stapler staple "${APP}"

echo "==> Verifying"
xcrun stapler validate "${APP}"
spctl -a -vvv -t exec "${APP}" 2>&1 | sed 's/^/    /'

# Re-package after stapling so the archive carries the ticket too.
rm -f "${ARCHIVE}"
ditto -c -k --keepParent "${APP}" "${ARCHIVE}"

echo "==> Notarised. Distributable copy: ${ARCHIVE}"
echo "    Reinstall the stapled build with: ./build.sh"
