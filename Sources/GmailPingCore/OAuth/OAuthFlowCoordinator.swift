import Foundation

public final class OAuthFlowCoordinator: @unchecked Sendable {
    private let oauthClient: GoogleOAuthClientProtocol
    private let gmailClient: GmailAPIClientProtocol
    private let keychainStorage: KeychainStorageProtocol
    private let accountStorage: AccountStorage
    private let browserLauncher: BrowserLauncherProtocol
    private let syncEngine: IncrementalSyncEngine

    public init(
        oauthClient: GoogleOAuthClientProtocol,
        gmailClient: GmailAPIClientProtocol,
        keychainStorage: KeychainStorageProtocol,
        accountStorage: AccountStorage,
        browserLauncher: BrowserLauncherProtocol,
        syncEngine: IncrementalSyncEngine
    ) {
        self.oauthClient = oauthClient
        self.gmailClient = gmailClient
        self.keychainStorage = keychainStorage
        self.accountStorage = accountStorage
        self.browserLauncher = browserLauncher
        self.syncEngine = syncEngine
    }

    public func addAccountFlow() async throws -> Account {
        let listener = LoopbackListener()
        let port = try listener.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        let state = PKCE.generateRandomString(length: 32)
        let nonce = PKCE.generateRandomString(length: 32)
        let codeVerifier = PKCE.generateCodeVerifier()
        let codeChallenge = PKCE.generateCodeChallenge(from: codeVerifier)

        guard let authURL = oauthClient.buildAuthorizationURL(
            state: state,
            nonce: nonce,
            codeChallenge: codeChallenge,
            redirectURI: redirectURI,
            loginHint: nil
        ) else {
            listener.stop()
            throw OAuthError.invalidRedirectURI
        }

        _ = browserLauncher.openURL(authURL)

        let params = try await listener.waitForCallback(timeoutSeconds: 120)
        guard let returnedState = params["state"], returnedState == state else {
            throw OAuthError.stateMismatch
        }
        guard let code = params["code"] else {
            throw OAuthError.missingCode
        }

        let tokenResult = try await oauthClient.exchangeCode(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            expectedNonce: nonce
        )

        // Fetch user profile from Gmail API to get confirmed email
        let profile = try await gmailClient.getProfile(accessToken: tokenResult.accessToken)
        let email = profile.emailAddress

        // Add or update account in account directory
        let (account, _) = try await accountStorage.addOrUpdateAccount(
            googleSub: tokenResult.googleSub,
            email: email
        )

        // Save token to Keychain
        let token = OAuthToken(
            accountId: account.id,
            accessToken: tokenResult.accessToken,
            refreshToken: tokenResult.refreshToken,
            expiresAt: tokenResult.expiresAt
        )
        try keychainStorage.saveToken(token)

        // Establish silent baseline
        _ = try await syncEngine.buildBaseline(
            account: account,
            accessToken: tokenResult.accessToken,
            isSystemLoginStartup: false
        )

        return account
    }

    public func reauthAccountFlow(account: Account) async throws {
        let listener = LoopbackListener()
        let port = try listener.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        let state = PKCE.generateRandomString(length: 32)
        let nonce = PKCE.generateRandomString(length: 32)
        let codeVerifier = PKCE.generateCodeVerifier()
        let codeChallenge = PKCE.generateCodeChallenge(from: codeVerifier)

        guard let authURL = oauthClient.buildAuthorizationURL(
            state: state,
            nonce: nonce,
            codeChallenge: codeChallenge,
            redirectURI: redirectURI,
            loginHint: account.email
        ) else {
            listener.stop()
            throw OAuthError.invalidRedirectURI
        }

        _ = browserLauncher.openURL(authURL)

        let params = try await listener.waitForCallback(timeoutSeconds: 120)
        guard let returnedState = params["state"], returnedState == state else {
            throw OAuthError.stateMismatch
        }
        guard let code = params["code"] else {
            throw OAuthError.missingCode
        }

        let tokenResult = try await oauthClient.exchangeCode(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            expectedNonce: nonce
        )

        // Strict sub verification: must match existing account sub!
        guard tokenResult.googleSub == account.googleSub else {
            throw OAuthError.subMismatch(expected: account.googleSub, actual: tokenResult.googleSub)
        }

        let profile = try await gmailClient.getProfile(accessToken: tokenResult.accessToken)
        let (updatedAcc, _) = try await accountStorage.addOrUpdateAccount(
            googleSub: tokenResult.googleSub,
            email: profile.emailAddress
        )

        let existingToken = try keychainStorage.getToken(for: account.id)
        let token = OAuthToken(
            accountId: updatedAcc.id,
            accessToken: tokenResult.accessToken,
            refreshToken: tokenResult.refreshToken ?? existingToken?.refreshToken,
            expiresAt: tokenResult.expiresAt
        )
        try keychainStorage.saveToken(token)

        await syncEngine.clearBackoff(accountId: updatedAcc.id)
        _ = await syncEngine.syncAccount(accountId: updatedAcc.id)
    }
}
