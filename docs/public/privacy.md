---
layout: default
title: GmailPing 隐私政策
permalink: /privacy/
---

# 隐私政策

本政策适用于本项目提供的 macOS 邮件提醒应用。应用在你的 Mac 上检查已授权 Gmail 收件箱的未读邮件数和新增邮件，并可通过 macOS 通知中心提醒你。

## 使用的 Google 用户数据

Google 登录返回的账号标识用于区分不同账号，Gmail 返回的邮箱地址用于在设置中显示账号，并在你点击通知时打开对应的 Gmail 网页。应用从 Gmail 获取收件箱未读数量、邮箱历史位置、新增消息 ID 和标签，用于检测新增邮件、过滤收件箱和避免重复提醒。应用无需读取邮件正文或附件，不发送或修改邮件。

## 存储和传输

应用通过 HTTPS 直接与 Google 交换 OAuth 令牌并查询邮箱状态。令牌由 macOS 钥匙串保存。账号记录、同步位置、未读数量、最近检测时间和近期消息 ID 存储在本机。macOS 通知可以显示邮箱地址和邮件数量，显示方式由系统通知设置控制。打开 Gmail 时，应用把目标邮箱地址传递给默认浏览器，以便 Google 定位账号。

应用通过 HTTPS 向 GitHub Releases 请求版本清单和安装包。更新请求不携带 Gmail 邮箱地址、授权令牌、邮件 ID 或未读数。可在菜单栏右键菜单关闭自动检查应用更新。

开发者没有代收邮箱数据的服务器。应用不出售 Google 用户数据，不使用这些数据投放广告或训练模型，也不将其传给分析服务。应用对从 Google API 收到的信息的使用和转移遵守 Google API Services User Data Policy，包括 Limited Use 要求。[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)

## 保留、移除和撤销

在「偏好设置 → 账号」移除一个邮箱将停止该账号的检查，并清理本机账号记录、同步文件、对应钥匙串凭据和应用通知。建议在卸载应用前移除账号。你也可以随时在 Google 账号的第三方连接中撤销授权。撤销云端授权后，如需删除本机记录，请在应用内移除账号。[管理 Google 第三方连接](https://myaccount.google.com/connections)

## 联系

支持与隐私问题请联系项目支持邮箱。[联系开发者](mailto:coolbor@gmail.com)
