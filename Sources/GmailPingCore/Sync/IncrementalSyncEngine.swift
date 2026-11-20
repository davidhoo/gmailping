import Foundation

public actor IncrementalSyncEngine {
    private let accountStorage: AccountStorage
    private let keychainStorage: KeychainStorageProtocol
    private let gmailClient: GmailAPIClientProtocol
    private let oauthClient: GoogleOAuthClientProtocol
    private let notificationService: NotificationServiceProtocol
    private let preferencesStorage: PreferencesStorageProtocol

    // Per-account synchronization locks / in-flight tracking
    private var inFlightAccounts: Set<UUID> = []
    private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
    private var consecutiveFailures: [UUID: Int] = [:]
    private var nextRetryTimes: [UUID: Date] = [:]
    private var isRateLimited: [UUID: Bool] = [:]
    private var projectQuotaExhaustedUntil: Date?

    public init(
        accountStorage: AccountStorage,
        keychainStorage: KeychainStorageProtocol,
        gmailClient: GmailAPIClientProtocol,
        oauthClient: GoogleOAuthClientProtocol,
        notificationService: NotificationServiceProtocol,
        preferencesStorage: PreferencesStorageProtocol
    ) {
        self.accountStorage = accountStorage
        self.keychainStorage = keychainStorage
        self.gmailClient = gmailClient
        self.oauthClient = oauthClient
        self.notificationService = notificationService
        self.preferencesStorage = preferencesStorage
    }

    public func isInFlight(accountId: UUID) -> Bool {
        return inFlightAccounts.contains(accountId)
    }

    private func hasCapacity(for accountId: UUID) -> Bool {
        inFlightAccounts.count < 2 && !inFlightAccounts.contains(accountId)
    }

    public func getNextRetryTime(accountId: UUID) -> Date? {
        return nextRetryTimes[accountId]
    }

    public func isReadyForSync(accountId: UUID, isManualTrigger: Bool = false) async -> (ready: Bool, reason: String?) {
        if inFlightAccounts.contains(accountId) {
            return (false, "该账号正在同步中")
        }

        return await retryReadiness(accountId: accountId, isManualTrigger: isManualTrigger)
    }

    private func retryReadiness(accountId: UUID, isManualTrigger: Bool) async -> (ready: Bool, reason: String?) {
        if let projectUntil = projectQuotaExhaustedUntil, Date() < projectUntil {
            let remain = Int(projectUntil.timeIntervalSinceNow)
            return (false, "项目级配额已耗尽，需等待 \(remain) 秒")
        }

        let snap = try? await accountStorage.loadSnapshot(for: accountId)
        if snap?.needsReauth == true {
            return (false, "需要重新授权，已停止自动请求")
        }

        if let retryTime = nextRetryTimes[accountId], Date() < retryTime {
            let isRateLimit = isRateLimited[accountId] == true
            if isRateLimit {
                // Server rate limit: both automatic and manual checks must wait!
                let remain = max(1, Int(retryTime.timeIntervalSinceNow))
                return (false, "处于服务端限流等待期，需等待 \(remain) 秒")
            } else {
                // Ordinary network backoff
                if isManualTrigger {
                    // Manual trigger can retry ordinary failures
                    return (true, nil)
                } else {
                    let remain = max(1, Int(retryTime.timeIntervalSinceNow))
                    return (false, "处于退避重试期，需等待 \(remain) 秒")
                }
            }
        }

        return (true, nil)
    }

    public func clearBackoff(accountId: UUID, forceServerRateLimit: Bool = false) {
        consecutiveFailures[accountId] = 0
        if forceServerRateLimit || isRateLimited[accountId] != true {
            nextRetryTimes.removeValue(forKey: accountId)
            isRateLimited.removeValue(forKey: accountId)
        }
    }

    public func markReauthorized(accountId: UUID) async throws {
        var snapshot = (try? await accountStorage.loadSnapshot(for: accountId)) ?? AccountSnapshot(accountId: accountId)
        snapshot.needsReauth = false
        snapshot.lastErrorReason = nil
        try await accountStorage.saveSnapshot(snapshot)
        clearBackoff(accountId: accountId, forceServerRateLimit: true)
    }

    // MARK: - Main Sync Entry

    @discardableResult
    public func syncAccount(
        accountId: UUID,
        isSystemLoginStartup: Bool = false,
        isManualTrigger: Bool = false,
        waitForCapacity: Bool = true
    ) async -> Result<AccountSnapshot, Error> {
        // Reserve before awaiting storage so overlapping triggers cannot start the same account.
        while waitForCapacity && inFlightAccounts.count >= 2 && !inFlightAccounts.contains(accountId) {
            await withCheckedContinuation { capacityWaiters.append($0) }
        }
        guard !Task.isCancelled, hasCapacity(for: accountId) else {
            return .failure(CancellationError())
        }
        inFlightAccounts.insert(accountId)
        defer {
            inFlightAccounts.remove(accountId)
            let waiters = capacityWaiters
            capacityWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        let (ready, reason) = await retryReadiness(accountId: accountId, isManualTrigger: isManualTrigger)
        guard ready else {
            return .failure(NSError(domain: "GmailPing", code: -1, userInfo: [NSLocalizedDescriptionKey: reason ?? "账号暂未就绪"]))
        }

        do {
            let snapshot = try await performSync(accountId: accountId, isSystemLoginStartup: isSystemLoginStartup)
            consecutiveFailures[accountId] = 0
            nextRetryTimes.removeValue(forKey: accountId)
            isRateLimited.removeValue(forKey: accountId)
            return .success(snapshot)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                // Sleep / quit / task cancellation: do NOT mark offline, do NOT set backoff
                return .failure(error)
            }
            await handleSyncError(accountId: accountId, error: error)
            return .failure(error)
        }
    }

    private func performSync(
        accountId: UUID,
        isSystemLoginStartup: Bool
    ) async throws -> AccountSnapshot {
        // 1. Check account active status
        guard try await accountStorage.isAccountActive(accountId: accountId) else {
            throw NSError(domain: "GmailPing", code: -2, userInfo: [NSLocalizedDescriptionKey: "账号不存在或已被移除"])
        }

        let directory = try await accountStorage.loadDirectory()
        guard let account = directory.accounts.first(where: { $0.id == accountId }) else {
            throw NSError(domain: "GmailPing", code: -2, userInfo: [NSLocalizedDescriptionKey: "账号不存在"])
        }

        // 2. Retrieve & valid token
        let token = try keychainStorage.getToken(for: accountId)
        guard var validToken = token else {
            var snap = (try? await accountStorage.loadSnapshot(for: accountId)) ?? AccountSnapshot(accountId: accountId)
            snap.needsReauth = true
            snap.lastErrorReason = "未找到授权凭据"
            try await accountStorage.saveSnapshot(snap)
            throw OAuthError.invalidGrant
        }

        if validToken.isExpired {
            validToken = try await refreshAndSaveToken(for: validToken)
        }

        // 3. Load or initialize snapshot
        var snapshot = (try? await accountStorage.loadSnapshot(for: accountId)) ?? AccountSnapshot(accountId: accountId)

        // If in recovery, deliver any stuck batches
        if !snapshot.pendingBatches.isEmpty {
            snapshot = try await recoverPendingBatches(snapshot: snapshot, email: account.email)
        }

        // 4. Baseline check: if no historyId or cursor expired previously
        guard let startHistoryId = snapshot.historyId, !startHistoryId.isEmpty else {
            return try await buildBaseline(
                account: account,
                accessToken: validToken.accessToken,
                isSystemLoginStartup: isSystemLoginStartup
            )
        }

        // 5. Incremental History Check
        var currentToken = validToken.accessToken
        var pageToken: String? = nil
        var candidateMessageIds: [String] = []
        var finalHistoryId = startHistoryId

        do {
            repeat {
                let response: GmailHistoryListResponse
                do {
                    response = try await gmailClient.listHistory(
                        accessToken: currentToken,
                        startHistoryId: startHistoryId,
                        pageToken: pageToken
                    )
                } catch GmailAPIError.unauthorized {
                    validToken = try await refreshAndSaveToken(for: validToken)
                    currentToken = validToken.accessToken
                    response = try await gmailClient.listHistory(
                        accessToken: currentToken,
                        startHistoryId: startHistoryId,
                        pageToken: pageToken
                    )
                }

                finalHistoryId = response.historyId

                for item in response.history ?? [] {
                    for added in item.messagesAdded ?? [] {
                        candidateMessageIds.append(added.message.id)
                    }
                }

                pageToken = response.nextPageToken
            } while pageToken != nil && !pageToken!.isEmpty
        } catch GmailAPIError.historyIdExpired {
            // History cursor expired (404) -> silent baseline rebuild!
            return try await buildBaseline(
                account: account,
                accessToken: currentToken,
                isSystemLoginStartup: false
            )
        }

        // Dedup candidate IDs while preserving order
        var seenCandidates = Set<String>()
        var uniqueCandidates: [String] = []
        for id in candidateMessageIds {
            if !seenCandidates.contains(id) {
                seenCandidates.insert(id)
                uniqueCandidates.append(id)
            }
        }

        // 6. Filter candidate messages against current INBOX label and SPAM/TRASH
        let knownSet = Set(snapshot.knownMessageIds)
        var notifiableIds: [String] = []

        for msgId in uniqueCandidates {
            if knownSet.contains(msgId) {
                continue
            }

            let msg: GmailMessage?
            do {
                msg = try await gmailClient.getMessage(accessToken: currentToken, messageId: msgId)
            } catch GmailAPIError.unauthorized {
                validToken = try await refreshAndSaveToken(for: validToken)
                currentToken = validToken.accessToken
                msg = try await gmailClient.getMessage(accessToken: currentToken, messageId: msgId)
            }

            guard let msg = msg, let labelIds = msg.labelIds else {
                continue // deleted / not found
            }

            let inInbox = labelIds.contains("INBOX")
            let notSpamOrTrash = !labelIds.contains("SPAM") && !labelIds.contains("TRASH")
            if inInbox && notSpamOrTrash {
                notifiableIds.append(msgId)
            }
        }

        // 7. Get fresh INBOX unread count
        let inboxLabel: GmailLabel
        do {
            inboxLabel = try await gmailClient.getInboxLabel(accessToken: currentToken)
        } catch GmailAPIError.unauthorized {
            validToken = try await refreshAndSaveToken(for: validToken)
            currentToken = validToken.accessToken
            inboxLabel = try await gmailClient.getInboxLabel(accessToken: currentToken)
        }

        // 8. Re-check active status before atomic commit
        guard try await accountStorage.isAccountActive(accountId: accountId) else {
            throw NSError(domain: "GmailPing", code: -3, userInfo: [NSLocalizedDescriptionKey: "账号在同步过程中已被移除"])
        }

        // 9. Prepare atomic commit
        var updatedKnown = snapshot.knownMessageIds
        for id in uniqueCandidates {
            if !knownSet.contains(id) {
                updatedKnown.append(id)
            }
        }
        // Bound known message IDs to recent 500
        if updatedKnown.count > 500 {
            updatedKnown = Array(updatedKnown.suffix(500))
        }

        snapshot.historyId = finalHistoryId
        snapshot.unreadCount = inboxLabel.messagesUnread
        snapshot.lastSuccessTime = Date()
        snapshot.lastErrorReason = nil
        snapshot.needsReauth = false
        snapshot.isOffline = false
        snapshot.knownMessageIds = updatedKnown

        // Generate batch if notifiable messages exist
        var newBatch: NotificationBatch? = nil
        if !notifiableIds.isEmpty {
            let batchId = "\(accountId.uuidString)-\(startHistoryId)-\(finalHistoryId)"
            newBatch = NotificationBatch(
                id: batchId,
                accountId: accountId,
                accountEmail: account.email,
                count: notifiableIds.count,
                status: .pending
            )
            snapshot.pendingBatches.append(newBatch!)
        }

        // Atomic commit to disk
        try await accountStorage.saveSnapshot(snapshot)

        // 10. Deliver notifications
        let preferences = preferencesStorage.loadPreferences()
        if let batch = newBatch {
            snapshot = try await deliverSingleBatch(snapshot: snapshot, batchId: batch.id, preferences: preferences)
        } else if isSystemLoginStartup && preferences.notifyExistingUnreadOnSystemLogin && inboxLabel.messagesUnread > 0 {
            // System login summary if enabled and no new emails in this round
            if preferences.systemNotificationsEnabled {
                _ = await notificationService.deliverLoginSummary(
                    accountId: accountId,
                    email: account.email,
                    unreadCount: inboxLabel.messagesUnread,
                    playSound: preferences.notificationSoundEnabled
                )
            }
        }

        return snapshot
    }

    // MARK: - Baseline Construction

    public func buildBaseline(
        account: Account,
        accessToken: String,
        isSystemLoginStartup: Bool
    ) async throws -> AccountSnapshot {
        var token = accessToken

        // 1. users.getProfile to get current historyId
        let profile: GmailProfile
        do {
            profile = try await gmailClient.getProfile(accessToken: token)
        } catch GmailAPIError.unauthorized {
            if let saved = try keychainStorage.getToken(for: account.id) {
                let refreshed = try await refreshAndSaveToken(for: saved)
                token = refreshed.accessToken
                profile = try await gmailClient.getProfile(accessToken: token)
            } else {
                throw OAuthError.invalidGrant
            }
        }

        // 2. users.labels.get(INBOX) to get messagesUnread
        let label = try await gmailClient.getInboxLabel(accessToken: token)

        // Verify account is still active before saving
        guard try await accountStorage.isAccountActive(accountId: account.id) else {
            throw NSError(domain: "GmailPing", code: -3, userInfo: [NSLocalizedDescriptionKey: "账号已被移除"])
        }

        // 3. Atomic save snapshot (silent baseline: no notifications)
        var snapshot = (try? await accountStorage.loadSnapshot(for: account.id)) ?? AccountSnapshot(accountId: account.id)
        snapshot.historyId = profile.historyId
        snapshot.unreadCount = label.messagesUnread
        snapshot.lastSuccessTime = Date()
        snapshot.lastErrorReason = nil
        snapshot.needsReauth = false
        snapshot.isOffline = false
        snapshot.knownMessageIds = []
        snapshot.pendingBatches = []

        try await accountStorage.saveSnapshot(snapshot)
        return snapshot
    }

    // MARK: - Delivery & Recovery

    private func deliverSingleBatch(
        snapshot: AccountSnapshot,
        batchId: String,
        preferences: AppPreferences
    ) async throws -> AccountSnapshot {
        var snap = snapshot
        guard let idx = snap.pendingBatches.firstIndex(where: { $0.id == batchId }) else {
            return snap
        }

        // Mark delivering and save to disk first!
        snap.pendingBatches[idx].status = .delivering
        try await accountStorage.saveSnapshot(snap)

        let batch = snap.pendingBatches[idx]
        if preferences.systemNotificationsEnabled {
            _ = await notificationService.deliverBatch(batch, playSound: preferences.notificationSoundEnabled)
        }

        // Mark delivered / remove from pending and save
        snap.pendingBatches.remove(at: idx)
        try await accountStorage.saveSnapshot(snap)
        return snap
    }

    private func recoverPendingBatches(
        snapshot: AccountSnapshot,
        email: String
    ) async throws -> AccountSnapshot {
        var snap = snapshot
        _ = await notificationService.getPendingAndDeliveredNotificationIds(for: snap.accountId)
        let preferences = preferencesStorage.loadPreferences()

        for var batch in snap.pendingBatches {
            if batch.status == .pending {
                // Pending batch: mark delivering, save first, then attempt delivery
                batch.status = .delivering
                snap.pendingBatches = [batch]
                try? await accountStorage.saveSnapshot(snap)

                if preferences.systemNotificationsEnabled {
                    _ = await notificationService.deliverBatch(batch, playSound: preferences.notificationSoundEnabled)
                }
            } else if batch.status == .delivering {
                // If it was already marked delivering:
                // Check if system delivered notifications contains it.
                // If not found (result uncertain): end the batch to avoid double disruption!
                // (寧可漏發，絕不重復打擾)
            }
        }

        snap.pendingBatches = []
        try await accountStorage.saveSnapshot(snap)
        return snap
    }

    // MARK: - Token Refresh Helper

    private func refreshAndSaveToken(for token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.invalidGrant
        }
        do {
            let refreshed = try await oauthClient.refreshToken(refreshToken)
            let newToken = OAuthToken(
                accountId: token.accountId,
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.newRefreshToken ?? token.refreshToken,
                expiresAt: refreshed.expiresAt
            )
            try keychainStorage.saveToken(newToken)
            return newToken
        } catch let oauthErr as OAuthError {
            if oauthErr == .invalidGrant {
                throw OAuthError.invalidGrant
            }
            throw oauthErr
        } catch {
            throw error
        }
    }

    // MARK: - Error Handling & Backoff

    private func handleSyncError(accountId: UUID, error: Error) async {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            return
        }
        guard (try? await accountStorage.isAccountActive(accountId: accountId)) == true else {
            return
        }

        let failures = (consecutiveFailures[accountId] ?? 0) + 1
        consecutiveFailures[accountId] = failures

        var snap = (try? await accountStorage.loadSnapshot(for: accountId)) ?? AccountSnapshot(accountId: accountId)

        if let oauthErr = error as? OAuthError, oauthErr == .invalidGrant {
            snap.needsReauth = true
            snap.lastErrorReason = "授权失效，需要重新授权"
            nextRetryTimes[accountId] = .distantFuture // stop automatic polling
            isRateLimited[accountId] = false
        } else if let apiErr = error as? GmailAPIError, apiErr == .unauthorized {
            snap.needsReauth = true
            snap.lastErrorReason = "授权失效，需要重新授权"
            nextRetryTimes[accountId] = .distantFuture
            isRateLimited[accountId] = false
        } else if let apiErr = error as? GmailAPIError, case .policyBlocked(let reason) = apiErr {
            snap.needsReauth = true
            snap.lastErrorReason = reason
            nextRetryTimes[accountId] = .distantFuture
            isRateLimited[accountId] = false
        } else if let apiErr = error as? GmailAPIError, case .rateLimited(let retryAfter, let isProjectLevel) = apiErr {
            let delay = retryAfter ?? 60.0
            if isProjectLevel {
                projectQuotaExhaustedUntil = Date().addingTimeInterval(delay)
                snap.lastErrorReason = "项目级配额耗尽"
            } else {
                snap.lastErrorReason = "触发限流"
            }
            isRateLimited[accountId] = true
            nextRetryTimes[accountId] = Date().addingTimeInterval(delay)
        } else {
            // Temporary network/server error
            snap.isOffline = true
            snap.lastErrorReason = error.localizedDescription
            isRateLimited[accountId] = false
            // Exponential backoff with jitter: 30s to 15m
            let baseDelay = min(900.0, 30.0 * pow(2.0, Double(min(failures - 1, 5))))
            let jitter = Double.random(in: -0.1...0.1) * baseDelay
            let delay = max(30.0, baseDelay + jitter)
            nextRetryTimes[accountId] = Date().addingTimeInterval(delay)
        }

        try? await accountStorage.saveSnapshot(snap)
    }
}
