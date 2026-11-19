import Foundation

public final class GmailPingManager: @unchecked Sendable {
    public let accountStorage: AccountStorage
    public let keychainStorage: KeychainStorageProtocol
    public let preferencesStorage: PreferencesStorageProtocol
    public let oauthClient: GoogleOAuthClientProtocol
    public let gmailClient: GmailAPIClientProtocol
    public let notificationService: NotificationServiceProtocol
    public let browserLauncher: BrowserLauncherProtocol
    public let loginItemManager: LoginItemManagerProtocol
    public let syncEngine: IncrementalSyncEngine
    public let scheduler: SyncScheduler

    private let lock = NSLock()
    public var onStateChanged: (@Sendable (MenuBarDisplayState) -> Void)?

    public init(
        accountStorage: AccountStorage,
        keychainStorage: KeychainStorageProtocol,
        preferencesStorage: PreferencesStorageProtocol,
        oauthClient: GoogleOAuthClientProtocol,
        gmailClient: GmailAPIClientProtocol,
        notificationService: NotificationServiceProtocol,
        browserLauncher: BrowserLauncherProtocol,
        loginItemManager: LoginItemManagerProtocol,
        syncEngine: IncrementalSyncEngine? = nil
    ) {
        self.accountStorage = accountStorage
        self.keychainStorage = keychainStorage
        self.preferencesStorage = preferencesStorage
        self.oauthClient = oauthClient
        self.gmailClient = gmailClient
        self.notificationService = notificationService
        self.browserLauncher = browserLauncher
        self.loginItemManager = loginItemManager

        let engine = syncEngine ?? IncrementalSyncEngine(
            accountStorage: accountStorage,
            keychainStorage: keychainStorage,
            gmailClient: gmailClient,
            oauthClient: oauthClient,
            notificationService: notificationService,
            preferencesStorage: preferencesStorage
        )
        self.syncEngine = engine

        let sched = SyncScheduler(
            syncEngine: engine,
            accountStorage: accountStorage,
            preferencesStorage: preferencesStorage
        )
        self.scheduler = sched

        sched.onSyncCompleted = { [weak self] in
            Task {
                await self?.notifyStateChanged()
            }
        }
    }

    public func start(isSystemLoginStartup: Bool = false) async {
        let prefs = preferencesStorage.loadPreferences()
        try? loginItemManager.syncWithPreferences(launchAtLogin: prefs.launchAtLogin)
        try? await accountStorage.cleanupOrphans(keychain: keychainStorage, notificationService: notificationService)
        scheduler.start(isSystemLoginStartup: isSystemLoginStartup)
        await notifyStateChanged()
    }

    public func stop() {
        scheduler.stop()
    }

    public func getDisplayState() async -> MenuBarDisplayState {
        let directory = (try? await accountStorage.loadDirectory()) ?? AccountDirectory()
        let activeAccounts = directory.accounts.filter { !$0.isPendingCleanup }

        var snapshots: [UUID: AccountSnapshot] = [:]
        for acc in activeAccounts {
            if let snap = try? await accountStorage.loadSnapshot(for: acc.id) {
                snapshots[acc.id] = snap
            }
        }

        let prefs = preferencesStorage.loadPreferences()
        return MenuBarStateCalculator.computeDisplayState(
            accounts: activeAccounts,
            defaultAccountId: directory.defaultAccountId,
            snapshots: snapshots,
            preferences: prefs
        )
    }

    public func notifyStateChanged() async {
        let state = await getDisplayState()
        onStateChanged?(state)
    }

    // MARK: - Actions

    public func openDefaultInbox() async {
        let directory = (try? await accountStorage.loadDirectory()) ?? AccountDirectory()
        let activeAccounts = directory.accounts.filter { !$0.isPendingCleanup }

        guard !activeAccounts.isEmpty else {
            // Zero accounts: open add account / preferences
            return
        }

        let defaultAcc = activeAccounts.first(where: { $0.id == directory.defaultAccountId }) ?? activeAccounts.first!
        _ = browserLauncher.openInbox(for: defaultAcc.email)
    }

    public func openInbox(for accountId: UUID) async {
        let directory = (try? await accountStorage.loadDirectory()) ?? AccountDirectory()
        if let acc = directory.accounts.first(where: { $0.id == accountId }) {
            _ = browserLauncher.openInbox(for: acc.email)
        }
    }

    public func setDefaultAccount(accountId: UUID) async throws {
        try await accountStorage.setDefaultAccount(accountId: accountId)
        var prefs = preferencesStorage.loadPreferences()
        prefs.defaultAccountId = accountId
        preferencesStorage.savePreferences(prefs)
        await notifyStateChanged()
    }

    public func removeAccount(accountId: UUID) async throws {
        // 1. Mark pending cleanup so it stops scheduling/summary immediately
        try await accountStorage.markPendingCleanup(accountId: accountId)
        await notifyStateChanged()

        // 2. Clear credentials and local storage
        try? keychainStorage.deleteToken(for: accountId)
        await notificationService.clearNotifications(for: accountId)

        // 3. Finalize removal
        try await accountStorage.removeAccount(accountId: accountId)
        await notifyStateChanged()
    }

    public func checkAllNow() async {
        await scheduler.checkAll(isManualTrigger: true)
        await notifyStateChanged()
    }

    public func checkAccountNow(accountId: UUID) async {
        await scheduler.checkSingleAccount(accountId: accountId)
        await notifyStateChanged()
    }

    public func updatePreferences(_ prefs: AppPreferences) async {
        preferencesStorage.savePreferences(prefs)
        try? loginItemManager.setEnabled(prefs.launchAtLogin)
        scheduler.rescheduleTimer()
        await notifyStateChanged()
    }
}
