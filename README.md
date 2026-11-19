# GmailPing

GmailPing 是为 macOS 13 及更新版本设计的原生菜单栏工具。一个图标汇总多个 Gmail 收件箱的未读邮件数。点击图标打开默认邮箱，点击新邮件通知打开收到邮件的邮箱。

[项目首页](https://davidhoo.github.io/gmailping/) · [隐私政策](https://davidhoo.github.io/gmailping/privacy/) · [下载安装包](https://github.com/davidhoo/gmailping/releases)

## 首次添加 Gmail 账号

打开 GmailPing 的 DMG，将 GmailPing 拖入「Applications（应用程序）」，然后从「应用程序」启动。打开 **偏好设置 → 账号 → 添加 Google 账号…**，在浏览器选择邮箱并授权。添加其他邮箱时重复此操作。每个邮箱的令牌独立保存在这台 Mac 的钥匙串中。

## 维护者配置与打包

1. 维护者为 GmailPing 选择一个 Google Cloud 项目，启用 [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com)。
2. 配置同意屏幕与 External 受众，声明 `openid` 和 `https://www.googleapis.com/auth/gmail.metadata`。测试阶段将试用者加入测试用户。公开分发时按受限权限要求完成适用审核。[受众设置](https://console.cloud.google.com/auth/audience) · [Gmail 权限说明](https://developers.google.com/workspace/gmail/api/auth/scopes)
3. 创建 **Desktop app（桌面应用）** OAuth 客户端，将下载的客户端 JSON 保存在源码目录之外。每次发行使用同一客户端，以便已有用户继续刷新令牌。[Google Cloud 客户端](https://console.cloud.google.com/auth/clients)
4. 在项目根目录执行以下命令。脚本校验桌面客户端格式，把客户端配置封装到应用，生成 `dist/GmailPing-<版本号>-universal.dmg`。默认采用本机临时签名。公开分发时通过 `GMAILPING_SIGN_IDENTITY` 指定 Developer ID Application 身份，并在打包后完成 Apple 公证。

```sh
GMAILPING_OAUTH_CLIENT_FILE="/absolute/path/to/desktop-client.json" ./scripts/package_dmg.sh
```

桌面客户端属于公开客户端，随包字段可以被读取。每位用户仍需通过 Google 同意页和 PKCE 流程取得自己的令牌。[Google 桌面 OAuth 说明](https://developers.google.com/identity/protocols/oauth2/native-app)

本地开发可运行 `./scripts/build_app.sh --development`，通过 `GMAILPING_CLIENT_ID` 和可选的 `GMAILPING_CLIENT_SECRET` 提供配置。已有的 `~/.gmailping/config.json` 继续可用。运行时按环境变量、本机已有配置、随包配置的顺序读取，以保留既有账号的客户端绑定。

## V1 设计文档

| 文档 | 阅读目的 |
| --- | --- |
| [产品需求](docs/产品需求.md) | 确认图标、多账号、通知和偏好设置的用户体验 |
| [技术方案](docs/技术方案.md) | 确认授权、账号隔离、状态持久化与增量同步的实现 |
| [开发与验收](docs/开发与验收.md) | 按阶段实施，用两个测试邮箱验证关键场景 |
