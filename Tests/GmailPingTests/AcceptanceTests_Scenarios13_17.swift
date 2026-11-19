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

    // MARK: - 场景 13: 区分未知与缓存、限流退避阻止自动及手动检查
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
        XCTAssertTrue(state.tooltip.contains("尚无数据") || state.tooltip.contains("等待同步"))

        // Rate limit 429 with Retry-After 120s on Account B
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setHistoryResponse(startHistoryId: "200", result: .failure(GmailAPIError.rateLimited(retryAfter: 120, isProjectLevel: false)))

        _ = await env.syncEngine.syncAccount(accountId: accountB.id)

        let nextRetry = await env.syncEngine.getNextRetryTime(accountId: accountB.id)
        XCTAssertNotNil(nextRetry)
        if let retry = nextRetry {
            let diff = retry.timeIntervalSinceNow
            XCTAssertGreaterThan(diff, 100)
            XCTAssertLessThanOrEqual(diff, 125)
        }

        // Verify scheduler respects Retry-After: automatic check does NOT fire
        let callCountBeforeAuto = await env.gmailClient.listHistoryCallCount
        await env.manager.scheduler.checkAll(isManualTrigger: false)
        let callCountAfterAuto = await env.gmailClient.listHistoryCallCount
        XCTAssertEqual(callCountBeforeAuto, callCountAfterAuto, "限流期间自动检查不得发送请求")

        // Verify manual check ALSO respects Retry-After: does NOT fire
        await env.manager.scheduler.checkSingleAccount(accountId: accountB.id)
        let callCountAfterManual = await env.gmailClient.listHistoryCallCount
        XCTAssertEqual(callCountBeforeAuto, callCountAfterManual, "手动检查也必须尊重服务端 Retry-After 限流等待时间")

        // Verify checkAllNow() (checkAll with isManualTrigger = true) ALSO respects Retry-After
        await env.manager.checkAllNow()
        let callCountAfterCheckAllNow = await env.gmailClient.listHistoryCallCount
        XCTAssertEqual(callCountBeforeAuto, callCountAfterCheckAllNow, "立即检查全部在 Retry-After 内同样不得发送请求")

        // Now test ordinary network failure backoff (NOT rate limit)
        let (accountC, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_C", email: "c@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountC.id, accessToken: "token_C", refreshToken: "refresh_C", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "c@example.com", historyId: "300")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 1)))
        _ = try await env.syncEngine.buildBaseline(account: accountC, accessToken: "token_C", isSystemLoginStartup: false)

        // Make C fail with ordinary network error
        await env.gmailClient.setHistoryResponse(startHistoryId: "300", result: .failure(GmailAPIError.networkError("WiFi reset")))
        _ = await env.syncEngine.syncAccount(accountId: accountC.id)

        // Automatic check skips C during backoff
        let countBeforeCAuto = await env.gmailClient.listHistoryCallCount
        await env.manager.scheduler.checkAll(isManualTrigger: false)
        let countAfterCAuto = await env.gmailClient.listHistoryCallCount
        XCTAssertEqual(countBeforeCAuto, countAfterCAuto, "普通退避期自动检查不发请求")

        // Manual checkAllNow() DOES fire for ordinary failure
        await env.gmailClient.setHistoryResponse(startHistoryId: "300", result: .success(GmailHistoryListResponse(history: [], historyId: "300")))
        await env.manager.checkAllNow()
        let countAfterCManual = await env.gmailClient.listHistoryCallCount
        XCTAssertGreaterThan(countAfterCManual, countBeforeCAuto, "立即检查全部在普通退避下会发送请求")
    }

    // MARK: - 账号需要重新授权时自动检查停止请求
    func testNeedsReauthStopsAutomaticCheck() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        var snap = AccountSnapshot(accountId: accountA.id)
        snap.historyId = "100"
        snap.unreadCount = 2
        snap.needsReauth = true
        snap.lastErrorReason = "授权失效"
        try await env.accountStorage.saveSnapshot(snap)

        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))

        let callCountBefore = await env.gmailClient.listHistoryCallCount
        await env.manager.scheduler.checkAll(isManualTrigger: false)
        let callCountAfter = await env.gmailClient.listHistoryCallCount
        XCTAssertEqual(callCountBefore, callCountAfter, "需要重新授权的账号应停止自动请求")
    }

    // MARK: - 刷新令牌遇网络错误不能误标为重新授权
    func testTokenRefreshNetworkFailure_DoesNotMarkNeedsReauth() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        // Token is expired
        let expiredToken = OAuthToken(
            accountId: accountA.id,
            accessToken: "expired_token",
            refreshToken: "valid_refresh",
            expiresAt: Date().addingTimeInterval(-100)
        )
        try env.keychainStorage.saveToken(expiredToken)

        var snap = AccountSnapshot(accountId: accountA.id)
        snap.historyId = "100"
        snap.unreadCount = 2
        try await env.accountStorage.saveSnapshot(snap)

        // Mock OAuth refresh throws network error
        env.oauthClient.refreshResult = .failure(OAuthError.networkError("WiFi 掉线"))

        let result = await env.syncEngine.syncAccount(accountId: accountA.id)
        XCTAssertFalse(result.isSuccess)

        let loadedSnap = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertFalse(loadedSnap?.needsReauth == true, "网络抖动或断网不得将账号错标为需要重新授权")
        XCTAssertTrue(loadedSnap?.isOffline == true)
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
        // Test detectIsSystemLoginLaunch on real AppleEvent descriptors:
        // 1. Positive case: event has keyAEPropData with 'lgit' (0x6c676974)
        let lgitEvent = NSAppleEventDescriptor.record()
        let lgitDesc = NSAppleEventDescriptor(enumCode: 0x6c676974)
        lgitEvent.setParam(lgitDesc, forKeyword: keyAEPropData)
        XCTAssertTrue(LoginItemManager.detectIsSystemLoginLaunch(event: lgitEvent), "Apple Event 含有 lgit 登录项标识时应识别为登录启动")

        // 2. Negative case: event has different keyword / enumCode
        let otherEvent = NSAppleEventDescriptor.record()
        let otherDesc = NSAppleEventDescriptor(enumCode: 0x6f746872 /* 'othr' */)
        otherEvent.setParam(otherDesc, forKeyword: keyAEPropData)
        XCTAssertFalse(LoginItemManager.detectIsSystemLoginLaunch(event: otherEvent), "非 lgit 的 Apple Event 严禁识别为登录启动")

        // 3. Nil event case
        XCTAssertFalse(LoginItemManager.detectIsSystemLoginLaunch(event: nil), "无 Apple Event 时应返回 false")

        let prefs = AppPreferences(notifyExistingUnreadOnSystemLogin: true)
        env.preferencesStorage.savePreferences(prefs)

        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 3)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // 1. Normal manual startup (using otherEvent): should NOT post login summary
        await env.gmailClient.setHistoryResponse(startHistoryId: "100", result: .success(GmailHistoryListResponse(history: [], historyId: "100")))
        let isManualStartup = LoginItemManager.detectIsSystemLoginLaunch(event: otherEvent)
        _ = await env.syncEngine.syncAccount(accountId: accountA.id, isSystemLoginStartup: isManualStartup)

        var summaries = await env.notificationService.deliveredSummaries
        XCTAssertEqual(summaries.count, 0, "普通手动启动不发送登录摘要")

        // 2. System login startup (using lgitEvent) with unread 3 and no new emails: delivers summary
        let isLoginStartup = LoginItemManager.detectIsSystemLoginLaunch(event: lgitEvent)
        XCTAssertTrue(isLoginStartup)
        _ = await env.syncEngine.syncAccount(accountId: accountA.id, isSystemLoginStartup: isLoginStartup)

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

        _ = await env.syncEngine.syncAccount(accountId: accountA.id, isSystemLoginStartup: isLoginStartup)

        let batches = await env.notificationService.deliveredBatches
        summaries = await env.notificationService.deliveredSummaries
        XCTAssertEqual(batches.count, 1, "同轮有新邮件时优先发新邮件通知")
        XCTAssertEqual(summaries.count, 0, "同轮有新邮件时不重复发已有未读摘要")
    }

    // MARK: - 场景 17: 中断恢复、投递中不明不重发、重启清理与新建实例 UUID
    func testScenario17_InterruptionRecoveryAndDeliveryIdempotence() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))

        // 1. Pending batch recovers and delivers on next sync
        let pendingBatch = NotificationBatch(
            id: "\(accountA.id.uuidString)-100-105",
            accountId: accountA.id,
            accountEmail: "a@example.com",
            count: 2,
            status: .pending
        )
        var snap = AccountSnapshot(
            accountId: accountA.id,
            historyId: "105",
            unreadCount: 4,
            lastSuccessTime: Date(),
            pendingBatches: [pendingBatch]
        )
        try await env.accountStorage.saveSnapshot(snap)

        await env.gmailClient.setHistoryResponse(startHistoryId: "105", result: .success(GmailHistoryListResponse(history: [], historyId: "105")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 4)))

        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        var batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.id, pendingBatch.id)

        // 2. Batch was stuck in .delivering, and NOT found in system delivered:
        // Must NOT re-deliver to prevent duplicate harassment!
        await env.notificationService.reset()
        let deliveringBatch = NotificationBatch(
            id: "\(accountA.id.uuidString)-105-110",
            accountId: accountA.id,
            accountEmail: "a@example.com",
            count: 1,
            status: .delivering
        )
        snap.pendingBatches = [deliveringBatch]
        try await env.accountStorage.saveSnapshot(snap)

        await env.gmailClient.setHistoryResponse(startHistoryId: "105", result: .success(GmailHistoryListResponse(history: [], historyId: "105")))
        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 0, "投递中状态且系统记录不明的批次，宁可少发也绝不重复打扰")

        // 3. Pending cleanup account finalized on restart, and re-adding gets NEW UUID
        try await env.accountStorage.markPendingCleanup(accountId: accountA.id)
        try await env.accountStorage.cleanupOrphans(keychain: env.keychainStorage, notificationService: env.notificationService)

        let dirAfterCleanup = try await env.accountStorage.loadDirectory()
        XCTAssertFalse(dirAfterCleanup.accounts.contains(where: { $0.id == accountA.id }), "重启应彻底清理待清理标记账号")

        // Re-adding same Google sub creates a NEW instance UUID
        let (reAddedAccount, isNew) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        XCTAssertTrue(isNew)
        XCTAssertNotEqual(reAddedAccount.id, accountA.id, "移除后再次添加必须是新实例 UUID，迟到回调无法写入")
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
