import Foundation

public actor OAuthFlowCoordinator {
    private let oauthClient: GoogleOAuthClientProtocol
    private let gmailClient: GmailAPIClientProtocol
    private let keychainStorage: KeychainStorageProtocol
    private let accountStorage: AccountStorage
    private let browserLauncher: BrowserLauncherProtocol
    private let syncEngine: IncrementalSyncEngine

    private var activeListener: LoopbackListener?

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

    public func cancel() {
        activeListener?.cancel()
        activeListener = nil
    }

    public func addAccountFlow() async throws -> Account {
        try oauthClient.validateConfiguration()
        let listener = LoopbackListener()
        activeListener = listener

        defer {
            listener.stop()
            if activeListener === listener {
                activeListener = nil
            }
        }

        let state = PKCE.generateRandomString(length: 32)
        let nonce = PKCE.generateRandomString(length: 32)
        let codeVerifier = PKCE.generateCodeVerifier()
        let codeChallenge = PKCE.generateCodeChallenge(from: codeVerifier)

        let port = try listener.start(expectedState: state)
        let redirectURI = "http://127.0.0.1:\(port)"

        guard let authURL = oauthClient.buildAuthorizationURL(
            state: state,
            nonce: nonce,
            codeChallenge: codeChallenge,
            redirectURI: redirectURI,
            loginHint: nil
        ) else {
            throw OAuthError.invalidRedirectURI
        }

        _ = browserLauncher.openURL(authURL)

        let params = try await listener.waitForCallback(expectedState: state, timeoutSeconds: 120)
        guard let code = params["code"] else {
            throw OAuthError.missingCode
        }

        let tokenResult = try await oauthClient.exchangeCode(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            expectedNonce: nonce
        )

        // Must acquire refresh token on new account connection
        guard let refreshToken = tokenResult.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.missingRefreshToken
        }

        // Fetch user profile to get confirmed primary email
        let profile = try await gmailClient.getProfile(accessToken: tokenResult.accessToken)
        let email = profile.emailAddress

        // Check if an active account with this googleSub already exists
        let existingAccount = try await accountStorage.getActiveAccount(byGoogleSub: tokenResult.googleSub)
        let targetAccountId = existingAccount?.id ?? UUID()

        // Order: First save credentials to Keychain, then publish account record
        let token = OAuthToken(
            accountId: targetAccountId,
            accessToken: tokenResult.accessToken,
            refreshToken: refreshToken,
            expiresAt: tokenResult.expiresAt
        )
        try keychainStorage.saveToken(token)

        let (account, isNew) = try await accountStorage.addOrUpdateAccount(
            googleSub: tokenResult.googleSub,
            email: email,
            explicitId: targetAccountId
        )

        try await syncEngine.markReauthorized(accountId: account.id)

        if isNew {
            // Establish silent baseline for new account
            _ = try await syncEngine.buildBaseline(
                account: account,
                accessToken: tokenResult.accessToken,
                isSystemLoginStartup: false
            )
        } else {
            // Re-adding existing active account: refresh sync from current state
            let syncResult = await syncEngine.syncAccount(accountId: account.id, isManualTrigger: true)
            if case .failure(let err) = syncResult {
                throw err
            }
        }

        return account
    }

    public func reauthAccountFlow(account: Account) async throws {
        try oauthClient.validateConfiguration()
        let listener = LoopbackListener()
        activeListener = listener

        defer {
            listener.stop()
            if activeListener === listener {
                activeListener = nil
            }
        }

        let state = PKCE.generateRandomString(length: 32)
        let nonce = PKCE.generateRandomString(length: 32)
        let codeVerifier = PKCE.generateCodeVerifier()
        let codeChallenge = PKCE.generateCodeChallenge(from: codeVerifier)

        let port = try listener.start(expectedState: state)
        let redirectURI = "http://127.0.0.1:\(port)"

        guard let authURL = oauthClient.buildAuthorizationURL(
            state: state,
            nonce: nonce,
            codeChallenge: codeChallenge,
            redirectURI: redirectURI,
            loginHint: account.email
        ) else {
            throw OAuthError.invalidRedirectURI
        }

        _ = browserLauncher.openURL(authURL)

        let params = try await listener.waitForCallback(expectedState: state, timeoutSeconds: 120)
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
            throw OAuthError.subMismatch(
                expected: account.googleSub,
                actual: tokenResult.googleSub,
                expectedEmail: account.email
            )
        }

        let profile = try await gmailClient.getProfile(accessToken: tokenResult.accessToken)
        let (updatedAcc, _) = try await accountStorage.addOrUpdateAccount(
            googleSub: tokenResult.googleSub,
            email: profile.emailAddress,
            explicitId: account.id
        )

        let existingToken = try keychainStorage.getToken(for: account.id)
        let token = OAuthToken(
            accountId: updatedAcc.id,
            accessToken: tokenResult.accessToken,
            refreshToken: tokenResult.refreshToken ?? existingToken?.refreshToken,
            expiresAt: tokenResult.expiresAt
        )
        try keychainStorage.saveToken(token)

        try await syncEngine.markReauthorized(accountId: updatedAcc.id)
        let syncResult = await syncEngine.syncAccount(accountId: updatedAcc.id, isManualTrigger: true)
        if case .failure(let error) = syncResult {
            throw error
        }
    }
}
