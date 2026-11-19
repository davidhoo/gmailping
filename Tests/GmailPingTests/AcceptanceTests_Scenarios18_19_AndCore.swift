import XCTest
import Security
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

    private func assertThrowsAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error not thrown: \(message())", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }

    // MARK: - 场景 18: 登录项控制与应用生命周期
    func testScenario18_LoginItemAndLifecycle() async throws {
        XCTAssertFalse(env.loginItemManager.isEnabled)
        XCTAssertEqual(env.loginItemManager.status, .notRegistered)

        // 1. First-time app start: automatically enables login item if default prefs has launchAtLogin = true
        let prefs = env.preferencesStorage.loadPreferences()
        XCTAssertFalse(prefs.hasInitializedLoginItem)
        XCTAssertTrue(prefs.launchAtLogin)

        await env.manager.start()
        XCTAssertTrue(env.loginItemManager.isEnabled)
        XCTAssertEqual(env.loginItemManager.status, .enabled)

        let loadedPrefs = env.preferencesStorage.loadPreferences()
        XCTAssertTrue(loadedPrefs.hasInitializedLoginItem)

        // 2. User disables login item in macOS System Settings:
        env.loginItemManager.setStatus(.notRegistered)
        XCTAssertFalse(env.loginItemManager.isEnabled)

        // 3. User modifies other preferences (e.g. check interval): MUST NOT re-register login item!
        var updatedPrefs = env.preferencesStorage.loadPreferences()
        updatedPrefs.checkInterval = .minutes5
        await env.manager.updatePreferences(updatedPrefs)
        XCTAssertFalse(env.loginItemManager.isEnabled, "修改刷新间隔等偏好设置不得重置或强制注册开机启动项")

        // 4. App restarts: start() MUST NOT re-register login item because hasInitializedLoginItem is true!
        await env.manager.start()
        XCTAssertFalse(env.loginItemManager.isEnabled, "应用重新启动不得覆盖用户在系统设置中关闭的开机启动项")

        // 5. Explicit user toggle in app settings:
        try await env.manager.setLaunchAtLogin(true)
        XCTAssertTrue(env.loginItemManager.isEnabled)
        XCTAssertEqual(env.loginItemManager.status, .enabled)

        try await env.manager.setLaunchAtLogin(false)
        XCTAssertFalse(env.loginItemManager.isEnabled)
        XCTAssertEqual(env.loginItemManager.status, .notRegistered)

        // Stop manager
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

        // Generate real RSA 2048 keypairs for testing
        let keyGenParams: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048
        ]
        var cfError: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(keyGenParams as CFDictionary, &cfError),
              let pubKey = SecKeyCopyPublicKey(privKey),
              let wrongPrivKey = SecKeyCreateRandomKey(keyGenParams as CFDictionary, &cfError),
              let wrongPubKey = SecKeyCopyPublicKey(wrongPrivKey) else {
            XCTFail("Failed to generate RSA test keys: \(String(describing: cfError))")
            return
        }

        func signJWT(header: [String: Any]? = nil, payload: [String: Any], key: SecKey) throws -> String {
            let h = header ?? ["alg": "RS256", "typ": "JWT", "kid": "key_1"]
            let hData = try JSONSerialization.data(withJSONObject: h)
            let pData = try JSONSerialization.data(withJSONObject: payload)
            let hStr = toBase64URL(hData)
            let pStr = toBase64URL(pData)
            let signedContent = "\(hStr).\(pStr)"
            guard let signedData = signedContent.data(using: .utf8) else {
                fatalError("Data encoding failed")
            }
            var signError: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                key,
                .rsaSignatureMessagePKCS1v15SHA256,
                signedData as CFData,
                &signError
            ) as Data? else {
                throw signError!.takeRetainedValue() as Error
            }
            return "\(signedContent).\(toBase64URL(signature))"
        }

        func makeUnsignedJWT(header: [String: Any]? = nil, payload: [String: Any], signature: String) -> String {
            let h = header ?? ["alg": "RS256", "typ": "JWT", "kid": "key_1"]
            let hData = try! JSONSerialization.data(withJSONObject: h)
            let pData = try! JSONSerialization.data(withJSONObject: payload)
            let hStr = toBase64URL(hData)
            let pStr = toBase64URL(pData)
            return "\(hStr).\(pStr).\(signature)"
        }

        client.publicKeyProvider = { _ in pubKey }

        let basePayload: [String: Any] = [
            "sub": "12345",
            "iss": "https://accounts.google.com",
            "aud": "test_client_id",
            "exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
            "nonce": "valid_nonce",
            "email": "user@example.com"
        ]

        // 1. Rejects 'none' algorithm
        let noneAlgJWT = makeUnsignedJWT(header: ["alg": "none", "typ": "JWT"], payload: basePayload, signature: "c2lnbmF0dXJl")
        await assertThrowsAsync(try await client.parseAndValidateIDToken(noneAlgJWT, expectedNonce: "valid_nonce")) { error in
            if case let OAuthError.invalidIDToken(reason) = error {
                XCTAssertTrue(reason.contains("none"), "Expected rejection of 'none' alg, got: \(reason)")
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // 2. Rejects missing or empty signature
        let emptySigJWT = makeUnsignedJWT(payload: basePayload, signature: "")
        await assertThrowsAsync(try await client.parseAndValidateIDToken(emptySigJWT, expectedNonce: "valid_nonce"))

        // 3. Rejects invalid fake signature string
        let fakeSigJWT = makeUnsignedJWT(payload: basePayload, signature: "c2lnbmF0dXJl")
        await assertThrowsAsync(try await client.parseAndValidateIDToken(fakeSigJWT, expectedNonce: "valid_nonce")) { error in
            if case let OAuthError.invalidIDToken(reason) = error {
                XCTAssertTrue(reason.contains("RS256 签名校验失败"), "Expected signature verification failure, got: \(reason)")
            }
        }

        // 4. Rejects signature signed with wrong private key
        let wrongSignedJWT = try signJWT(payload: basePayload, key: wrongPrivKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(wrongSignedJWT, expectedNonce: "valid_nonce")) { error in
            if case let OAuthError.invalidIDToken(reason) = error {
                XCTAssertTrue(reason.contains("RS256 签名校验失败"), "Expected signature verification failure with wrong key, got: \(reason)")
            }
        }

        let validSignedJWT = try signJWT(payload: basePayload, key: privKey)

        // 4b. Rejects valid signature when verified against wrong public key
        await assertThrowsAsync(try await client.parseAndValidateIDToken(validSignedJWT, expectedNonce: "valid_nonce", publicKey: wrongPubKey)) { error in
            if case let OAuthError.invalidIDToken(reason) = error {
                XCTAssertTrue(reason.contains("RS256 签名校验失败"), "Verifying with wrong public key must fail, got: \(reason)")
            }
        }

        // 5. Rejects tampered signature (flip bytes)
        let parts = validSignedJWT.components(separatedBy: ".")
        var sigChars = Array(parts[2])
        if !sigChars.isEmpty {
            sigChars[0] = (sigChars[0] == "A") ? "B" : "A"
        }
        let tamperedSigJWT = "\(parts[0]).\(parts[1]).\(String(sigChars))"
        await assertThrowsAsync(try await client.parseAndValidateIDToken(tamperedSigJWT, expectedNonce: "valid_nonce")) { error in
            if case let OAuthError.invalidIDToken(reason) = error {
                XCTAssertTrue(reason.contains("RS256 签名校验失败"), "Tampered signature must fail verification, got: \(reason)")
            }
        }

        // 6. Rejects missing audience (aud)
        var missingAudPayload = basePayload
        missingAudPayload.removeValue(forKey: "aud")
        let missingAudJWT = try signJWT(payload: missingAudPayload, key: privKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(missingAudJWT, expectedNonce: "valid_nonce"))

        // 7. Rejects audience mismatch
        var wrongAudPayload = basePayload
        wrongAudPayload["aud"] = "other_client_id"
        let wrongAudJWT = try signJWT(payload: wrongAudPayload, key: privKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(wrongAudJWT, expectedNonce: "valid_nonce"))

        // 8. Rejects missing expiration (exp)
        var missingExpPayload = basePayload
        missingExpPayload.removeValue(forKey: "exp")
        let missingExpJWT = try signJWT(payload: missingExpPayload, key: privKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(missingExpJWT, expectedNonce: "valid_nonce"))

        // 9. Rejects expired token
        var expiredPayload = basePayload
        expiredPayload["exp"] = Date().addingTimeInterval(-3600).timeIntervalSince1970
        let expiredJWT = try signJWT(payload: expiredPayload, key: privKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(expiredJWT, expectedNonce: "valid_nonce"))

        // 10. Rejects invalid issuer
        var badIssPayload = basePayload
        badIssPayload["iss"] = "https://evil.com"
        let badIssJWT = try signJWT(payload: badIssPayload, key: privKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(badIssJWT, expectedNonce: "valid_nonce"))

        // 11. Rejects missing issuer
        var missingIssPayload = basePayload
        missingIssPayload.removeValue(forKey: "iss")
        let missingIssJWT = try signJWT(payload: missingIssPayload, key: privKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(missingIssJWT, expectedNonce: "valid_nonce"))

        // 12. Rejects nonce mismatch
        var mismatchNoncePayload = basePayload
        mismatchNoncePayload["nonce"] = "wrong_nonce"
        let mismatchNonceJWT = try signJWT(payload: mismatchNoncePayload, key: privKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(mismatchNonceJWT, expectedNonce: "expected_nonce"))

        // 13. Rejects missing nonce
        var missingNoncePayload = basePayload
        missingNoncePayload.removeValue(forKey: "nonce")
        let missingNonceJWT = try signJWT(payload: missingNoncePayload, key: privKey)
        await assertThrowsAsync(try await client.parseAndValidateIDToken(missingNonceJWT, expectedNonce: "valid_nonce"))

        // 14. Real cryptographic valid token passes!
        let validResult = try await client.parseAndValidateIDToken(validSignedJWT, expectedNonce: "valid_nonce")
        XCTAssertEqual(validResult.sub, "12345")
        XCTAssertEqual(validResult.email, "user@example.com")

        // 15. Scope verification: exchangeCode must strictly require gmail.metadata
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOAuthURLProtocol.self]
        let customSession = URLSession(configuration: config)
        let testClient = GoogleOAuthClient(clientId: "test_client_id", session: customSession)
        testClient.publicKeyProvider = { _ in pubKey }

        // Mock 15a: Missing gmail.metadata in scope
        MockOAuthURLProtocol.responseHandler = { _ in
            let body: [String: Any] = [
                "access_token": "at_123",
                "refresh_token": "rt_123",
                "expires_in": 3600,
                "id_token": validSignedJWT,
                "scope": "openid https://mail.google.com/"
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        await assertThrowsAsync(try await testClient.exchangeCode(code: "c", codeVerifier: "v", redirectURI: "http://127.0.0.1:8080", expectedNonce: "valid_nonce")) { error in
            guard case OAuthError.insufficientScopes = error else {
                XCTFail("Expected insufficientScopes error, got: \(error)")
                return
            }
        }

        // Mock 15b: Scope contains gmail.metadata -> passes
        MockOAuthURLProtocol.responseHandler = { _ in
            let body: [String: Any] = [
                "access_token": "at_123",
                "refresh_token": "rt_123",
                "expires_in": 3600,
                "id_token": validSignedJWT,
                "scope": "openid https://www.googleapis.com/auth/gmail.metadata"
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            let resp = HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let exchangeRes = try await testClient.exchangeCode(code: "c", codeVerifier: "v", redirectURI: "http://127.0.0.1:8080", expectedNonce: "valid_nonce")
        XCTAssertEqual(exchangeRes.accessToken, "at_123")
    }

    // MARK: - 任务取消（如休眠/退出）测试：保留 Snapshot，不标记离线，不触发退避重试，支持立即同步
    func testCancellationDuringSync_PreservesSnapshotAndAllowsImmediateCheck() async throws {
        let (account, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_cancel_test", email: "cancel_test@example.com")
        
        let token = OAuthToken(
            accountId: account.id,
            accessToken: "valid_token",
            refreshToken: "valid_refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try env.keychainStorage.saveToken(token)

        // 1. Initial baseline sync
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "cancel_test@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))
        await env.syncEngine.syncAccount(accountId: account.id)

        let initialSnap = try await env.accountStorage.loadSnapshot(for: account.id)
        XCTAssertEqual(initialSnap?.unreadCount, 2)
        XCTAssertFalse(initialSnap?.isOffline ?? true)
        XCTAssertNil(initialSnap?.lastErrorReason)
        XCTAssertEqual(initialSnap?.historyId, "100")

        // 2. Set mock delay so next sync remains in-flight during listHistory
        await env.gmailClient.setHistoryDelay(nanoseconds: 500_000_000) // 0.5s

        // 3. Launch sync in a Task and cancel it shortly after start
        let syncTask = Task {
            await env.syncEngine.syncAccount(accountId: account.id)
        }
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        syncTask.cancel()
        _ = await syncTask.value

        // 4. Verify post-cancellation state: snapshot is intact, NOT marked offline, NO backoff
        let postCancelSnap = try await env.accountStorage.loadSnapshot(for: account.id)
        XCTAssertEqual(postCancelSnap?.unreadCount, 2, "被取消的任务应保留原有未读计数")
        XCTAssertFalse(postCancelSnap?.isOffline ?? true, "被取消的任务不得将账号置为离线状态")
        XCTAssertNil(postCancelSnap?.lastErrorReason, "被取消的任务不得产生错误原因")

        let retryTime = await env.syncEngine.getNextRetryTime(accountId: account.id)
        XCTAssertNil(retryTime, "被取消的任务不得计算退避等待时间")

        let (isReady, reason) = await env.syncEngine.isReadyForSync(accountId: account.id)
        XCTAssertTrue(isReady, "取消后账号必须处于立即可同步状态以支持唤醒检查，失败原因: \(reason ?? "")")

        // 5. Subsequent sync without delay succeeds immediately
        await env.gmailClient.setHistoryDelay(nanoseconds: 0)
        await env.gmailClient.setHistoryResponse(startHistoryId: "100", result: .success(GmailHistoryListResponse(history: [], nextPageToken: nil, historyId: "105")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 3)))
        await env.syncEngine.syncAccount(accountId: account.id)

        let finalSnap = try await env.accountStorage.loadSnapshot(for: account.id)
        XCTAssertEqual(finalSnap?.unreadCount, 3)
        XCTAssertEqual(finalSnap?.historyId, "105")
        XCTAssertFalse(finalSnap?.isOffline ?? true)
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
