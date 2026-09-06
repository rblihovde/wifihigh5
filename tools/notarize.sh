#!/bin/bash
# Notarises the built app with Apple and staples the ticket to it.
#
# One-time setup, using an app-specific password from appleid.apple.com:
#
#   xcrun notarytool store-credentials "WifiHigh5" \
#       --apple-id "you@example.com" \
#       --team-id "A826N9S2WM" \
#       --password "abcd-efgh-ijkl-mnop"
#
# Then just run this script. Requires a build signed with a Developer ID and
# the hardened runtime, which build.sh already produces.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WifiHigh5"
APP="build/${APP_NAME}.app"
ARCHIVE="build/${APP_NAME// /}-notarize.zip"
PROFILE="${NOTARY_PROFILE:-WifiHigh5}"

# The keychain profile is named independently of the app, and one may already
# exist under the name this project used previously. Fall back to it rather
# than making the operator store the same credential twice.
LEGACY_PROFILE="WiFiSignalTester"
if ! xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
    if xcrun notarytool history --keychain-profile "${LEGACY_PROFILE}" >/dev/null 2>&1; then
        echo "==> Using existing keychain profile '${LEGACY_PROFILE}'"
        PROFILE="${LEGACY_PROFILE}"
    fi
fi

if [ ! -d "${APP}" ]; then
    echo "!! ${APP} not found. Run ./build.sh first." >&2
    exit 1
fi

# The signature is captured before being searched rather than piped into a
# grep. Under `set -o pipefail` a `grep -q` closes the pipe as soon as it
# matches, codesign dies of SIGPIPE, and the pipeline reports failure on
# success — which inverted both of these checks.
SIGNATURE=$(codesign -dvv "${APP}" 2>&1 || true)

# Ad-hoc signatures cannot be notarised, so fail early rather than after upload.
if ! grep -q "Authority=Developer ID Application" <<<"${SIGNATURE}"; then
    echo "!! ${APP} is not signed with a Developer ID certificate." >&2
    echo "   Rebuild with: CODESIGN_IDENTITY='Developer ID Application: ...' ./build.sh" >&2
    exit 1
fi

if ! grep -q "Timestamp=" <<<"${SIGNATURE}"; then
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

# Installing the stapled bundle directly matters: rebuilding would recompile
# and re-sign, producing a different binary that this ticket does not cover.
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
    INSTALLED="/Applications/${APP_NAME}.app"
    echo "==> Installing the stapled build to ${INSTALLED}"
    rm -rf "${INSTALLED}"
    cp -R "${APP}" "/Applications/"
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "${LSREGISTER}" -f "${INSTALLED}"
    xcrun stapler validate "${INSTALLED}" 2>&1 | sed 's/^/    /'
    spctl -a -vvv -t exec "${INSTALLED}" 2>&1 | sed 's/^/    /'
fi

echo "==> Notarised. Distributable copy: ${ARCHIVE}"
echo "    Note: any later ./build.sh re-signs the app and drops the ticket."
echo "    Run this script again after rebuilding."
