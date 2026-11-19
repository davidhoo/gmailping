import Foundation

public enum CheckInterval: Int, Codable, CaseIterable, Sendable {
    case seconds30 = 30
    case seconds60 = 60
    case minutes2 = 120
    case minutes5 = 300
    case manual = 0

    public var title: String {
        switch self {
        case .seconds30: return "30 秒"
        case .seconds60: return "60 秒"
        case .minutes2: return "2 分钟"
        case .minutes5: return "5 分钟"
        case .manual: return "手动"
        }
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool
    public var hasInitializedLoginItem: Bool
    public var checkInterval: CheckInterval
    public var showUnreadCount: Bool
    public var hideCountWhenZero: Bool
    public var systemNotificationsEnabled: Bool
    public var notificationSoundEnabled: Bool
    public var notifyExistingUnreadOnSystemLogin: Bool
    public var defaultAccountId: UUID?

    enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case hasInitializedLoginItem
        case checkInterval
        case showUnreadCount
        case hideCountWhenZero
        case systemNotificationsEnabled
        case notificationSoundEnabled
        case notifyExistingUnreadOnSystemLogin
        case defaultAccountId
    }

    public init(
        launchAtLogin: Bool = true,
        hasInitializedLoginItem: Bool = false,
        checkInterval: CheckInterval = .seconds60,
        showUnreadCount: Bool = true,
        hideCountWhenZero: Bool = true,
        systemNotificationsEnabled: Bool = true,
        notificationSoundEnabled: Bool = true,
        notifyExistingUnreadOnSystemLogin: Bool = false,
        defaultAccountId: UUID? = nil
    ) {
        self.launchAtLogin = launchAtLogin
        self.hasInitializedLoginItem = hasInitializedLoginItem
        self.checkInterval = checkInterval
        self.showUnreadCount = showUnreadCount
        self.hideCountWhenZero = hideCountWhenZero
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.notificationSoundEnabled = notificationSoundEnabled
        self.notifyExistingUnreadOnSystemLogin = notifyExistingUnreadOnSystemLogin
        self.defaultAccountId = defaultAccountId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        // 关键向后兼容：当旧数据中缺少 hasInitializedLoginItem 字段时，判定为已安装升级老用户，
        // 默认为 true，防止覆盖用户在系统设置里已关闭的登录项，且避免重置用户的其它偏好
        self.hasInitializedLoginItem = try container.decodeIfPresent(Bool.self, forKey: .hasInitializedLoginItem) ?? true
        self.checkInterval = try container.decodeIfPresent(CheckInterval.self, forKey: .checkInterval) ?? .seconds60
        self.showUnreadCount = try container.decodeIfPresent(Bool.self, forKey: .showUnreadCount) ?? true
        self.hideCountWhenZero = try container.decodeIfPresent(Bool.self, forKey: .hideCountWhenZero) ?? true
        self.systemNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? true
        self.notificationSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled) ?? true
        self.notifyExistingUnreadOnSystemLogin = try container.decodeIfPresent(Bool.self, forKey: .notifyExistingUnreadOnSystemLogin) ?? false
        self.defaultAccountId = try container.decodeIfPresent(UUID.self, forKey: .defaultAccountId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(hasInitializedLoginItem, forKey: .hasInitializedLoginItem)
        try container.encode(checkInterval, forKey: .checkInterval)
        try container.encode(showUnreadCount, forKey: .showUnreadCount)
        try container.encode(hideCountWhenZero, forKey: .hideCountWhenZero)
        try container.encode(systemNotificationsEnabled, forKey: .systemNotificationsEnabled)
        try container.encode(notificationSoundEnabled, forKey: .notificationSoundEnabled)
        try container.encode(notifyExistingUnreadOnSystemLogin, forKey: .notifyExistingUnreadOnSystemLogin)
        try container.encodeIfPresent(defaultAccountId, forKey: .defaultAccountId)
    }
}
