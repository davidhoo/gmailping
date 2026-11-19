import Foundation

public struct AccountStatusItem: Equatable, Sendable {
    public let account: Account
    public let snapshot: AccountSnapshot?
    public let isDefault: Bool

    public init(account: Account, snapshot: AccountSnapshot?, isDefault: Bool) {
        self.account = account
        self.snapshot = snapshot
        self.isDefault = isDefault
    }

    public var displayTitle: String {
        var title = account.email
        if isDefault {
            title += " (默认)"
        }
        return title
    }

    public var unreadString: String {
        guard let count = snapshot?.unreadCount else {
            return "等待同步"
        }
        return "\(count) 封未读"
    }

    public var lastSyncString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        let timeStr = snapshot?.lastSuccessTime.map { formatter.string(from: $0) }

        if snapshot?.needsReauth == true {
            if let time = timeStr {
                return "待重新授权 (上次成功 \(time))"
            }
            return "待重新授权: \(snapshot?.lastErrorReason ?? "凭据失效")"
        }

        if let reason = snapshot?.lastErrorReason {
            if let time = timeStr {
                return "异常: \(reason) (上次成功 \(time))"
            }
            return "异常: \(reason)"
        }

        if let time = timeStr {
            return "更新于 \(time)"
        }

        return "尚未同步"
    }
}

public struct MenuBarDisplayState: Equatable, Sendable {
    public enum PrimaryClickAction: Equatable, Sendable {
        case openPreferences
        case openInbox(UUID)
        case chooseAccount([AccountStatusItem])
    }

    public let title: String
    public let tooltip: String
    public let accessibilityDescription: String
    public let totalUnread: Int?
    public let hasAnyAccounts: Bool
    public let hasPendingAccounts: Bool
    public let hasOfflineOrReauthAccounts: Bool
    public let accountItems: [AccountStatusItem]

    public var primaryClickAction: PrimaryClickAction {
        let unreadAccounts = accountItems.filter { ($0.snapshot?.unreadCount ?? 0) > 0 }
        if unreadAccounts.count > 1 {
            return .chooseAccount(unreadAccounts)
        }
        guard let target = unreadAccounts.first ?? accountItems.first(where: { $0.isDefault }) ?? accountItems.first else {
            return .openPreferences
        }
        return .openInbox(target.account.id)
    }

    public init(
        title: String,
        tooltip: String,
        accessibilityDescription: String = "",
        totalUnread: Int?,
        hasAnyAccounts: Bool,
        hasPendingAccounts: Bool,
        hasOfflineOrReauthAccounts: Bool,
        accountItems: [AccountStatusItem]
    ) {
        self.title = title
        self.tooltip = tooltip
        self.accessibilityDescription = accessibilityDescription.isEmpty ? tooltip : accessibilityDescription
        self.totalUnread = totalUnread
        self.hasAnyAccounts = hasAnyAccounts
        self.hasPendingAccounts = hasPendingAccounts
        self.hasOfflineOrReauthAccounts = hasOfflineOrReauthAccounts
        self.accountItems = accountItems
    }
}

public struct MenuBarStateCalculator {
    public static func computeDisplayState(
        accounts: [Account],
        defaultAccountId: UUID?,
        snapshots: [UUID: AccountSnapshot],
        preferences: AppPreferences
    ) -> MenuBarDisplayState {
        let activeAccounts = accounts.filter { !$0.isPendingCleanup }

        guard !activeAccounts.isEmpty else {
            return MenuBarDisplayState(
                title: "",
                tooltip: "GmailPing (未添加账号)",
                accessibilityDescription: "GmailPing，未添加账号",
                totalUnread: nil,
                hasAnyAccounts: false,
                hasPendingAccounts: false,
                hasOfflineOrReauthAccounts: false,
                accountItems: []
            )
        }

        var items: [AccountStatusItem] = []
        var total = 0
        var hasAtLeastOneSynced = false
        var hasEverSyncedAny = false
        var staleAccounts: [String] = []
        var pendingCount = 0

        for acc in activeAccounts {
            let snap = snapshots[acc.id]
            let isDef = acc.id == defaultAccountId
            items.append(AccountStatusItem(account: acc, snapshot: snap, isDefault: isDef))

            if let unread = snap?.unreadCount {
                total += unread
                hasAtLeastOneSynced = true
            } else {
                pendingCount += 1
            }

            if snap?.lastSuccessTime != nil {
                hasEverSyncedAny = true
            }

            if snap?.isOffline == true || snap?.needsReauth == true {
                staleAccounts.append(acc.email)
            }
        }

        let hasPending = pendingCount > 0
        let hasOfflineOrReauth = !staleAccounts.isEmpty

        // Determine title display
        let title: String
        if !preferences.showUnreadCount {
            title = ""
        } else if !hasEverSyncedAny && !hasAtLeastOneSynced {
            // First time sync, no account has ever completed sync yet
            title = " 等待同步"
        } else if !hasAtLeastOneSynced {
            // All accounts unknown/stale without known counts -> pure icon
            title = ""
        } else if total == 0 && preferences.hideCountWhenZero {
            // Synced and total is 0 with hideCountWhenZero enabled -> pure icon
            title = ""
        } else if total >= 100 {
            title = " 99+"
        } else {
            title = " \(total)"
        }

        // Construct tooltip & accessibility descriptions
        var tooltipParts: [String] = ["GmailPing"]
        var accessParts: [String] = ["GmailPing"]

        if hasAtLeastOneSynced {
            tooltipParts.append("合计 \(total) 封未读")
            accessParts.append("合计 \(total) 封未读邮件")
        } else if !hasEverSyncedAny {
            tooltipParts.append("等待同步")
            accessParts.append("所有账号正在等待首次同步")
        } else {
            tooltipParts.append("全部账号待更新")
            accessParts.append("全部账号数据暂不可用，待更新")
        }

        if hasOfflineOrReauth {
            let accountList = staleAccounts.joined(separator: "、")
            tooltipParts.append("部分账号待更新: \(accountList)")
            accessParts.append("待更新账号：\(accountList)")
        }

        if hasPending && hasAtLeastOneSynced {
            tooltipParts.append("有 \(pendingCount) 个账号尚无数据")
            accessParts.append("有 \(pendingCount) 个账号正在等待首次同步")
        }

        return MenuBarDisplayState(
            title: title,
            tooltip: tooltipParts.joined(separator: " · "),
            accessibilityDescription: accessParts.joined(separator: "，"),
            totalUnread: hasAtLeastOneSynced ? total : nil,
            hasAnyAccounts: true,
            hasPendingAccounts: hasPending,
            hasOfflineOrReauthAccounts: hasOfflineOrReauth,
            accountItems: items
        )
    }
}
