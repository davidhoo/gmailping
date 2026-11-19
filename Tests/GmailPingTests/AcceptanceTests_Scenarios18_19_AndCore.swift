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

        var prefs = env.preferencesStorage.loadPreferences()
        prefs.launchAtLogin = true
        await env.manager.updatePreferences(prefs)

        XCTAssertTrue(env.loginItemManager.isEnabled)

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
        // RFC 7636 Appendix B:
        // code_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        // code_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
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
}
