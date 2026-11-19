import XCTest
@testable import GmailPingCore

final class AcceptanceTests_Scenarios18_19_AndCore: XCTestCase {
    var env: TestEnvironment!

    override func setUp() {
        super.setUp()
        env = TestEnvironment()
    }

    override func tearDown() {
        env.cleanup()
        super.tearDown()
    }

    // MARK: - 场景 18: 登录项控制与应用生命周期
    func testScenario18_LoginItemAndLifecycle() async throws {
        XCTAssertFalse(env.loginItemManager.isEnabled)
        XCTAssertEqual(env.loginItemManager.status, .notRegistered)

        var prefs = env.preferencesStorage.loadPreferences()
        prefs.launchAtLogin = true
        await env.manager.updatePreferences(prefs)

        XCTAssertTrue(env.loginItemManager.isEnabled)
        XCTAssertEqual(env.loginItemManager.status, .enabled)

        prefs.launchAtLogin = false
        await env.manager.updatePreferences(prefs)

        XCTAssertFalse(env.loginItemManager.isEnabled)

        // Stop manager stops scheduler
        env.manager.stop()
    }

    // MARK: - 场景 19: 菜单栏图标规范与渲染属性
    func testScenario19_MenuBarIconProperties() {
        let icon = MenuBarIcon.makeEnvelopeIcon()
        XCTAssertTrue(icon.isTemplate, "独立信封菜单栏图标必须使用模板渲染以自适应系统浅色/深色外观")
        XCTAssertEqual(icon.size.width, 18.0)
        XCTAssertEqual(icon.size.height, 18.0)
    }

    // MARK: - PKCE RFC 7636 官方测试向量验证
    func testPKCE_RFC7636_TestVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.generateCodeChallenge(from: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // MARK: - Keychain 存储与孤立条目清理
    func testKeychainAndOrphanCleanup() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        let tokenA = OAuthToken(
            accountId: accountA.id,
            accessToken: "token_A",
            refreshToken: "refresh_A",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try env.keychainStorage.saveToken(tokenA)

        // Add orphan token in Keychain
        let orphanId = UUID()
        let orphanToken = OAuthToken(
            accountId: orphanId,
            accessToken: "orphan_token",
            refreshToken: "orphan_refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try env.keychainStorage.saveToken(orphanToken)

        var allIds = try env.keychainStorage.allStoredAccountIds()
        XCTAssertTrue(allIds.contains(orphanId))
        XCTAssertTrue(allIds.contains(accountA.id))

        // Run cleanup
        try await env.accountStorage.cleanupOrphans(keychain: env.keychainStorage)

        allIds = try env.keychainStorage.allStoredAccountIds()
        XCTAssertFalse(allIds.contains(orphanId), "孤立凭据应在启动时被清理")
        XCTAssertTrue(allIds.contains(accountA.id), "有效账号凭据应保留")
    }

    // MARK: - 新账号缺失 Refresh Token 拒绝连接
    func testMissingRefreshToken_RejectsAccountConnection() async throws {
        env.browserLauncher.autoCallback = true
        // OAuth response has NO refresh token
        env.oauthClient.exchangeResult = .success(TokenExchangeResult(
            accessToken: "valid_access_token",
            refreshToken: nil, // Missing!
            expiresAt: Date().addingTimeInterval(3600),
            googleSub: "sub_new_user",
            emailFromIdToken: "new@example.com"
        ))

        let coordinator = OAuthFlowCoordinator(
            oauthClient: env.oauthClient,
            gmailClient: env.gmailClient,
            keychainStorage: env.keychainStorage,
            accountStorage: env.accountStorage,
            browserLauncher: env.browserLauncher,
            syncEngine: env.syncEngine
        )

        do {
            _ = try await coordinator.addAccountFlow()
            XCTFail("Missing refresh token must throw error")
        } catch OAuthError.missingRefreshToken {
            // Expected!
        }

        // Verify account was NOT published to directory
        let dir = try await env.accountStorage.loadDirectory()
        XCTAssertFalse(dir.accounts.contains(where: { $0.googleSub == "sub_new_user" }), "缺少 refresh token 的账号不得出现在账号列表中")
    }

    // MARK: - ID Token 严格校验（发行方、过期时间、Nonce、权限范围）
    func testIDTokenValidation_StrictChecks() {
        let client = GoogleOAuthClient(clientId: "test_client_id")

        // Helper to craft JWT payload
        func makeJWT(payload: [String: Any]) -> String {
            let header = ["alg": "none", "typ": "JWT"]
            let hData = try! JSONSerialization.data(withJSONObject: header)
            let pData = try! JSONSerialization.data(withJSONObject: payload)
            let hStr = hData.base64EncodedString()
            let pStr = pData.base64EncodedString()
            return "\(hStr).\(pStr).signature"
        }

        // 1. Invalid issuer
        let badIssJWT = makeJWT(payload: [
            "sub": "12345",
            "iss": "https://evil.com",
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "nonce": "valid_nonce"
        ])
        XCTAssertThrowsError(try client.parseAndValidateIDToken(badIssJWT, expectedNonce: "valid_nonce"))

        // 2. Expired token
        let expiredJWT = makeJWT(payload: [
            "sub": "12345",
            "iss": "https://accounts.google.com",
            "exp": Date().addingTimeInterval(-3600).timeIntervalSince1970,
            "nonce": "valid_nonce"
        ])
        XCTAssertThrowsError(try client.parseAndValidateIDToken(expiredJWT, expectedNonce: "valid_nonce"))

        // 3. Nonce mismatch
        let mismatchNonceJWT = makeJWT(payload: [
            "sub": "12345",
            "iss": "https://accounts.google.com",
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "nonce": "wrong_nonce"
        ])
        XCTAssertThrowsError(try client.parseAndValidateIDToken(mismatchNonceJWT, expectedNonce: "expected_nonce"))

        // 4. Valid token
        let validJWT = makeJWT(payload: [
            "sub": "12345",
            "iss": "https://accounts.google.com",
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "nonce": "expected_nonce",
            "email": "user@example.com"
        ])
        let result = try? client.parseAndValidateIDToken(validJWT, expectedNonce: "expected_nonce")
        XCTAssertEqual(result?.sub, "12345")
        XCTAssertEqual(result?.email, "user@example.com")
    }
}
