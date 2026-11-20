#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/../dist"
"${SCRIPT_DIR}/build_app.sh"

WORK_DIR="$(mktemp -d "${DIST_DIR}/.dmg-XXXXXXXX")"
MOUNT_POINT="${WORK_DIR}/mounted"
mounted=false
cleanup() {
    if [[ "${mounted}" == true ]]; then
        hdiutil detach -quiet "${MOUNT_POINT}" || return 1
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT
STAGE="${WORK_DIR}/volume"
mkdir "${STAGE}"
ditto "${DIST_DIR}/GmailPing.app" "${STAGE}/GmailPing.app"
ln -s /Applications "${STAGE}/Applications"
ICON_DIR="${STAGE}/GmailPing.app/Contents/Resources"
cp "${ICON_DIR}/AppIcon.icns" "${STAGE}/.VolumeIcon.icns"

# Ad-hoc signing seals the bundle for local installation. A publisher may supply a Developer ID identity.
SIGN_IDENTITY="${GMAILPING_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    SIGN_ARGS+=(--timestamp --options runtime)
    FRAMEWORK="${STAGE}/GmailPing.app/Contents/Frameworks/Sparkle.framework"
    for helper in "${FRAMEWORK}"/XPCServices/*.xpc "${FRAMEWORK}/Autoupdate" "${FRAMEWORK}/Updater.app"; do
        codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "${helper}"
    done
    codesign "${SIGN_ARGS[@]}" "${FRAMEWORK}"
fi
codesign "${SIGN_ARGS[@]}" "${STAGE}/GmailPing.app"
codesign --verify --deep --strict "${STAGE}/GmailPing.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${STAGE}/GmailPing.app/Contents/Info.plist")"
ARCHS="$(lipo -archs "${STAGE}/GmailPing.app/Contents/MacOS/GmailPingApp")"
for arch in arm64 x86_64; do
    [[ " ${ARCHS} " == *" ${arch} "* ]] || { echo "Missing ${arch} architecture" >&2; exit 1; }
done
NAME="GmailPing-${VERSION}-universal.dmg"
hdiutil create -quiet -srcfolder "${STAGE}" -volname GmailPing -fs HFS+ -format UDRW "${WORK_DIR}/writable.dmg"
mkdir "${MOUNT_POINT}"
hdiutil attach -quiet -nobrowse -mountpoint "${MOUNT_POINT}" "${WORK_DIR}/writable.dmg"
mounted=true
SetFile -a C "${MOUNT_POINT}"
hdiutil detach -quiet "${MOUNT_POINT}"
mounted=false
hdiutil convert -quiet "${WORK_DIR}/writable.dmg" -format UDZO -o "${WORK_DIR}/${NAME}"
hdiutil verify -quiet "${WORK_DIR}/${NAME}"
# Finder stores an unmounted file's custom icon in its resource fork.
# Keep that metadata in a ZIP for downloads as well as on the local DMG.
cat > "${WORK_DIR}/icon.r" <<'REZ'
read 'icns' (-16455) "AppIcon.icns";
REZ
Rez -i "${ICON_DIR}" "${WORK_DIR}/icon.r" -append -o "${WORK_DIR}/${NAME}"
SetFile -a C "${WORK_DIR}/${NAME}"
ditto -c -k --rsrc --sequesterRsrc "${WORK_DIR}/${NAME}" "${WORK_DIR}/${NAME}.zip"
# Generate a signed feed pointing at immutable assets in this version's release.
FEED_DIR="${WORK_DIR}/feed"
mkdir "${FEED_DIR}"
ln "${WORK_DIR}/${NAME}" "${FEED_DIR}/${NAME}"
SPARKLE_TOOLS="${SCRIPT_DIR}/../.build/artifacts/sparkle/Sparkle/bin"
"${SPARKLE_TOOLS}/generate_appcast" --account com.gmailping.app \
    --download-url-prefix "https://github.com/davidhoo/gmailping/releases/download/v${VERSION}/" "${FEED_DIR}"
"${SPARKLE_TOOLS}/sign_update" --verify --account com.gmailping.app "${FEED_DIR}/appcast.xml"
mv -f "${FEED_DIR}/appcast.xml" "${DIST_DIR}/appcast.xml"
mv -f "${WORK_DIR}/${NAME}" "${DIST_DIR}/${NAME}"
mv -f "${WORK_DIR}/${NAME}.zip" "${DIST_DIR}/${NAME}.zip"
echo "DMG: ${DIST_DIR}/${NAME}"
echo "ZIP: ${DIST_DIR}/${NAME}.zip"
