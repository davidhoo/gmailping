# GmailPing 开发者指南

[English](README.md) · **简体中文** · [日本語](README.ja.md) · [Español](README.es.md)

## 构建与测试

在运行 macOS 13 或更新版本的 Mac 上，使用带有 Swift 5.9 或更新版本的 Xcode。在仓库根目录运行以下命令。测试使用模拟的 Gmail 和 OAuth 客户端，无需 Google 账号。

```sh
swift build
swift test
```

[GmailPingApp](../../Sources/GmailPingApp) 包含 AppKit 菜单栏和 SwiftUI 偏好设置。[GmailPingCore](../../Sources/GmailPingCore) 负责 OAuth 授权、钥匙串存储、各账号的同步和通知。修改未读数、提醒或收件箱选择逻辑时，可先查看[验收测试](../../Tests/GmailPingTests)。

## 连接测试邮箱

1. 在 Google Cloud 项目中启用 [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com)，在 OAuth 同意屏幕声明 `openid` 和 `https://www.googleapis.com/auth/gmail.metadata`。如果外部应用处于测试阶段，将测试邮箱加入测试用户名单。
2. 创建[桌面应用 OAuth 客户端](https://console.cloud.google.com/auth/clients)，将 JSON 文件下载到仓库之外。把下方示例路径换成实际路径。复制命令会保留已有的本机配置。
3. 构建并打开应用，然后按[用户指南](../../README.zh-CN.md)连接邮箱。

```sh
mkdir -p ~/.gmailping
cp -n /absolute/path/to/desktop-client.json ~/.gmailping/config.json
./scripts/build_app.sh --development
open dist/GmailPing.app
```

运行时优先读取 `GMAILPING_CLIENT_ID` 和可选的 `GMAILPING_CLIENT_SECRET`，其次读取 `~/.gmailping/config.json`，最后读取随包配置。本机文件也支持旧版扁平 JSON 格式。测试双账号行为时，分别给两个邮箱发信，点击菜单栏图标和新邮件通知，核对打开的收件箱。把旧邮件标为未读，确认只有计数变化。

## 打包发布

各版本沿用同一个发布者 OAuth 客户端，以便已有账号继续刷新令牌。打包脚本使用 Python 3 校验桌面客户端 JSON，将其封装到应用，并在 `dist/` 生成通用版 DMG 和保留 Finder 图标的 `.dmg.zip`。

```sh
GMAILPING_OAUTH_CLIENT_FILE="/absolute/path/to/desktop-client.json" ./scripts/package_dmg.sh
```

脚本默认使用临时签名。使用 Developer ID 分发时，将 `GMAILPING_SIGN_IDENTITY` 设为 Developer ID Application 签名身份，并另行完成 Apple 公证。随应用分发的桌面客户端配置可以被读取。用户授权使用 PKCE 和本机回调，令牌保存在钥匙串中。公开分发时，须按 Gmail 元数据受限权限的要求完成相应 Google 验证。[桌面 OAuth](https://developers.google.com/identity/protocols/oauth2/native-app) · [Gmail 权限范围](https://developers.google.com/workspace/gmail/api/auth/scopes)

项目原始文档包括[产品需求](../产品需求.md)、[技术方案](../技术方案.md)、[开发与验收](../开发与验收.md)和 [OAuth 公开发布记录](../OAuth公开发布.md)。
