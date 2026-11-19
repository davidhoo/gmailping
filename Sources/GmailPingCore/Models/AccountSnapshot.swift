import Foundation

public struct NotificationBatch: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending
        case delivering
        case delivered
    }

    public let id: String
    public let accountId: UUID
    public let accountEmail: String
    public let count: Int
    public var status: Status
    public let createdAt: Date

    public init(
        id: String,
        accountId: UUID,
        accountEmail: String,
        count: Int,
        status: Status = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.accountEmail = accountEmail
        self.count = count
        self.status = status
        self.createdAt = createdAt
    }
}

public struct AccountSnapshot: Codable, Equatable, Sendable {
    public let accountId: UUID
    public var historyId: String?
    public var unreadCount: Int?
    public var lastSuccessTime: Date?
    public var lastErrorReason: String?
    public var needsReauth: Bool
    public var isOffline: Bool
    public var knownMessageIds: [String]
    public var pendingBatches: [NotificationBatch]

    public init(
        accountId: UUID,
        historyId: String? = nil,
        unreadCount: Int? = nil,
        lastSuccessTime: Date? = nil,
        lastErrorReason: String? = nil,
        needsReauth: Bool = false,
        isOffline: Bool = false,
        knownMessageIds: [String] = [],
        pendingBatches: [NotificationBatch] = []
    ) {
        self.accountId = accountId
        self.historyId = historyId
        self.unreadCount = unreadCount
        self.lastSuccessTime = lastSuccessTime
        self.lastErrorReason = lastErrorReason
        self.needsReauth = needsReauth
        self.isOffline = isOffline
        self.knownMessageIds = knownMessageIds
        self.pendingBatches = pendingBatches
    }
}
