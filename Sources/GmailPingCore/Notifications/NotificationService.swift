import Foundation
import UserNotifications

public protocol NotificationServiceProtocol: Sendable {
    func requestAuthorization() async -> Bool
    func deliverBatch(
        _ batch: NotificationBatch,
        playSound: Bool
    ) async -> Bool
    func deliverLoginSummary(
        accountId: UUID,
        email: String,
        unreadCount: Int,
        playSound: Bool
    ) async -> Bool
    func clearNotifications(for accountId: UUID) async
    func getPendingAndDeliveredNotificationIds(for accountId: UUID) async -> Set<String>
}

public final class NotificationService: NSObject, NotificationServiceProtocol, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private var onNotificationClick: (@Sendable (UUID, String) -> Void)?

    public init(onNotificationClick: (@Sendable (UUID, String) -> Void)? = nil) {
        self.onNotificationClick = onNotificationClick
        super.init()
        center.delegate = self
    }

    public func setNotificationClickHandler(_ handler: @escaping @Sendable (UUID, String) -> Void) {
        self.onNotificationClick = handler
    }

    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            return granted
        } catch {
            return false
        }
    }

    public func deliverBatch(
        _ batch: NotificationBatch,
        playSound: Bool
    ) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "收到新邮件"
        content.subtitle = batch.accountEmail
        content.body = "收到 \(batch.count) 封新邮件"
        if playSound {
            content.sound = .default
        }
        content.threadIdentifier = batch.accountId.uuidString
        content.userInfo = [
            "accountId": batch.accountId.uuidString,
            "email": batch.accountEmail
        ]

        let request = UNNotificationRequest(
            identifier: batch.id,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    public func deliverLoginSummary(
        accountId: UUID,
        email: String,
        unreadCount: Int,
        playSound: Bool
    ) async -> Bool {
        guard unreadCount > 0 else { return false }
        let content = UNMutableNotificationContent()
        content.title = "收件箱有 \(unreadCount) 封未读邮件"
        content.subtitle = email
        content.body = ""
        if playSound {
            content.sound = .default
        }
        content.threadIdentifier = accountId.uuidString
        content.userInfo = [
            "accountId": accountId.uuidString,
            "email": email
        ]

        let identifier = "login-summary-\(accountId.uuidString)-\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    public func clearNotifications(for accountId: UUID) async {
        let prefix = accountId.uuidString
        let pending = await center.pendingNotificationRequests()
        let pendingIds = pending.filter { $0.identifier.contains(prefix) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pendingIds)

        let delivered = await center.deliveredNotifications()
        let deliveredIds = delivered.filter { $0.request.identifier.contains(prefix) }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
    }

    public func getPendingAndDeliveredNotificationIds(for accountId: UUID) async -> Set<String> {
        let prefix = accountId.uuidString
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()

        var ids = Set<String>()
        for r in pending where r.identifier.contains(prefix) {
            ids.insert(r.identifier)
        }
        for d in delivered where d.request.identifier.contains(prefix) {
            ids.insert(d.request.identifier)
        }
        return ids
    }

    // UNUserNotificationCenterDelegate
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let idString = userInfo["accountId"] as? String,
           let accountId = UUID(uuidString: idString),
           let email = userInfo["email"] as? String {
            onNotificationClick?(accountId, email)
        }
        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

public actor MockNotificationService: NotificationServiceProtocol {
    public private(set) var deliveredBatches: [NotificationBatch] = []
    public private(set) var deliveredSummaries: [(accountId: UUID, email: String, count: Int)] = []
    public var authorizationGranted: Bool = true
    public private(set) var clearedAccounts: [UUID] = []

    public init() {}

    public func setAuthorizationGranted(_ granted: Bool) {
        self.authorizationGranted = granted
    }

    public func requestAuthorization() async -> Bool {
        return authorizationGranted
    }

    public func deliverBatch(
        _ batch: NotificationBatch,
        playSound: Bool
    ) async -> Bool {
        guard authorizationGranted else { return false }
        deliveredBatches.append(batch)
        return true
    }

    public func deliverLoginSummary(
        accountId: UUID,
        email: String,
        unreadCount: Int,
        playSound: Bool
    ) async -> Bool {
        guard authorizationGranted, unreadCount > 0 else { return false }
        deliveredSummaries.append((accountId, email, unreadCount))
        return true
    }

    public func clearNotifications(for accountId: UUID) async {
        clearedAccounts.append(accountId)
        deliveredBatches.removeAll { $0.accountId == accountId }
        deliveredSummaries.removeAll { $0.accountId == accountId }
    }

    public func getPendingAndDeliveredNotificationIds(for accountId: UUID) async -> Set<String> {
        let batchIds = deliveredBatches.filter { $0.accountId == accountId }.map(\.id)
        return Set(batchIds)
    }

    public func reset() {
        deliveredBatches.removeAll()
        deliveredSummaries.removeAll()
        clearedAccounts.removeAll()
    }
}
