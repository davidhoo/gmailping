import Foundation

public struct OAuthToken: Codable, Equatable, Sendable {
    public let accountId: UUID
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(
        accountId: UUID,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date
    ) {
        self.accountId = accountId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        // 60-second safety margin
        return Date().addingTimeInterval(60) >= expiresAt
    }
}
