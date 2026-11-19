import Foundation

public struct Account: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let googleSub: String
    public var email: String
    public let addedAt: Date
    public var order: Int
    public var isPendingCleanup: Bool

    public init(
        id: UUID = UUID(),
        googleSub: String,
        email: String,
        addedAt: Date = Date(),
        order: Int = 0,
        isPendingCleanup: Bool = false
    ) {
        self.id = id
        self.googleSub = googleSub
        self.email = email
        self.addedAt = addedAt
        self.order = order
        self.isPendingCleanup = isPendingCleanup
    }
}

public struct AccountDirectory: Codable, Equatable, Sendable {
    public var version: Int
    public var accounts: [Account]
    public var defaultAccountId: UUID?

    public init(
        version: Int = 1,
        accounts: [Account] = [],
        defaultAccountId: UUID? = nil
    ) {
        self.version = version
        self.accounts = accounts
        self.defaultAccountId = defaultAccountId
    }
}
