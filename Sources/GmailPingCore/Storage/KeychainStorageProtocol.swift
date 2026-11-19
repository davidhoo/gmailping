import Foundation

public protocol KeychainStorageProtocol: Sendable {
    func saveToken(_ token: OAuthToken) throws
    func getToken(for accountId: UUID) throws -> OAuthToken?
    func deleteToken(for accountId: UUID) throws
    func allStoredAccountIds() throws -> [UUID]
}
