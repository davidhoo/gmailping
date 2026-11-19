#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${ROOT_DIR}"

echo "==> Building GmailPing with SwiftPM (release)..."
swift build -c release --product GmailPingApp

APP_BUNDLE="${ROOT_DIR}/dist/GmailPing.app"
BIN_SOURCE="${ROOT_DIR}/.build/release/GmailPingApp"
if [ ! -f "${BIN_SOURCE}" ]; then
    # Try out directory if SPM used out
    BIN_SOURCE="$(find .build -name "GmailPingApp" -type f -perm +111 | head -n 1)"
fi

echo "==> Packaging into ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_SOURCE}" "${APP_BUNDLE}/Contents/MacOS/GmailPingApp"
chmod +x "${APP_BUNDLE}/Contents/MacOS/GmailPingApp"

cat << 'EOF' > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GmailPingApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.gmailping.app</string>
    <key>CFBundleName</key>
    <string>GmailPing</string>
    <key>CFBundleDisplayName</key>
    <string>GmailPing</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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

echo "==> App bundle built successfully at: ${APP_BUNDLE}"
