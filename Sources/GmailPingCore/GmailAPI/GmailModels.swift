import Foundation

public struct GmailProfile: Codable, Equatable, Sendable {
    public let emailAddress: String
    public let messagesTotal: Int?
    public let threadsTotal: Int?
    public let historyId: String

    public init(
        emailAddress: String,
        messagesTotal: Int? = nil,
        threadsTotal: Int? = nil,
        historyId: String
    ) {
        self.emailAddress = emailAddress
        self.messagesTotal = messagesTotal
        self.threadsTotal = threadsTotal
        self.historyId = historyId
    }
}

public struct GmailLabel: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let messagesTotal: Int?
    public let messagesUnread: Int
    public let threadsTotal: Int?
    public let threadsUnread: Int?

    public init(
        id: String,
        name: String,
        messagesTotal: Int? = nil,
        messagesUnread: Int,
        threadsTotal: Int? = nil,
        threadsUnread: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.messagesTotal = messagesTotal
        self.messagesUnread = messagesUnread
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
    }
}

public struct GmailMessage: Codable, Equatable, Sendable {
    public let id: String
    public let threadId: String?
    public let labelIds: [String]?

    public init(id: String, threadId: String? = nil, labelIds: [String]? = nil) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
    }
}

public struct GmailMessageAdded: Codable, Equatable, Sendable {
    public let message: GmailMessage

    public init(message: GmailMessage) {
        self.message = message
    }
}

public struct GmailHistoryItem: Codable, Equatable, Sendable {
    public let id: String?
    public let messagesAdded: [GmailMessageAdded]?

    public init(id: String? = nil, messagesAdded: [GmailMessageAdded]? = nil) {
        self.id = id
        self.messagesAdded = messagesAdded
    }
}

public struct GmailHistoryListResponse: Codable, Equatable, Sendable {
    public let history: [GmailHistoryItem]?
    public let nextPageToken: String?
    public let historyId: String

    public init(
        history: [GmailHistoryItem]? = nil,
        nextPageToken: String? = nil,
        historyId: String
    ) {
        self.history = history
        self.nextPageToken = nextPageToken
        self.historyId = historyId
    }
}

public enum GmailAPIError: Error, LocalizedError, Equatable {
    case unauthorized
    case historyIdExpired(startHistoryId: String)
    case messageNotFound(id: String)
    case rateLimited(retryAfter: TimeInterval?, isProjectLevel: Bool)
    case policyBlocked(reason: String)
    case serverError(statusCode: Int)
    case networkError(String)
    case parsingError(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Gmail 访问未授权或凭据过期 (401)"
        case .historyIdExpired(let id):
            return "Gmail 历史游标已过期 (404, startHistoryId: \(id))"
        case .messageNotFound(let id):
            return "邮件未找到 (404, messageId: \(id))"
        case .rateLimited(let retryAfter, let isProjectLevel):
            let scope = isProjectLevel ? "项目级配额耗尽" : "用户请求限流"
            if let seconds = retryAfter {
                return "触发 Google API \(scope)，需等待 \(Int(seconds)) 秒"
            }
            return "触发 Google API \(scope)"
        case .policyBlocked(let reason):
            return "Google 权限被限制或策略阻止: \(reason)"
        case .serverError(let code):
            return "Google API 服务端错误 (\(code))"
        case .networkError(let msg):
            return "网络异常: \(msg)"
        case .parsingError(let msg):
            return "数据解析失败: \(msg)"
        }
    }
}

public protocol GmailAPIClientProtocol: Sendable {
    func getProfile(accessToken: String) async throws -> GmailProfile
    func getInboxLabel(accessToken: String) async throws -> GmailLabel
    func listHistory(accessToken: String, startHistoryId: String, pageToken: String?) async throws -> GmailHistoryListResponse
    func getMessage(accessToken: String, messageId: String) async throws -> GmailMessage?
}
