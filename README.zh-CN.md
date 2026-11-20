# GmailPing

[English](README.md) · **简体中文** · [日本語](README.ja.md) · [Español](README.es.md)

GmailPing 在 Mac 菜单栏显示多个 Gmail 收件箱的未读邮件总数。收到新邮件时，点一下通知，就能在默认浏览器里打开收到这封信的邮箱。

## 安装并连接 Gmail

1. 前往[下载页面](https://github.com/davidhoo/gmailping/releases)下载通用版 `.dmg`，适用于运行 macOS 13 或更新版本的 Apple 芯片和 Intel 芯片 Mac。如果选择 `.dmg.zip`，先解压。1.0.2 是采用临时签名的预览版，尚未经过 Apple 公证。
2. 打开磁盘映像，将 **GmailPing** 拖入「应用程序」，再从那里启动。菜单栏会出现一个信封图标。
3. 点信封打开偏好设置，选择 **账号 → 添加 Google 账号...**，在浏览器中选中邮箱并授权。要关注其他邮箱，重复这一步即可。
4. 如果想收到新邮件提醒，请在 macOS 询问时允许通知。之后可以在**偏好设置**中调整提示音和检查间隔。

## 打开有未读邮件的收件箱

点一下信封。如果只有一个邮箱有未读邮件，会直接打开该邮箱；如果有多个，菜单会列出各自的地址和未读数，点选即可。没有已知未读时会打开默认邮箱。右键信封可以查看各账号上次检查的时间、立即检查邮件，或更改默认账号。

同一轮检查中，同一个邮箱收到的多封新邮件会合并为一条通知。把旧邮件标为未读只会更新计数，不会触发新邮件提醒。

## 隐私与支持

GmailPing 从你的 Mac 直接连接 Google，查询邮件数量、邮件 ID 和标签。正文和附件留在 Gmail，每个账号的授权令牌都保存在 macOS 钥匙串。要断开连接，可在「账号」中移除邮箱，也可以在 Google 账号中撤销授权。[隐私政策](https://davidhoo.github.io/gmailping/privacy/) · [管理 Google 账号连接](https://myaccount.google.com/connections)

如需帮助，请在[支持邮件](mailto:coolbor@gmail.com)中注明 macOS 和 GmailPing 的版本。

[开发者指南](docs/development/README.zh-CN.md) · [MIT 许可证](LICENSE)
