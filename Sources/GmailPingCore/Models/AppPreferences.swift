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
    public var checkInterval: CheckInterval
    public var showUnreadCount: Bool
    public var hideCountWhenZero: Bool
    public var systemNotificationsEnabled: Bool
    public var notificationSoundEnabled: Bool
    public var notifyExistingUnreadOnSystemLogin: Bool
    public var defaultAccountId: UUID?

    public init(
        launchAtLogin: Bool = true,
        checkInterval: CheckInterval = .seconds60,
        showUnreadCount: Bool = true,
        hideCountWhenZero: Bool = true,
        systemNotificationsEnabled: Bool = true,
        notificationSoundEnabled: Bool = true,
        notifyExistingUnreadOnSystemLogin: Bool = false,
        defaultAccountId: UUID? = nil
    ) {
        self.launchAtLogin = launchAtLogin
        self.checkInterval = checkInterval
        self.showUnreadCount = showUnreadCount
        self.hideCountWhenZero = hideCountWhenZero
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.notificationSoundEnabled = notificationSoundEnabled
        self.notifyExistingUnreadOnSystemLogin = notifyExistingUnreadOnSystemLogin
        self.defaultAccountId = defaultAccountId
    }
}
