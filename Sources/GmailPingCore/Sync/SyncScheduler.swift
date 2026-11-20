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

    private var readingTask: Task<Void, Never>?
    private var readingAccount: UUID?
    private var readingSession: UUID?

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
        cancelReadingLocked()
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
            cancelReadingLocked()
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

    // Only the most recently opened inbox receives extra automatic checks.
    func followOpenedInbox(_ accountId: UUID, firstDelay: Duration = .seconds(5),
                           interval: Duration = .seconds(10), window: Duration = .seconds(60)) {
        lock.lock()
        defer { lock.unlock() }
        cancelReadingLocked()
        guard preferencesStorage.loadPreferences().checkInterval != .manual,
              isNetworkAvailable, !isSystemSleeping else { return }

        let session = UUID()
        let clock = ContinuousClock()
        let start = clock.now
        readingAccount = accountId
        readingSession = session
        readingTask = Task { [weak self] in
            defer { self?.finishReading(session) }
            var next = start + firstDelay
            let end = start + window
            while next < end {
                do { try await clock.sleep(until: next) } catch { return }
                guard let self, !Task.isCancelled, clock.now < end else { return }
                // Leave busy sync workers to the normal schedule and try the next tick.
                let result = await self.syncEngine.syncAccount(accountId: accountId, waitForCapacity: false)
                guard !Task.isCancelled else { return }
                self.onSyncCompleted?()
                if case .success(let snapshot) = result, snapshot.unreadCount == 0 { return }
                next = clock.now + interval
            }
        }
    }

    func cancelReading(for accountId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if readingAccount == accountId { cancelReadingLocked() }
    }

    private func isFollowing(_ accountId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readingAccount == accountId
    }

    private func finishReading(_ session: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if readingSession == session {
            readingSession = nil
            readingAccount = nil
            readingTask = nil
        }
    }

    private func cancelReadingLocked() {
        readingTask?.cancel()
        readingTask = nil
        readingAccount = nil
        readingSession = nil
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
                if !isManualTrigger && self.isFollowing(account.id) { continue }
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
            if !isOnline { self.cancelReadingLocked() }
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
            self.cancelReadingLocked()
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
