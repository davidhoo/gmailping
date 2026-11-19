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
        if let reason = snapshot?.lastErrorReason, snapshot?.needsReauth == true {
            return "异常: \(reason)"
        }
        if let time = snapshot?.lastSuccessTime {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "更新于 \(formatter.string(from: time))"
        }
        if let reason = snapshot?.lastErrorReason {
            return "异常: \(reason)"
        }
        return "尚未同步"
    }
}

public struct MenuBarDisplayState: Equatable, Sendable {
    public let title: String
    public let tooltip: String
    public let totalUnread: Int?
    public let hasAnyAccounts: Bool
    public let hasPendingAccounts: Bool
    public let hasOfflineOrReauthAccounts: Bool
    public let accountItems: [AccountStatusItem]

    public init(
        title: String,
        tooltip: String,
        totalUnread: Int?,
        hasAnyAccounts: Bool,
        hasPendingAccounts: Bool,
        hasOfflineOrReauthAccounts: Bool,
        accountItems: [AccountStatusItem]
    ) {
        self.title = title
        self.tooltip = tooltip
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
        var hasPending = false
        var hasOfflineOrReauth = false

        for acc in activeAccounts {
            let snap = snapshots[acc.id]
            let isDef = acc.id == defaultAccountId
            items.append(AccountStatusItem(account: acc, snapshot: snap, isDefault: isDef))

            if let unread = snap?.unreadCount {
                total += unread
                hasAtLeastOneSynced = true
            } else {
                hasPending = true
            }

            if snap?.isOffline == true || snap?.needsReauth == true {
                hasOfflineOrReauth = true
            }
        }

        // Title format
        let title: String
        if !preferences.showUnreadCount {
            title = ""
        } else if !hasAtLeastOneSynced {
            // No account has synced yet
            title = ""
        } else if total == 0 && preferences.hideCountWhenZero {
            title = ""
        } else if total >= 100 {
            title = " 99+"
        } else {
            title = " \(total)"
        }

        // Tooltip
        var tooltipParts: [String] = []
        tooltipParts.append("GmailPing")
        if hasAtLeastOneSynced {
            tooltipParts.append("合计 \(total) 封未读")
        } else {
            tooltipParts.append("等待同步")
        }

        if hasOfflineOrReauth {
            tooltipParts.append("部分账号待更新")
        } else if hasPending {
            tooltipParts.append("有账号等待同步")
        }

        return MenuBarDisplayState(
            title: title,
            tooltip: tooltipParts.joined(separator: " · "),
            totalUnread: hasAtLeastOneSynced ? total : nil,
            hasAnyAccounts: true,
            hasPendingAccounts: hasPending,
            hasOfflineOrReauthAccounts: hasOfflineOrReauth,
            accountItems: items
        )
    }
}
