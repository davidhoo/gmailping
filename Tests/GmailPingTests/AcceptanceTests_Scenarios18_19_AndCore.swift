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

    // MARK: - ID Token 严格校验（算法、签名、发行方、受众、过期时间、Nonce、权限范围）
    func testIDTokenValidation_StrictChecks() async throws {
        let client = GoogleOAuthClient(clientId: "test_client_id")

        // Helper to craft base64url string
        func toBase64URL(_ data: Data) -> String {
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }

        func makeJWT(header: [String: Any]? = nil, payload: [String: Any], signature: String = "c2lnbmF0dXJlX2J5dGVzX3ZhbGlk") -> String {
            let h = header ?? ["alg": "RS256", "typ": "JWT"]
            let hData = try! JSONSerialization.data(withJSONObject: h)
            let pData = try! JSONSerialization.data(withJSONObject: payload)
            let hStr = toBase64URL(hData)
            let pStr = toBase64URL(pData)
            return "\(hStr).\(pStr).\(signature)"
        }

        let basePayload: [String: Any] = [
            "sub": "12345",
            "iss": "https://accounts.google.com",
            "aud": "test_client_id",
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "nonce": "valid_nonce",
            "email": "user@example.com"
        ]

        // 1. Rejects 'none' algorithm
        let noneAlgJWT = makeJWT(header: ["alg": "none", "typ": "JWT"], payload: basePayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(noneAlgJWT, expectedNonce: "valid_nonce"))

        // 2. Rejects missing or empty signature
        let emptySigJWT = makeJWT(payload: basePayload, signature: "")
        XCTAssertThrowsError(try client.parseAndValidateIDToken(emptySigJWT, expectedNonce: "valid_nonce"))

        // 3. Rejects missing audience (aud)
        var missingAudPayload = basePayload
        missingAudPayload.removeValue(forKey: "aud")
        let missingAudJWT = makeJWT(payload: missingAudPayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(missingAudJWT, expectedNonce: "valid_nonce"))

        // 4. Rejects audience mismatch
        var wrongAudPayload = basePayload
        wrongAudPayload["aud"] = "other_client_id"
        let wrongAudJWT = makeJWT(payload: wrongAudPayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(wrongAudJWT, expectedNonce: "valid_nonce"))

        // 5. Rejects missing expiration (exp)
        var missingExpPayload = basePayload
        missingExpPayload.removeValue(forKey: "exp")
        let missingExpJWT = makeJWT(payload: missingExpPayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(missingExpJWT, expectedNonce: "valid_nonce"))

        // 6. Rejects expired token
        var expiredPayload = basePayload
        expiredPayload["exp"] = Date().addingTimeInterval(-3600).timeIntervalSince1970
        let expiredJWT = makeJWT(payload: expiredPayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(expiredJWT, expectedNonce: "valid_nonce"))

        // 7. Rejects invalid issuer
        var badIssPayload = basePayload
        badIssPayload["iss"] = "https://evil.com"
        let badIssJWT = makeJWT(payload: badIssPayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(badIssJWT, expectedNonce: "valid_nonce"))

        // 8. Rejects missing issuer
        var missingIssPayload = basePayload
        missingIssPayload.removeValue(forKey: "iss")
        let missingIssJWT = makeJWT(payload: missingIssPayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(missingIssJWT, expectedNonce: "valid_nonce"))

        // 9. Rejects nonce mismatch
        var mismatchNoncePayload = basePayload
        mismatchNoncePayload["nonce"] = "wrong_nonce"
        let mismatchNonceJWT = makeJWT(payload: mismatchNoncePayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(mismatchNonceJWT, expectedNonce: "expected_nonce"))

        // 10. Rejects missing nonce
        var missingNoncePayload = basePayload
        missingNoncePayload.removeValue(forKey: "nonce")
        let missingNonceJWT = makeJWT(payload: missingNoncePayload)
        XCTAssertThrowsError(try client.parseAndValidateIDToken(missingNonceJWT, expectedNonce: "valid_nonce"))

        // 11. Valid token passes with all required claims and RS256 signature
        let validJWT = makeJWT(payload: basePayload)
        let result = try client.parseAndValidateIDToken(validJWT, expectedNonce: "valid_nonce")
        XCTAssertEqual(result.sub, "12345")
        XCTAssertEqual(result.email, "user@example.com")

        // 12. Scope verification: exchangeCode must strictly require gmail.metadata
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOAuthURLProtocol.self]
        let customSession = URLSession(configuration: config)
        let testClient = GoogleOAuthClient(clientId: "test_client_id", session: customSession)

        // Mock 12a: Missing gmail.metadata in scope
        MockOAuthURLProtocol.responseHandler = { _ in
            let body: [String: Any] = [
                "access_token": "at_123",
                "refresh_token": "rt_123",
                "expires_in": 3600,
                "id_token": validJWT,
                "scope": "openid https://mail.google.com/"
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        do {
            _ = try await testClient.exchangeCode(code: "c", codeVerifier: "v", redirectURI: "http://127.0.0.1:8080", expectedNonce: "valid_nonce")
            XCTFail("Should reject tokens without gmail.metadata scope")
        } catch OAuthError.insufficientScopes {
            // Expected!
        }

        // Mock 12b: Scope contains gmail.metadata -> passes
        MockOAuthURLProtocol.responseHandler = { _ in
            let body: [String: Any] = [
                "access_token": "at_123",
                "refresh_token": "rt_123",
                "expires_in": 3600,
                "id_token": validJWT,
                "scope": "openid https://www.googleapis.com/auth/gmail.metadata"
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let exchangeRes = try await testClient.exchangeCode(code: "c", codeVerifier: "v", redirectURI: "http://127.0.0.1:8080", expectedNonce: "valid_nonce")
        XCTAssertEqual(exchangeRes.accessToken, "at_123")
    }
}

final class MockOAuthURLProtocol: URLProtocol {
    static var responseHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.responseHandler else { return }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
