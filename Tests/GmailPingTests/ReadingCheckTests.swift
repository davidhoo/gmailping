import XCTest
@testable import GmailPingCore

final class ReadingCheckTests: XCTestCase {
    private let env = TestEnvironment()

    override func tearDown() {
        env.manager.stop()
        env.cleanup()
        super.tearDown()
    }

    private func addAccount(_ name: String) async throws -> Account {
        let (account, _) = try await env.accountStorage.addOrUpdateAccount(googleSub: name, email: "\(name)@example.com")
        try env.keychainStorage.saveToken(OAuthToken(accountId: account.id, accessToken: name,
                                                     refreshToken: name, expiresAt: Date().addingTimeInterval(3600)))
        return account
    }

    func testOpeningInboxDelaysFirstCheckAndOnlyRefreshesSelectedAccount() async throws {
        let first = try await addAccount("first")
        let selected = try await addAccount("selected")
        let checked = expectation(description: "Selected account refreshed")
        env.manager.scheduler.onSyncCompleted = { checked.fulfill() }
        await env.manager.openInbox(for: selected.id)
        XCTAssertEqual(env.browserLauncher.openedEmails, [selected.email])
        try await Task.sleep(for: .milliseconds(150))
        let before = await env.gmailClient.getInboxLabelCallCount
        XCTAssertEqual(before, 0)
        await fulfillment(of: [checked], timeout: 8)
        let otherSnapshot = try await env.accountStorage.loadSnapshot(for: first.id)
        let selectedSnapshot = try await env.accountStorage.loadSnapshot(for: selected.id)
        XCTAssertNil(otherSnapshot?.lastSuccessTime)
        XCTAssertEqual(selectedSnapshot?.unreadCount, 0)
    }

    func testReadingStopsAfterZero() async throws {
        let account = try await addAccount("reading")
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 2)))
        let checked = expectation(description: "First refresh")
        env.manager.scheduler.onSyncCompleted = { checked.fulfill() }
        env.manager.scheduler.followOpenedInbox(account.id, firstDelay: .milliseconds(30),
                                               interval: .milliseconds(200), window: .seconds(2))
        await fulfillment(of: [checked], timeout: 1)
        let second = expectation(description: "Read all")
        env.manager.scheduler.onSyncCompleted = { second.fulfill() }
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 0)))
        await fulfillment(of: [second], timeout: 1)
        try await Task.sleep(for: .milliseconds(450))
        let calls = await env.gmailClient.getInboxLabelCallCount
        XCTAssertEqual(calls, 2)
    }

    func testSwitchingAccountsReplacesWindowAndPositiveCountExpires() async throws {
        let first = try await addAccount("first")
        let second = try await addAccount("second")
        await env.gmailClient.setInboxLabelResult(.success(GmailLabel(id: "INBOX", name: "INBOX", messagesUnread: 8)))
        let scheduler = env.manager.scheduler
        scheduler.followOpenedInbox(first.id, firstDelay: .milliseconds(100))
        scheduler.followOpenedInbox(second.id, firstDelay: .milliseconds(20),
                                   interval: .milliseconds(120), window: .milliseconds(210))
        try await Task.sleep(for: .milliseconds(500))
        let calls = await env.gmailClient.getInboxLabelCallCount
        let previous = try await env.accountStorage.loadSnapshot(for: first.id)
        XCTAssertNil(previous?.lastSuccessTime)
        XCTAssertEqual(calls, 2)
    }

    func testManualModeCancelsExistingWindowAndPreventsNewOne() async throws {
        let account = try await addAccount("manual")
        let scheduler = env.manager.scheduler
        scheduler.followOpenedInbox(account.id, firstDelay: .milliseconds(100))
        await env.manager.updatePreferences(AppPreferences(checkInterval: .manual))
        scheduler.followOpenedInbox(account.id, firstDelay: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(250))
        let calls = await env.gmailClient.getInboxLabelCallCount
        XCTAssertEqual(calls, 0)
    }
}
