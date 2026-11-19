import Foundation
@testable import GmailPingCore

public struct TestEnvironment {
    public let tempDir: URL
    public let accountStorage: AccountStorage
    public let keychainStorage: MockKeychainStorage
    public let preferencesStorage: MockPreferencesStorage
    public let gmailClient: MockGmailAPIClient
    public let oauthClient: MockOAuthClient
    public let notificationService: MockNotificationService
    public let browserLauncher: MockBrowserLauncher
    public let loginItemManager: MockLoginItemManager
    public let syncEngine: IncrementalSyncEngine
    public let manager: GmailPingManager

    public init() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("GmailPingTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        self.tempDir = temp

        self.accountStorage = AccountStorage(baseDirectory: temp)
        self.keychainStorage = MockKeychainStorage()
        self.preferencesStorage = MockPreferencesStorage()
        self.gmailClient = MockGmailAPIClient()
        self.oauthClient = MockOAuthClient()
        self.notificationService = MockNotificationService()
        self.browserLauncher = MockBrowserLauncher()
        self.loginItemManager = MockLoginItemManager()

        self.syncEngine = IncrementalSyncEngine(
            accountStorage: accountStorage,
            keychainStorage: keychainStorage,
            gmailClient: gmailClient,
            oauthClient: oauthClient,
            notificationService: notificationService,
            preferencesStorage: preferencesStorage
        )

        self.manager = GmailPingManager(
            accountStorage: accountStorage,
            keychainStorage: keychainStorage,
            preferencesStorage: preferencesStorage,
            oauthClient: oauthClient,
            gmailClient: gmailClient,
            notificationService: notificationService,
            browserLauncher: browserLauncher,
            loginItemManager: loginItemManager
        )
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

public final class MockOAuthClient: GoogleOAuthClientProtocol, @unchecked Sendable {
    public var authorizationURL: URL? = URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=test")
    public var exchangeResult: Result<TokenExchangeResult, Error>?
    public var refreshResult: Result<(accessToken: String, newRefreshToken: String?, expiresAt: Date), Error>?

    public init() {}

    public func buildAuthorizationURL(
        state: String,
        nonce: String,
        codeChallenge: String,
        redirectURI: String,
        loginHint: String?
    ) -> URL? {
        return authorizationURL
    }

    public func exchangeCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        expectedNonce: String
    ) async throws -> TokenExchangeResult {
        if let res = exchangeResult {
            return try res.get()
        }
        return TokenExchangeResult(
            accessToken: "mock_access_token",
            refreshToken: "mock_refresh_token",
            expiresAt: Date().addingTimeInterval(3600),
            googleSub: "sub_default",
            emailFromIdToken: "default@example.com"
        )
    }

    public func refreshToken(
        _ currentRefreshToken: String
    ) async throws -> (accessToken: String, newRefreshToken: String?, expiresAt: Date) {
        if let res = refreshResult {
            return try res.get()
        }
        return ("refreshed_access_token", "new_refresh_token", Date().addingTimeInterval(3600))
    }
}
