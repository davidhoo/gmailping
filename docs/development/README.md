# GmailPing developer guide

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [Español](README.es.md)

## Build and test

On a Mac running macOS 13 or later, use Xcode with Swift 5.9 or later. Run these commands from the repository root. The tests use mock Gmail and OAuth clients and can run without a Google account.

```sh
swift build
swift test
```

[GmailPingApp](../../Sources/GmailPingApp) contains the AppKit menu bar and SwiftUI preferences. [GmailPingCore](../../Sources/GmailPingCore) handles OAuth, Keychain storage, per-account sync and notifications. Start with the [acceptance tests](../../Tests/GmailPingTests) when changing how unread counts, alerts or inbox selection work.

## Connect a test mailbox

1. Enable the [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com) in your Google Cloud project. Configure the OAuth consent screen with `openid` and `https://www.googleapis.com/auth/gmail.metadata`. For an external app in testing, add your test mailbox to the audience.
2. Create a [Desktop app OAuth client](https://console.cloud.google.com/auth/clients). Download its JSON file outside the repository. Substitute its actual path below. The copy command preserves any existing local configuration.
3. Build and open the app bundle, then connect a mailbox using the [user guide](../../README.md).

```sh
mkdir -p ~/.gmailping
cp -n /absolute/path/to/desktop-client.json ~/.gmailping/config.json
./scripts/build_app.sh --development
open dist/GmailPing.app
```

At runtime, `GMAILPING_CLIENT_ID` and the optional `GMAILPING_CLIENT_SECRET` take precedence over `~/.gmailping/config.json`, followed by the bundled client. The local file also accepts the legacy flat JSON format. To test inbox routing with two accounts, send mail to each, click the menu bar icon and then a notification. Mark an older message unread and confirm that only the count changes.

## Package a release

Use the same publisher OAuth client across releases so existing accounts can refresh their tokens. The script uses Python 3 to validate the desktop client export, bundles it in the app, and produces a universal DMG and a `.dmg.zip` in `dist/`. The ZIP preserves the Finder icon.

```sh
GMAILPING_OAUTH_CLIENT_FILE="/absolute/path/to/desktop-client.json" ./scripts/package_dmg.sh
```

The script uses ad-hoc signing by default. For Developer ID distribution, set `GMAILPING_SIGN_IDENTITY` to a Developer ID Application identity and complete Apple notarization separately. The bundled desktop client is readable. User grants use PKCE and a loopback callback, and user tokens live in Keychain. Public distribution using the restricted Gmail metadata scope requires Google’s applicable verification. [Desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app) · [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)

Original project notes (Simplified Chinese) cover the [product requirements](../产品需求.md), [technical design](../技术方案.md), [acceptance scenarios](../开发与验收.md) and [OAuth release review](../OAuth公开发布.md).
