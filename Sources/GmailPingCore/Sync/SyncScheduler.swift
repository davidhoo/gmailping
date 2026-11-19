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
                await checkAll(isSystemLoginStartup: isSystemLoginStartup)
            }
        }
    }

    public func stop() {
        lock.lock()
        timerTask?.cancel()
        timerTask = nil
        pendingDebounceTask?.cancel()
        pendingDebounceTask = nil
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
                    await self.checkAll()
                }
            }
        }
        lock.unlock()
    }

    // MARK: - Check Triggers

    public func checkAll(isSystemLoginStartup: Bool = false) async {
        let directory = (try? await accountStorage.loadDirectory()) ?? AccountDirectory()
        let activeAccounts = directory.accounts.filter { !$0.isPendingCleanup }

        // Max global concurrency = 2
        await withTaskGroup(of: Void.self) { group in
            var activeWorkers = 0

            for account in activeAccounts {
                if activeWorkers >= 2 {
                    _ = await group.next()
                    activeWorkers -= 1
                }

                activeWorkers += 1
                group.addTask {
                    _ = await self.syncEngine.syncAccount(
                        accountId: account.id,
                        isSystemLoginStartup: isSystemLoginStartup
                    )
                }
            }
        }

        onSyncCompleted?()
    }

    public func checkSingleAccount(accountId: UUID) async {
        await syncEngine.clearBackoff(accountId: accountId)
        _ = await syncEngine.syncAccount(accountId: accountId)
        onSyncCompleted?()
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
            self?.lock.lock()
            self?.isSystemSleeping = true
            self?.lock.unlock()
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
        // Manual mode ignores wake and network restore events!
        guard prefs.checkInterval != .manual else { return }

        lock.lock()
        pendingDebounceTask?.cancel()
        pendingDebounceTask = Task { [weak self] in
            // Debounce for 1 second to merge wake and network events
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self = self else { return }
            await self.checkAll()
        }
        lock.unlock()
    }

    private func getSystemState() -> (sleeping: Bool, online: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (isSystemSleeping, isNetworkAvailable)
    }
}
