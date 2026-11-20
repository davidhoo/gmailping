# GmailPing 開発者ガイド

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語** · [Español](README.es.md)

## ビルドとテスト

macOS 13 以降の Mac で、Swift 5.9 以降を含む Xcode を使用します。リポジトリのルートで以下のコマンドを実行してください。テストでは Gmail と OAuth のモックを使用するため、Google アカウントは不要です。

```sh
swift build
swift test
```

[GmailPingApp](../../Sources/GmailPingApp) には AppKit のメニューバーと SwiftUI の設定画面があります。[GmailPingCore](../../Sources/GmailPingCore) は OAuth、キーチェーンへの保存、アカウントごとの同期と通知を担当します。未読数、通知、受信トレイの選択動作を変更する際は、[受け入れテスト](../../Tests/GmailPingTests)で期待される動作を確認できます。

## テスト用の受信トレイに接続する

1. Google Cloud プロジェクトで [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com) を有効にし、OAuth 同意画面で `openid` と `https://www.googleapis.com/auth/gmail.metadata` を設定します。外部向けアプリがテスト段階の場合は、使用するメールアドレスをテストユーザーに追加します。
2. [デスクトップアプリ用 OAuth クライアント](https://console.cloud.google.com/auth/clients)を作成し、JSON ファイルをリポジトリの外に保存します。以下のパスを実際の保存先に置き換えてください。コピー時に既存のローカル設定は保持されます。
3. アプリをビルドして起動し、[ユーザーガイド](../../README.ja.md)に従ってアカウントを追加します。

```sh
mkdir -p ~/.gmailping
cp -n /absolute/path/to/desktop-client.json ~/.gmailping/config.json
./scripts/build_app.sh --development
open dist/GmailPing.app
```

実行時には `GMAILPING_CLIENT_ID` と任意の `GMAILPING_CLIENT_SECRET`、次に `~/.gmailping/config.json`、最後にアプリ同梱の設定が参照されます。ローカルファイルは旧形式のフラットな JSON にも対応します。2 つのテストアカウントにメールを送り、メニューバーのアイコンと新着通知からそれぞれ意図した受信トレイが開くことを確認します。以前のメールを未読に戻した際は、件数だけが変わることを確認してください。

## リリース用のパッケージを作る

既存アカウントのトークンを更新できるよう、各リリースで同じ配布元の OAuth クライアントを使用します。スクリプトは Python 3 でデスクトップクライアントの JSON を検証してアプリに組み込み、ユニバーサル版の DMG と Finder アイコンを保持した `.dmg.zip` を `dist/` に出力します。

```sh
GMAILPING_OAUTH_CLIENT_FILE="/absolute/path/to/desktop-client.json" ./scripts/package_dmg.sh
```

公開用 Mac のログインキーチェーンにある `com.gmailping.app` の Sparkle Ed25519 鍵でフィードと DMG に署名します。更新ごとに `CFBundleVersion` を増やし、`dist/appcast.xml`、DMG、ZIP を対応する GitHub Release にアップロードして Latest に設定します。

既定ではアドホック署名を使用します。Developer ID で配布する場合は、`GMAILPING_SIGN_IDENTITY` に Developer ID Application の署名 ID を設定し、Apple の公証を別途行います。同梱したクライアント設定は読み取り可能です。ユーザー認証には PKCE とループバックコールバックを使用し、トークンはキーチェーンに保存します。制限付きの Gmail メタデータスコープを使って一般公開する際は、該当する Google の審査を受けてください。[デスクトップ OAuth](https://developers.google.com/identity/protocols/oauth2/native-app) · [Gmail のスコープ](https://developers.google.com/workspace/gmail/api/auth/scopes)

原資料（簡体字中国語）には[製品要件](../产品需求.md)、[技術設計](../技术方案.md)、[受け入れシナリオ](../开发与验收.md)、[OAuth 公開審査の記録](../OAuth公开发布.md)があります。
