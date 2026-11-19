import XCTest
@testable import GmailPingCore

final class AcceptanceTests_Scenarios01_06: XCTestCase {
    var env: TestEnvironment!

    override func setUp() {
        super.setUp()
        env = TestEnvironment()
    }

    override func tearDown() {
        env.cleanup()
        super.tearDown()
    }

    // MARK: - 场景 01: 顺序添加双账号，静默基线，数字从 2 变为 7
    func testScenario01_AddTwoAccountsSequentially_SilentBaseline() async throws {
        // Step 1: Add Account A with 2 unread
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))

        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        var state = await env.manager.getDisplayState()
        XCTAssertEqual(state.totalUnread, 2)
        XCTAssertEqual(state.title, " 2")

        // Step 2: Add Account B with 5 unread
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "b@example.com", historyId: "200")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 5)))

        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "b@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        _ = try await env.syncEngine.buildBaseline(account: accountB, accessToken: "token_B", isSystemLoginStartup: false)

        state = await env.manager.getDisplayState()
        XCTAssertEqual(state.totalUnread, 7)
        XCTAssertEqual(state.title, " 7")

        // Verify each has distinct success time
        let snapA = try await env.accountStorage.loadSnapshot(for: accountA.id)
        let snapB = try await env.accountStorage.loadSnapshot(for: accountB.id)
        XCTAssertNotNil(snapA?.lastSuccessTime)
        XCTAssertNotNil(snapB?.lastSuccessTime)
        XCTAssertEqual(snapA?.historyId, "100")
        XCTAssertEqual(snapB?.historyId, "200")

        // Verify zero notifications for baseline
        let batches = await env.notificationService.deliveredBatches
        XCTAssertTrue(batches.isEmpty, "首次基线不应产生历史通知")
    }

    // MARK: - 场景 02: 重复添加、取消、重新授权时选错账号
    func testScenario02_DuplicateAdd_ReauthSubMismatch() async throws {
        env.browserLauncher.autoCallback = true
        env.oauthClient.exchangeResult = .success(TokenExchangeResult(
            accessToken: "token_A1",
            refreshToken: "refresh_A1",
            expiresAt: Date().addingTimeInterval(3600),
            googleSub: "sub_A",
            emailFromIdToken: "a@example.com"
        ))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))

        let coordinator = OAuthFlowCoordinator(
            oauthClient: env.oauthClient,
            gmailClient: env.gmailClient,
            keychainStorage: env.keychainStorage,
            accountStorage: env.accountStorage,
            browserLauncher: env.browserLauncher,
            syncEngine: env.syncEngine
        )

        // Add A
        let accountA = try await coordinator.addAccountFlow()
        XCTAssertEqual(accountA.email, "a@example.com")
        var storedIds = try env.keychainStorage.allStoredAccountIds()
        XCTAssertEqual(storedIds.count, 1)
        XCTAssertTrue(storedIds.contains(accountA.id))

        // Repeated add of same Google identity (sub_A) via addAccountFlow
        env.oauthClient.exchangeResult = .success(TokenExchangeResult(
            accessToken: "token_A2",
            refreshToken: "refresh_A2",
            expiresAt: Date().addingTimeInterval(3600),
            googleSub: "sub_A",
            emailFromIdToken: "a_new@example.com"
        ))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a_new@example.com", historyId: "100")))

        let accountA2 = try await coordinator.addAccountFlow()
        XCTAssertEqual(accountA.id, accountA2.id, "重复添加应复用并更新原账号实例")
        XCTAssertEqual(accountA2.email, "a_new@example.com")

        // Crucial check: Keychain must NOT create a new orphan UUID, must update accountA.id!
        storedIds = try env.keychainStorage.allStoredAccountIds()
        XCTAssertEqual(storedIds.count, 1, "钥匙串不应残留孤立 UUID，只应有 1 个")
        XCTAssertTrue(storedIds.contains(accountA.id))
        let updatedToken = try env.keychainStorage.getToken(for: accountA.id)
        XCTAssertEqual(updatedToken?.refreshToken, "refresh_A2", "原账号钥匙串凭据应被成功更新")

        let directory = try await env.accountStorage.loadDirectory()
        XCTAssertEqual(directory.accounts.count, 1)

        // Add B
        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "b@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 5)))
        _ = try await env.syncEngine.buildBaseline(account: accountB, accessToken: "token_B", isSystemLoginStartup: false)

        // Reauth A but user picks B's Google credentials (sub_B)
        // Verify real reauthAccountFlow throws subMismatch and B's state unaffected
        env.oauthClient.exchangeResult = .success(TokenExchangeResult(
            accessToken: "wrong_token",
            refreshToken: "wrong_refresh",
            expiresAt: Date().addingTimeInterval(3600),
            googleSub: "sub_B", // Mismatch with accountA.googleSub "sub_A"
            emailFromIdToken: "b@example.com"
        ))

        do {
            try await coordinator.reauthAccountFlow(account: accountA2)
            XCTFail("Should have thrown subMismatch")
        } catch let OAuthError.subMismatch(expected, actual, email) {
            XCTAssertEqual(expected, "sub_A")
            XCTAssertEqual(actual, "sub_B")
            XCTAssertEqual(email, "a_new@example.com")
        }

        // B's snapshot and count are preserved
        let snapB = try await env.accountStorage.loadSnapshot(for: accountB.id)
        XCTAssertEqual(snapB?.unreadCount, 5)
    }

    // MARK: - 场景 03: 默认账号切换与 URL 编码
    func testScenario03_BrowserRoutingAndURLEncoding() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "work+test@example.com")
        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "corp@custom-domain.org")

        // Initial default is A
        try await env.accountStorage.setDefaultAccount(accountId: accountA.id)
        await env.manager.openDefaultInbox()
        XCTAssertEqual(env.browserLauncher.openedEmails.last, "work+test@example.com")
        XCTAssertEqual(
            env.browserLauncher.openedURLs.last?.absoluteString,
            "https://mail.google.com/mail/?authuser=work%2Btest%40example.com#inbox"
        )

        // Switch default to B
        try await env.manager.setDefaultAccount(accountId: accountB.id)
        await env.manager.openDefaultInbox()
        XCTAssertEqual(env.browserLauncher.openedEmails.last, "corp@custom-domain.org")
        XCTAssertEqual(
            env.browserLauncher.openedURLs.last?.absoluteString,
            "https://mail.google.com/mail/?authuser=corp%40custom-domain.org#inbox"
        )

        // Open A directly from menu
        await env.manager.openInbox(for: accountA.id)
        XCTAssertEqual(env.browserLauncher.openedEmails.last, "work+test@example.com")
    }

    func testScenario03_PrimaryClickFollowsInboxUnreadCounts() async throws {
        var state = await env.manager.getDisplayState()
        XCTAssertEqual(state.primaryClickAction, .openPreferences)

        let (a, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "a", email: "a@example.com")
        let (b, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "b", email: "b@example.com")
        let (c, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "c", email: "c@example.com")
        // A is still waiting for its first sync. B is the only known unread inbox.
        try await env.accountStorage.saveSnapshot(AccountSnapshot(accountId: b.id, unreadCount: 103))
        try await env.accountStorage.saveSnapshot(AccountSnapshot(accountId: c.id, unreadCount: 0))
        state = await env.manager.getDisplayState()
        XCTAssertEqual(state.primaryClickAction, .openInbox(b.id))

        try await env.accountStorage.saveSnapshot(AccountSnapshot(accountId: c.id, unreadCount: 2))
        state = await env.manager.getDisplayState()
        guard case .chooseAccount(let rows) = state.primaryClickAction else {
            return XCTFail("多个收件箱有未读时应显示账号选择菜单")
        }
        XCTAssertEqual(rows.map { $0.account.id }, [b.id, c.id])
        XCTAssertEqual(rows.map { $0.unreadString }, ["103 封未读", "2 封未读"])

        for account in [b, c] {
            try await env.accountStorage.saveSnapshot(AccountSnapshot(accountId: account.id, unreadCount: 0))
        }
        state = await env.manager.getDisplayState()
        XCTAssertEqual(state.primaryClickAction, .openInbox(a.id))
    }

    // MARK: - 场景 04: 同轮检查 A 收到 3 封、B 收到 1 封，分别聚合通知
    func testScenario04_ConcurrentBatchArrival_IndependentNotifications() async throws {
        // Setup Account A (startHistoryId 100, unread 2)
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // Setup Account B (startHistoryId 200, unread 5)
        let (accountB, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_B", email: "b@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountB.id, accessToken: "token_B", refreshToken: "refresh_B", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "b@example.com", historyId: "200")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 5)))
        _ = try await env.syncEngine.buildBaseline(account: accountB, accessToken: "token_B", isSystemLoginStartup: false)

        // In next round: A receives msg1, msg2, msg3; B receives msg4
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .success(GmailHistoryListResponse(
                history: [
                    GmailHistoryItem(messagesAdded: [
                        GmailMessageAdded(message: GmailMessage(id: "msg1")),
                        GmailMessageAdded(message: GmailMessage(id: "msg2")),
                        GmailMessageAdded(message: GmailMessage(id: "msg3"))
                    ])
                ],
                historyId: "105"
            ))
        )
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "200",
            result: .success(GmailHistoryListResponse(
                history: [
                    GmailHistoryItem(messagesAdded: [
                        GmailMessageAdded(message: GmailMessage(id: "msg4"))
                    ])
                ],
                historyId: "203"
            ))
        )

        await env.gmailClient.setMessage(id: "msg1", labelIds: ["INBOX"])
        await env.gmailClient.setMessage(id: "msg2", labelIds: ["INBOX"])
        await env.gmailClient.setMessage(id: "msg3", labelIds: ["INBOX"])
        await env.gmailClient.setMessage(id: "msg4", labelIds: ["INBOX"])

        // Counts update: A becomes 5 (2+3), B becomes 6 (5+1), total = 11
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 5)))
        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 6)))
        _ = await env.syncEngine.syncAccount(accountId: accountB.id)

        // Check total display
        let state = await env.manager.getDisplayState()
        XCTAssertEqual(state.totalUnread, 11)
        XCTAssertEqual(state.title, " 11")

        // Check delivered notifications
        let batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 2)

        let batchA = batches.first(where: { $0.accountId == accountA.id })
        let batchB = batches.first(where: { $0.accountId == accountB.id })

        XCTAssertNotNil(batchA)
        XCTAssertEqual(batchA?.count, 3)
        XCTAssertEqual(batchA?.accountEmail, "a@example.com")

        XCTAssertNotNil(batchB)
        XCTAssertEqual(batchB?.count, 1)
        XCTAssertEqual(batchB?.accountEmail, "b@example.com")
    }

    // MARK: - 场景 05: 手机读掉 1 封，网页标旧邮件未读，均不触发新邮件通知
    func testScenario05_MobileReadAndOldEmailMarkedUnread_NoNotification() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 5)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // 1. Phone reads 1 email: history has no messageAdded, inboxLabel unread becomes 4 (-1)
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .success(GmailHistoryListResponse(history: [], historyId: "102"))
        )
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 4)))
        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        var snap = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertEqual(snap?.unreadCount, 4)
        var batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 0)

        // 2. Mark old email as unread on web: history has no messageAdded, inboxLabel unread becomes 5 (+1)
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "102",
            result: .success(GmailHistoryListResponse(history: [], historyId: "104"))
        )
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 5)))
        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        snap = try await env.accountStorage.loadSnapshot(for: accountA.id)
        XCTAssertEqual(snap?.unreadCount, 5)
        batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 0, "修改旧邮件状态不应产生新邮件通知")
    }

    // MARK: - 场景 06: 新邮件检查前已读（仍通知）；旧邮件移回收件箱（不通知）；非收件箱不通知
    func testScenario06_NewEmailReadBeforeCheck_MovedOldEmail_SpamTrashExcluded() async throws {
        let (accountA, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: "sub_A", email: "a@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: accountA.id, accessToken: "token_A", refreshToken: "refresh_A", expiresAt: Date().addingTimeInterval(3600)))
        await env.gmailClient.setProfileResult(.success(GmailProfile(emailAddress: "a@example.com", historyId: "100")))
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))
        _ = try await env.syncEngine.buildBaseline(account: accountA, accessToken: "token_A", isSystemLoginStartup: false)

        // 1. msg1 is a newly added message, already read on mobile before check (labels has INBOX, no UNREAD)
        // msg_spam is in SPAM
        // msg_trash is in TRASH
        // msg_archive is only in CATEGORY_PROMOTIONS (not in INBOX)
        await env.gmailClient.setHistoryResponse(
            startHistoryId: "100",
            result: .success(GmailHistoryListResponse(
                history: [
                    GmailHistoryItem(messagesAdded: [
                        GmailMessageAdded(message: GmailMessage(id: "msg1")),
                        GmailMessageAdded(message: GmailMessage(id: "msg_spam")),
                        GmailMessageAdded(message: GmailMessage(id: "msg_trash")),
                        GmailMessageAdded(message: GmailMessage(id: "msg_archive"))
                    ])
                ],
                historyId: "110"
            ))
        )

        await env.gmailClient.setMessage(id: "msg1", labelIds: ["INBOX"]) // Read on mobile, in INBOX
        await env.gmailClient.setMessage(id: "msg_spam", labelIds: ["SPAM"])
        await env.gmailClient.setMessage(id: "msg_trash", labelIds: ["TRASH", "INBOX"])
        await env.gmailClient.setMessage(id: "msg_archive", labelIds: ["CATEGORY_PROMOTIONS"])

        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))
        _ = await env.syncEngine.syncAccount(accountId: accountA.id)

        let batches = await env.notificationService.deliveredBatches
        XCTAssertEqual(batches.count, 1, "只应产生一条新邮件通知")
        XCTAssertEqual(batches.first?.count, 1, "只有 msg1 属于新到达收件箱邮件")
    }
}
