# GmailPing

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [Español](README.es.md)

See how many unread messages are in your Gmail inboxes from the macOS menu bar. When new mail arrives, click the notification to open the inbox that received it in your default browser.

## Install and connect Gmail

1. On the [releases page](https://github.com/davidhoo/gmailping/releases), download the universal `.dmg` for Apple silicon or Intel Macs running macOS 13 or later. If you choose the `.dmg.zip`, unzip it first. Version 1.0.2 is an ad-hoc signed preview without Apple notarization.
2. Open the disk image, drag **GmailPing** into **Applications**, and launch it from there. Look for the envelope in the menu bar.
3. Click the envelope to open preferences. The app’s controls are in Simplified Chinese. Select **账号** (Accounts), then **添加 Google 账号...** (Add Google account). Choose your Gmail account in the browser and approve access. Repeat for each inbox you want to follow.
4. To receive alerts, allow notifications when macOS asks. You can change the sound and check interval later in **偏好设置** (Preferences).

## Open the right inbox

Click the envelope. If one account has unread mail, GmailPing opens it directly. If several do, choose from a list showing each address and its unread count. If none has a known unread message, the default inbox opens. Right-click the envelope to see when each account was last checked, check for mail now, or change the default account.

GmailPing groups messages that arrive in the same inbox during one check into a single notification. Marking an old message as unread updates the count without triggering a new-mail alert.

## Privacy and support

Your Mac connects directly to Google to check counts, message IDs and labels. Messages and attachments stay in Gmail. Each account’s tokens are stored in the macOS Keychain. To disconnect an account, remove it under **账号**. You can also revoke its access in your Google account. [Privacy policy (Chinese)](https://davidhoo.github.io/gmailping/privacy/) · [Google account connections](https://myaccount.google.com/connections)

For help, include your macOS and GmailPing versions in your [support email](mailto:coolbor@gmail.com).

[Developer guide](docs/development/README.md) · [MIT License](LICENSE)
