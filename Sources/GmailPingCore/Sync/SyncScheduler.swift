import Foundation
import Network
import AppKit

public final class SyncScheduler: @unchecked Sendable {
    private let syncEngine: IncrementalSyncEngine
    private let accountStorage: AccountStorage
    private let preferencesStorage: PreferencesStorageProtocol
    private let pathMonitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.gmailping.networkmonitor")

    private let lock = NSLock()
    private var timerTask: Task<Void, Never>?
    private var isNetworkAvailable: Bool = true
    private var isSystemSleeping: Bool = false
    private var pendingDebounceTask: Task<Void, Never>?
    private var activeSyncTask: Task<Void, Never>?

    public var onSyncCompleted: (@Sendable () -> Void)?

    public init(
        syncEngine: IncrementalSyncEngine,
        accountStorage: AccountStorage,
        preferencesStorage: PreferencesStorageProtocol
    ) {
        self.syncEngine = syncEngine
        self.accountStorage = accountStorage
        self.preferencesStorage = preferencesStorage
        self.pathMonitor = NWPathMonitor()

        setupNetworkMonitor()
        setupSleepWakeObservers()
    }

    deinit {
        stop()
    }

    public func start(isSystemLoginStartup: Bool = false) {
        rescheduleTimer()
        Task {
            let prefs = preferencesStorage.loadPreferences()
            if prefs.checkInterval != .manual {
                await checkAll(isSystemLoginStartup: isSystemLoginStartup, isManualTrigger: false)
            }
        }
    }

    public func stop() {
        lock.lock()
        timerTask?.cancel()
        timerTask = nil
        pendingDebounceTask?.cancel()
        pendingDebounceTask = nil
        activeSyncTask?.cancel()
        activeSyncTask = nil
        lock.unlock()
    }

    public func rescheduleTimer() {
        lock.lock()
        timerTask?.cancel()
        timerTask = nil

        let prefs = preferencesStorage.loadPreferences()
        let intervalSeconds = prefs.checkInterval.rawValue

        guard intervalSeconds > 0 else {
            lock.unlock()
            return
        }

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                guard !Task.isCancelled, let self = self else { break }

                let (sleeping, online) = self.getSystemState()
                if !sleeping && online {
                    await self.checkAll(isManualTrigger: false)
                }
            }
        }
        lock.unlock()
    }

    // MARK: - Check Triggers

    public func checkAll(isSystemLoginStartup: Bool = false, isManualTrigger: Bool = false) async {
        let (sleeping, online) = getSystemState()
        guard !sleeping && online else { return }

        let syncTask = Task { [weak self] in
            guard let self = self else { return }
            let directory = (try? await self.accountStorage.loadDirectory()) ?? AccountDirectory()
            let activeAccounts = directory.accounts.filter { !$0.isPendingCleanup }

            // Filter accounts by readiness
            var accountsToSync: [Account] = []
            for account in activeAccounts {
                if Task.isCancelled { break }
                let (ready, _) = await self.syncEngine.isReadyForSync(
                    accountId: account.id,
                    isManualTrigger: isManualTrigger
                )
                if ready {
                    accountsToSync.append(account)
                }
            }

            guard !accountsToSync.isEmpty, !Task.isCancelled else {
                return
            }

            // Global concurrency = 2, staggered polling
            await withTaskGroup(of: Void.self) { group in
                var activeWorkers = 0

                for (index, account) in accountsToSync.enumerated() {
                    if Task.isCancelled { break }

                    if activeWorkers >= 2 {
                        _ = await group.next()
                        activeWorkers -= 1
                    }

                    // Stagger requests slightly (100ms) between starting different accounts
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }

                    if Task.isCancelled { break }

                    activeWorkers += 1
                    group.addTask {
                        _ = await self.syncEngine.syncAccount(
                            accountId: account.id,
                            isSystemLoginStartup: isSystemLoginStartup,
                            isManualTrigger: isManualTrigger
                        )
                    }
                }
            }
        }

        setActiveSyncTask(syncTask)
        await syncTask.value
        clearActiveSyncTask(ifEquals: syncTask)

        onSyncCompleted?()
    }

    public func checkSingleAccount(accountId: UUID) async {
        let singleTask = Task { [weak self] in
            guard let self = self else { return }
            let (ready, _) = await self.syncEngine.isReadyForSync(accountId: accountId, isManualTrigger: true)
            if ready && !Task.isCancelled {
                _ = await self.syncEngine.syncAccount(accountId: accountId, isManualTrigger: true)
            }
        }

        setActiveSyncTask(singleTask)
        await singleTask.value
        clearActiveSyncTask(ifEquals: singleTask)

        onSyncCompleted?()
    }

    private func setActiveSyncTask(_ task: Task<Void, Never>?) {
        lock.lock()
        activeSyncTask = task
        lock.unlock()
    }

    private func clearActiveSyncTask(ifEquals task: Task<Void, Never>) {
        lock.lock()
        if activeSyncTask == task {
            activeSyncTask = nil
        }
        lock.unlock()
    }

    // MARK: - Network & Sleep Handlers

    private func setupNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let isOnline = path.status == .satisfied
            let wasOnline: Bool

            self.lock.lock()
            wasOnline = self.isNetworkAvailable
            self.isNetworkAvailable = isOnline
            self.lock.unlock()

            if !wasOnline && isOnline {
                self.handleSystemWakeOrNetworkRestored()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func setupSleepWakeObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            self.isSystemSleeping = true
            // Cancel active in-flight sync task on sleep
            self.activeSyncTask?.cancel()
            self.activeSyncTask = nil
            self.lock.unlock()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lock.lock()
            self?.isSystemSleeping = false
            self?.lock.unlock()
            self?.handleSystemWakeOrNetworkRestored()
        }
    }

    private func handleSystemWakeOrNetworkRestored() {
        let prefs = preferencesStorage.loadPreferences()
        // Manual mode strictly ignores wake and network restore events!
        guard prefs.checkInterval != .manual else { return }

        lock.lock()
        pendingDebounceTask?.cancel()
        pendingDebounceTask = Task { [weak self] in
            // Debounce for 1 second to merge wake and network events
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self = self else { return }
            await self.checkAll(isManualTrigger: false)
        }
        lock.unlock()
    }

    private func getSystemState() -> (sleeping: Bool, online: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (isSystemSleeping, isNetworkAvailable)
    }
}
