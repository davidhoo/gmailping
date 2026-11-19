#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Prepare the publisher's desktop client before touching the existing app bundle.
# Resolve a relative input path from the caller's directory.
OAUTH_RESOURCE=""
if [[ ${1:-} == "--development" && $# == 1 ]]; then
    echo "Building a development app using local OAuth configuration."
elif [[ $# != 0 || -z ${GMAILPING_OAUTH_CLIENT_FILE:-} ]]; then
    echo "Set GMAILPING_OAUTH_CLIENT_FILE to the publisher's Desktop app JSON, or use --development for a local build." >&2
    exit 2
else
    OAUTH_RESOURCE="$(mktemp)"
    trap 'rm -f "${OAUTH_RESOURCE}"' EXIT
    python3 - "${GMAILPING_OAUTH_CLIENT_FILE}" "${OAUTH_RESOURCE}" <<'PYCLIENT'
import json
import re
import sys

try:
    with open(sys.argv[1]) as source:
        fields = json.load(source)["installed"]
    client_id = fields["client_id"].strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id):
        raise ValueError()
    client = {"client_id": client_id}
    if "client_secret" in fields:
        if not isinstance(fields["client_secret"], str) or not fields["client_secret"]:
            raise ValueError()
        client["client_secret"] = fields["client_secret"]
except (OSError, KeyError, ValueError, TypeError, AttributeError):
    sys.exit("Expected a readable Google Desktop app OAuth client export with an installed.client_id.")
with open(sys.argv[2], "w") as resource:
    json.dump({"installed": client}, resource)
PYCLIENT
fi

cd "${ROOT_DIR}"

echo "==> Building GmailPing Universal Binary (arm64 + x86_64) in Release mode..."
swift build -c release --arch arm64 --arch x86_64 --product GmailPingApp

APP_BUNDLE="${ROOT_DIR}/dist/GmailPing.app"
BIN_SOURCE="${ROOT_DIR}/.build/out/Products/Release/GmailPingApp"

if [ ! -f "${BIN_SOURCE}" ]; then
    # Fallback search if path differs
    BIN_SOURCE="$(find .build -name "GmailPingApp" -type f -perm +111 | grep -E "Release.*GmailPingApp" | head -n 1)"
fi

echo "==> Packaging into ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

install -m 644 "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

if [[ -n "${OAUTH_RESOURCE}" ]]; then
    install -m 644 "${OAUTH_RESOURCE}" "${APP_BUNDLE}/Contents/Resources/GoogleDesktopClient.json"
fi

cp "${BIN_SOURCE}" "${APP_BUNDLE}/Contents/MacOS/GmailPingApp"
chmod +x "${APP_BUNDLE}/Contents/MacOS/GmailPingApp"

cat << 'EOF' > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GmailPingApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.gmailping.app</string>
    <key>CFBundleName</key>
    <string>GmailPing</string>
    <key>CFBundleDisplayName</key>
    <string>GmailPing</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.2</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Verifying binary architectures with lipo..."
lipo -info "${APP_BUNDLE}/Contents/MacOS/GmailPingApp"

echo "==> App bundle built successfully at: ${APP_BUNDLE}"
