#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/../dist"
"${SCRIPT_DIR}/build_app.sh"

WORK_DIR="$(mktemp -d "${DIST_DIR}/.dmg-XXXXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
STAGE="${WORK_DIR}/volume"
mkdir "${STAGE}"
ditto "${DIST_DIR}/GmailPing.app" "${STAGE}/GmailPing.app"
ln -s /Applications "${STAGE}/Applications"

# Ad-hoc signing seals the bundle for local installation. A publisher may supply a Developer ID identity.
SIGN_IDENTITY="${GMAILPING_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --options runtime --sign "${SIGN_IDENTITY}")
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "${STAGE}/GmailPing.app"
codesign --verify --deep --strict "${STAGE}/GmailPing.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${STAGE}/GmailPing.app/Contents/Info.plist")"
ARCHS="$(lipo -archs "${STAGE}/GmailPing.app/Contents/MacOS/GmailPingApp")"
for arch in arm64 x86_64; do
    [[ " ${ARCHS} " == *" ${arch} "* ]] || { echo "Missing ${arch} architecture" >&2; exit 1; }
done
NAME="GmailPing-${VERSION}-universal.dmg"
hdiutil create -quiet -srcfolder "${STAGE}" -volname GmailPing -fs HFS+ -format UDZO "${WORK_DIR}/${NAME}"
hdiutil verify -quiet "${WORK_DIR}/${NAME}"
mv -f "${WORK_DIR}/${NAME}" "${DIST_DIR}/${NAME}"
echo "DMG: ${DIST_DIR}/${NAME}"
