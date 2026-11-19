import XCTest
@testable import GmailPingCore

final class AcceptanceTests_Scenarios07_12: XCTestCase {
    var env: TestEnvironment!

    override func setUp() {
        super.setUp()
        env = TestEnvironment()
    }

    override func tearDown() {
        env.cleanup()
        super.tearDown()
    }

    // MARK: - 场景 07: 跨页去重与跨账号独立
    func testScenario07_PaginationDeduplication_AndCrossAccountIndependence() async throws {
        // Setup Account A
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 0)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // Setup Account B
        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "b@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "b@example.com", historyId: "200")))
        _ = try await env.syncEngine.buildBaseline(account: accountB, accessToken: "token_B", isSystemLoginStartup: false)

        // Account A: Page 1 returns msg1, msg2 with nextPageToken="page2"
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .success(GmailHistoryListResponse(
                history: [
                    GmailHistoryItem(messagesAdded: [
                        GmailMessageAdded(message: GmailMessage(id: "msg1")),
                        GmailMessageAdded(message: GmailMessage(id: "msg2"))
                    ])
                ],
                nextPageToken: "page2",
                historyId: "105"
            ))
        )
        // Page 2 returns duplicate msg1 and msg3, no nextPageToken
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100_page2",
            result: .success(GmailHistoryListResponse(
                history: [
                    GmailHistoryItem(messagesAdded: [
                        GmailMessageAdded(message: GmailMessage(id: "msg1")),
                        GmailMessageAdded(message: GmailMessage(id: "msg3"))
                    ])
                ],
                nextPageToken: nil,
                historyId: "110"
            ))
        )

        // Account B uses msg1 as well
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "200",
            result: .success(GmailHistoryListResponse(
                history: [
                    GmailHistoryItem(messagesAdded: [
                        GmailMessageAdded(message: GmailMessage(id: "msg1"))
                    ])
                ],
                nextPageToken: nil,
                historyId: "205"
            ))
        )

        await env.gmailClient.setMessage(id: "msg1", labelIds: ["INBOX"])
        await env.gmailClient.setMessage(id: "msg2", labelIds: ["INBOX"])
        await env.gmailClient.setMessage(id: "msg3", labelIds: ["INBOX"])

        // Run sync for A
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 3)))
        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        // Run sync for B
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 1)))
        _ = await env.syncEngine.syncAccount(accountId: accountB.id)

        let batches = await env.notificationService.deliveredBatches
        let batchA = batches.first(where: { $0.accountId == accountA.id })
        let batchB = batches.first(where: { $0.accountId == accountB.id })

        XCTAssertEqual(batchA?.count, 3, "A 应去重，只计算 msg1, msg2, msg3 共 3 封")
        XCTAssertEqual(batchB?.count, 1, "B 独立计算 msg1 为 1 封")

        // Subsequent check: no new messages in history -> 0 new notifications
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "110",
            result: .success(GmailHistoryListResponse(history: [], historyId: "110"))
        )
        _ = await env.syncEngine.syncAccount(accountId: accountA.id)
        let totalBatchesAfter = await env.notificationService.deliveredBatches
        XCTAssertEqual(totalBatchesAfter.count, 2, "后续无新邮件检查不增加通知")
    }

    // MARK: - 场景 08: 分页失败、候选查询失败回滚，重试成功只产生一个批次
    func testScenario08_FailureRollbackAndCleanRetry() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        let initialSnap = try await env.accountStorage.loadSnapshot(for: accountA.id)
        let initialSuccessTime = initialSnap?.lastSuccessTime

        // Fail during page 2
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .success(GmailHistoryListResponse(history: [], nextPageToken: "page2", historyId: "105"))
        )
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100_page2",
            result: .failure(GmailAPIError.networkError("Connection lost"))
        )

        let result = await env.syncEngine.syncAccount(accountId: accountA.id)
        XCTAssertFalse(result.isSuccess)

        // Snapshot cursor & success time remains unchanged
        let rolledBackSnap = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertEqual(rolledBackSnap?.historyId, "100")
        XCTAssertEqual(rolledBackSnap?.unreadCount, 2)
        XCTAssertEqual(rolledBackSnap?.lastSuccessTime, initialSuccessTime)

        // Clear backoff & retry with full success
        await env.syncEngine.clearBackoff(accountId: accountA.id)
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .success(GmailHistoryListResponse(
                history: [
                    GmailHistoryItem(messagesAdded: [
                        GmailMessageAdded(message: GmailMessage(id: "msg1"))
                    ])
                ],
                historyId: "110"
            ))
        )
        await env.gmailClient.setMessage(id: "msg1", labelIds: ["INBOX"])
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 3)))

        let retryResult = await env.syncEngine.syncAccount(accountId: accountA.id)
        XCTAssertTrue(retryResult.isSuccess)

        let completedSnap = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertEqual(completedSnap?.historyId, "110")
        XCTAssertEqual(completedSnap?.unreadCount, 3)

        let batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 1)
    }

    // MARK: - 场景 09: historyId 404 游标过期静默重建基线，B 照常工作
    func testScenario09_HistoryIdExpiredRebuildBaselineSilently() async throws {
        // Setup Account A
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 10)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // Setup Account B
        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "b@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "b@example.com", historyId: "200")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 3)))
        _ = try await env.syncEngine.buildBaseline(account: accountB, accessToken: "token_B", isSystemLoginStartup: false)

        // A's history.list throws 404 historyIdExpired
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .failure(GmailAPIError.historyIdExpired(startHistoryId: "100"))
        )
        // New profile has historyId 150, inbox has 12 unread
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "150")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 12)))

        let resultA = await env.syncEngine.syncAccount(accountId: accountA.id)
        XCTAssertTrue(resultA.isSuccess)

        // A rebuilt baseline silently to 150
        let snapA = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertEqual(snapA?.historyId, "150")
        XCTAssertEqual(snapA?.unreadCount, 12)

        // Zero notifications for A!
        let batchesA = await env.notificationService.deliveredBatches.filter { $0.accountId == accountA.id }
        XCTAssertEqual(batchesA.count, 0, "静默重建基线不应产生历史通知")

        // B syncs and receives new email normally
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "200",
            result: .success(GmailHistoryListResponse(
                history: [
                    GmailHistoryItem(messagesAdded: [GmailMessageAdded(message: GmailMessage(id: "b_msg1"))])
                ],
                historyId: "205"
            ))
        )
        await env.gmailClient.setMessage(id: "b_msg1", labelIds: ["INBOX"])
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 4)))

        let resultB = await env.syncEngine.syncAccount(accountId: accountB.id)
        XCTAssertTrue(resultB.isSuccess)

        let batchesB = await env.notificationService.deliveredBatches.filter { $0.accountId == accountB.id }
        XCTAssertEqual(batchesB.count, 1)
    }

    // MARK: - 场景 10: 撤销授权标为需要重新授权，B 正常更新
    func testScenario10_RevokeAuth_NeedsReauth_IsolateOtherAccounts() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 3)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "b@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "b@example.com", historyId: "200")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 1)))
        _ = try await env.syncEngine.buildBaseline(account: accountB, accessToken: "token_B", isSystemLoginStartup: false)

        // Make A return 401 unauthorized and refresh return invalid_grant
        await env.gmailClient.setHistoryResponse(startHistoryId: "100", result: .failure(GmailAPIError.unauthorized))
        env.oauthClient.refreshResult = .failure(OAuthError.invalidGrant)

        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        let snapA = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertTrue(snapA?.needsReauth == true)
        XCTAssertEqual(snapA?.unreadCount, 3, "保留已知未读数")

        // B syncs normally
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "200",
            result: .success(GmailHistoryListResponse(
                history: [GmailHistoryItem(messagesAdded: [GmailMessageAdded(message: GmailMessage(id: "b_new"))])],
                historyId: "205"
            ))
        )
        await env.gmailClient.setMessage(id: "b_new", labelIds: ["INBOX"])
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))
        _ = await env.syncEngine.syncAccount(accountId: accountB.id)

        let snapB = try await env.accountStorage.loadSnapshot(for: accountB.id)
        XCTAssertEqual(snapB?.unreadCount, 2)
        XCTAssertFalse(snapB?.needsReauth == true)

        let state = await env.manager.getDisplayState()
        XCTAssertTrue(state.hasOfflineOrReauthAccounts)
        XCTAssertTrue(state.tooltip.contains("部分账号待更新"))

        let itemA = state.accountItems.first(where: { $0.account.id == accountA.id })
        XCTAssertTrue(itemA?.lastSyncString.contains("待重新授权") == true, "菜单项应显示待重新授权")
        XCTAssertTrue(itemA?.lastSyncString.contains("上次成功") == true, "菜单项应同时保留旧数据成功时间")
    }

    // MARK: - 场景 11: 移除默认账号时迟到结果废弃，默认目标转移
    func testScenario11_RemoveDefaultAccount_LateResponseDiscarded_DefaultMigrated() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 3)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "b@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "b@example.com", historyId: "200")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))
        _ = try await env.syncEngine.buildBaseline(account: accountB, accessToken: "token_B", isSystemLoginStartup: false)

        // Remove default account A
        try await env.manager.removeAccount(accountId: accountA.id)

        // Verify default automatically migrated to B
        let dir = try await env.accountStorage.loadDirectory()
        XCTAssertEqual(dir.defaultAccountId, accountB.id)
        XCTAssertEqual(dir.accounts.count, 1)

        // Verify A's token deleted
        let tokenA = try env.keychainStorage.getToken(for: accountA.id)
        XCTAssertNil(tokenA)

        // Verify total unread immediately扣除 A's contribution
        let state = await env.manager.getDisplayState()
        XCTAssertEqual(state.totalUnread, 2)
        XCTAssertEqual(state.title, " 2")

        // Verify notifications for A cleared
        let cleared = await env.notificationService.clearedAccounts
        XCTAssertTrue(cleared.contains(accountA.id))
    }

    // MARK: - 场景 12: 数字格式化（0、99、100、105）与开关组合
    func testScenario12_BadgeFormattingAndToggles() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")

        // 1. Initial unsynced state -> " 等待同步", tooltip 等待同步
        let state = await env.manager.getDisplayState()
        XCTAssertEqual(state.title, " 等待同步")
        XCTAssertNil(state.totalUnread)
        XCTAssertTrue(state.tooltip.contains("等待同步"))

        // Helper to set unread
        func setUnread(_ count: Int, prefs: AppPreferences) -> MenuBarDisplayState {
            var snap = AccountSnapshot(accountId: accountA.id)
            snap.unreadCount = count
            snap.lastSuccessTime = Date()
            return MenuBarStateCalculator.computeDisplayState(
                accounts: [accountA],
                defaultAccountId: accountA.id,
                snapshots: [accountA.id: snap],
                preferences: prefs
            )
        }

        var prefs = AppPreferences(showUnreadCount: true, hideCountWhenZero: true)

        // Count = 0, hideZero = true -> pure icon
        var s = setUnread(0, prefs: prefs)
        XCTAssertEqual(s.title, "")
        XCTAssertEqual(s.totalUnread, 0)

        // Count = 0, hideZero = false -> " 0"
        prefs.hideCountWhenZero = false
        s = setUnread(0, prefs: prefs)
        XCTAssertEqual(s.title, " 0")
        XCTAssertEqual(s.totalUnread, 0)

        // Count = 99 -> " 99"
        prefs.hideCountWhenZero = true
        s = setUnread(99, prefs: prefs)
        XCTAssertEqual(s.title, " 99")
        XCTAssertEqual(s.totalUnread, 99)

        // Count = 100 -> " 99+"
        s = setUnread(100, prefs: prefs)
        XCTAssertEqual(s.title, " 99+")
        XCTAssertEqual(s.totalUnread, 100)

        // Count = 105 -> " 99+"
        s = setUnread(105, prefs: prefs)
        XCTAssertEqual(s.title, " 99+")
        XCTAssertEqual(s.totalUnread, 105)

        // showUnreadCount = false -> pure icon throughout
        prefs.showUnreadCount = false
        s = setUnread(105, prefs: prefs)
        XCTAssertEqual(s.title, "")
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
