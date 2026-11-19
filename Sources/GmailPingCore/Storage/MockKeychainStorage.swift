import Foundation

public final class MockKeychainStorage: KeychainStorageProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: OAuthToken] = [:]

    public init(initialTokens: [OAuthToken] = []) {
        for token in initialTokens {
            storage[token.accountId] = token
        }
    }

    public func saveToken(_ token: OAuthToken) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[token.accountId] = token
    }

    public func getToken(for accountId: UUID) throws -> OAuthToken? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountId]
    }

    public func deleteToken(for accountId: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountId)
    }

    public func allStoredAccountIds() throws -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.keys)
    }
}
