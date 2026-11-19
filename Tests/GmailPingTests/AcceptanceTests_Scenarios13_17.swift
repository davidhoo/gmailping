import XCTest
@testable import GmailPingCore

final class AcceptanceTests_Scenarios13_17: XCTestCase {
    var env: TestEnvironment!

    override func setUp() {
        super.setUp()
        env = TestEnvironment()
    }

    override func tearDown() {
        env.cleanup()
        super.tearDown()
    }

    // MARK: - 场景 13: 区分未知与缓存、限流与离线退避
    func testScenario13_DistinguishUnknownAndCached_RateLimitAndBackoff() async throws {
        // Account A: never synced (no snapshot)
        _ = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")

        // Account B: has cached count 5
        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "b@example.com")
        var snapB = AccountSnapshot(accountId: accountB.id)
        snapB.historyId = "200"
        snapB.unreadCount = 5
        snapB.lastSuccessTime = Date()
        try await env.accountStorage.saveSnapshot(snapB)

        // Menu bar display state: total is 5, but tooltip indicates pending sync
        let state = await env.manager.getDisplayState()
        XCTAssertEqual(state.totalUnread, 5)
        XCTAssertTrue(state.hasPendingAccounts)
        XCTAssertTrue(state.tooltip.contains("有账号等待同步"))

        // Rate limit 429 with Retry-After 120s on Account B
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setHistoryResponse(startHistoryId: "200", result: .failure(GmailAPIError.rateLimited(retryAfter: 120)))

        _ = await env.syncEngine.syncAccount(accountId: accountB.id)

        let nextRetry = await env.syncEngine.getNextRetryTime(accountId: accountB.id)
        XCTAssertNotNil(nextRetry)
        if let retry = nextRetry {
            let diff = retry.timeIntervalSinceNow
            XCTAssertGreaterThan(diff, 100)
            XCTAssertLessThanOrEqual(diff, 125)
        }
    }

    // MARK: - 场景 14: 遍历检查周期与手动模式限制
    func testScenario14_CheckIntervalsAndManualMode() async throws {
        // Verify all intervals
        XCTAssertEqual(CheckInterval.seconds30.rawValue, 30)
        XCTAssertEqual(CheckInterval.seconds60.rawValue, 60)
        XCTAssertEqual(CheckInterval.minutes2.rawValue, 120)
        XCTAssertEqual(CheckInterval.minutes5.rawValue, 300)
        XCTAssertEqual(CheckInterval.manual.rawValue, 0)

        // Set to manual
        let prefs = AppPreferences(checkInterval: .manual)
        env.preferencesStorage.savePreferences(prefs)

        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 0)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // Start scheduler in manual mode
        env.manager.scheduler.start(isSystemLoginStartup: false)

        // Give any background task a tiny slice to verify no check triggered
        try await Task.sleep(nanoseconds: 50_000_000)

        let initialHistoryCount = await env.gmailClient.listHistoryCallCount
        XCTAssertEqual(initialHistoryCount, 0, "手动模式下启动不自动查询")

        // User explicit check: works!
        await env.manager.checkAllNow()
        let countAfterManual = await env.gmailClient.listHistoryCallCount
        XCTAssertGreaterThan(countAfterManual, initialHistoryCount, "用户主动检查在手动模式下应生效")
    }

    // MARK: - 场景 15: 关闭通知与声音，重新开启不补发
    func testScenario15_NotificationAndSoundToggles_NoBacklogSpam() async throws {
        var prefs = AppPreferences(
            systemNotificationsEnabled: false,
            notificationSoundEnabled: false
        )
        env.preferencesStorage.savePreferences(prefs)

        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 0)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // New email arrives while notifications are turned off
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .success(GmailHistoryListResponse(
                history: [GmailHistoryItem(messagesAdded: [GmailMessageAdded(message: GmailMessage(id: "msg1"))])],
                historyId: "105"
            ))
        )
        await env.gmailClient.setMessage(id: "msg1", labelIds: ["INBOX"])
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 1)))

        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        // Unread count updated to 1
        let snap = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertEqual(snap?.unreadCount, 1)

        // Zero delivered notifications
        let batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 0)

        // Re-enable notifications
        prefs.systemNotificationsEnabled = true
        env.preferencesStorage.savePreferences(prefs)

        // Subsequent check: no new message in history -> no retroactive spam!
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "105",
            result: .success(GmailHistoryListResponse(history: [], historyId: "105"))
        )
        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        let batchesAfter = await env.notificationService.deliveredBatches
        XCTAssertEqual(batchesAfter.count, 0, "重新开启通知不应补发关闭期间已同步的邮件")
    }

    // MARK: - 场景 16: 系统登录启动摘要与普通启动区分
    func testScenario16_SystemLoginStartupSummary() async throws {
        let prefs = AppPreferences(notifyExistingUnreadOnSystemLogin: true)
        env.preferencesStorage.savePreferences(prefs)

        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 3)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // 1. Normal manual startup: should NOT post login summary
        await env.gmailClient.setHistoryResponse(startHistoryId: "100", result: .success(GmailHistoryListResponse(history: [], historyId: "100")))
        _ = await env.syncEngine.syncAccount(accountId: accountA.id, isSystemLoginStartup: false)

        var summaries = await env.notificationService.deliveredSummaries
        XCTAssertEqual(summaries.count, 0, "普通手动启动不发送登录摘要")

        // 2. System login startup with unread 3 and no new emails: delivers summary
        _ = await env.syncEngine.syncAccount(accountId: accountA.id, isSystemLoginStartup: true)

        summaries = await env.notificationService.deliveredSummaries
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.count, 3)
        XCTAssertEqual(summaries.first?.email, "a@example.com")

        // 3. System login startup with new emails in same round: prioritizes new email notification
        await env.notificationService.reset()
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .success(GmailHistoryListResponse(
                history: [GmailHistoryItem(messagesAdded: [GmailMessageAdded(message: GmailMessage(id: "new_msg"))])],
                historyId: "105"
            ))
        )
        await env.gmailClient.setMessage(id: "new_msg", labelIds: ["INBOX"])
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 4)))

        _ = await env.syncEngine.syncAccount(accountId: accountA.id, isSystemLoginStartup: true)

        let batches = await env.notificationService.deliveredBatches
        summaries = await env.notificationService.deliveredSummaries
        XCTAssertEqual(batches.count, 1, "同轮有新邮件时优先发新邮件通知")
        XCTAssertEqual(summaries.count, 0, "同轮有新邮件时不重复发已有未读摘要")
    }

    // MARK: - 场景 17: 中断恢复与投递幂等
    func testScenario17_InterruptionRecoveryAndDeliveryIdempotence() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))

        // Simulate committed snapshot with a pending batch
        let pendingBatch = NotificationBatch(
            id: "\(accountA.id.uuidString)-100-105",
            accountId: accountA.id,
            accountEmail: "a@example.com",
            count: 2,
            status: .pending
        )
        let snap = AccountSnapshot(
            accountId: accountA.id,
            historyId: "105",
            unreadCount: 4,
            lastSuccessTime: Date(),
            pendingBatches: [pendingBatch]
        )
        try await env.accountStorage.saveSnapshot(snap)

        // Next sync runs recovery on startup
        await env.gmailClient.setHistoryResponse(startHistoryId: "105", result: .success(GmailHistoryListResponse(history: [], historyId: "105")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 4)))

        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        let batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.id, pendingBatch.id)

        // Pending batch cleared from snapshot
        let recoveredSnap = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertTrue(recoveredSnap?.pendingBatches.isEmpty == true)
    }
}
