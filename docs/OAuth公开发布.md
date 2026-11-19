# Google OAuth 公开发布材料

## 当前发布状态

截至 2026-11-19 17:50（北京时间），公开仓库、GitHub Pages 首页和隐私政策均已上线。Google Cloud 项目 `gmailping` 的 Gmail API 已启用，受众为 External，发布状态为「正式版」。同意页配置的品牌名为 GmailPing，授权网域为 `davidhoo.github.io`，数据范围为 `openid` 和 `gmail.metadata`。

Search Console 已分别确认项目首页和根站点 `https://davidhoo.github.io/` 的 URL 前缀所有权。根目录的 Google HTML 验证文件由独立的 GitHub Pages 仓库发布，应持续保留。根站点验证完成后已重试品牌验证，Google 仍提示首页未登记到发布者名下，并要求等待 24 小时同步。建议北京时间 2026-11-20 17:50 后重试；若仍是同一提示，使用控制台的额外审核入口并提供根站点和项目首页的所有权验证结果。品牌通过后需发布品牌，再提交数据访问审核。当前 DMG 是本机临时签名的预览包。

[产品首页](https://davidhoo.github.io/gmailping/) · [隐私政策](https://davidhoo.github.io/gmailping/privacy/) · [品牌页](https://console.cloud.google.com/auth/branding?project=gmailping) · [验证中心](https://console.cloud.google.com/auth/verification?project=gmailping)

## 权限用途说明（供审核表单使用）

**openid.** We use the stable Google account identifier to distinguish mailboxes on the same Mac and to ensure that reauthorization reconnects the intended account. The Gmail profile supplies the mailbox address shown in the app.

**https://www.googleapis.com/auth/gmail.metadata.** The app is a local macOS new-mail notifier. It reads the inbox label to display the unread message count. It uses the Gmail history API to distinguish newly delivered messages from older messages that the user has manually marked unread. For new candidate IDs it requests only the message ID and labels to determine whether the message belongs to the inbox. The narrower gmail.labels scope cannot access mailbox history. The app does not request permission to read message bodies, download attachments, send mail, or modify a mailbox.

**Data flow.** The desktop app opens the user's browser for consent and receives the OAuth authorization code through a loopback callback protected by state and PKCE. Tokens are stored in the macOS Keychain. Mailbox state and the deduplication records stay on the user's device. There is no developer backend receiving Gmail data. The app uses macOS notifications to show the mailbox and the number of new messages.

## 审核演示视频

使用专门的演示邮箱录制真实操作，使用英文界面或英文说明。录像从项目官网开始，展示应用名称、公开隐私政策、应用「添加账号」、Google 同意页、地址栏中的 OAuth 客户端 ID 及所请求权限。返回应用后展示未读数、一封新邮件的通知、手动将旧邮件标为未读时只更新数字，以及移除账号的入口。剪除授权回调、令牌和与演示无关的个人信息。提交审核人员可访问的视频链接。

## 提交与验收

1. 在发布者控制且已验证的域名部署首页与[隐私政策](public/privacy.md)。首页应公开介绍应用、支持方式和数据用途，并直接链接隐私政策。最终产品名、同意页、网站和安装包保持一致。
2. 在 Google Auth Platform 的品牌页保存首页、隐私政策和授权网域，使用能代表发布者的应用名称和品牌素材。按控制台提示验证并发布品牌。
3. 在受众页确认用户类型为 External，将发布状态切换为 In production。在验证中心按控制台要求提交受限范围用途、演示视频及数据处理信息。Google 返回的审核状态与「已切换为生产」分别记录。
4. 审核通过后，使用未列入测试名单的个人 Gmail 账号，在正式签名公证的安装包上验证首次授权、回调、计数和持续刷新。公开分发 macOS 安装包时记录 Developer ID 和公证验证结果。

[Google 品牌验证](https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification) · [Google 受限范围验证](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)
