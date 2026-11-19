import Foundation

public actor AccountStorage {
    public let baseDirectory: URL
    private let accountsFileURL: URL
    private let snapshotsDirectoryURL: URL
    private let fileManager = FileManager.default

    public init(baseDirectory: URL? = nil) {
        let base: URL
        if let baseDirectory = baseDirectory {
            base = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            base = appSupport.appendingPathComponent("GmailPing", isDirectory: true)
        }
        self.baseDirectory = base
        self.accountsFileURL = base.appendingPathComponent("accounts.json")
        self.snapshotsDirectoryURL = base.appendingPathComponent("snapshots", isDirectory: true)
    }

    public func prepareDirectories() throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: snapshotsDirectoryURL, withIntermediateDirectories: true)
    }

    // MARK: - Accounts Directory Operations

    public func loadDirectory() throws -> AccountDirectory {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: accountsFileURL.path) else {
            return AccountDirectory()
        }
        let data = try Data(contentsOf: accountsFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountDirectory.self, from: data)
    }

    public func saveDirectory(_ directory: AccountDirectory) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(directory)

        let tempURL = baseDirectory.appendingPathComponent("accounts.json.tmp.\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try fileManager.replaceItemAt(accountsFileURL, withItemAt: tempURL)
    }

    public func addOrUpdateAccount(
        googleSub: String,
        email: String
    ) throws -> (Account, Bool) { // returns (account, isNew)
        var directory = try loadDirectory()

        if let index = directory.accounts.firstIndex(where: { $0.googleSub == googleSub }) {
            // Existing sub: update email, order stays, mark not pending cleanup
            var account = directory.accounts[index]
            account.email = email
            account.isPendingCleanup = false
            directory.accounts[index] = account
            try saveDirectory(directory)
            return (account, false)
        } else {
            let nextOrder = (directory.accounts.map(\.order).max() ?? -1) + 1
            let account = Account(
                id: UUID(),
                googleSub: googleSub,
                email: email,
                addedAt: Date(),
                order: nextOrder,
                isPendingCleanup: false
            )
            directory.accounts.append(account)
            if directory.defaultAccountId == nil {
                directory.defaultAccountId = account.id
            }
            try saveDirectory(directory)
            return (account, true)
        }
    }

    public func markPendingCleanup(accountId: UUID) throws {
        var directory = try loadDirectory()
        if let idx = directory.accounts.firstIndex(where: { $0.id == accountId }) {
            directory.accounts[idx].isPendingCleanup = true
            try saveDirectory(directory)
        }
    }

    public func removeAccount(accountId: UUID) throws {
        var directory = try loadDirectory()
        directory.accounts.removeAll { $0.id == accountId }

        if directory.defaultAccountId == accountId {
            // Pick first remaining account by order
            let remaining = directory.accounts
                .filter { !$0.isPendingCleanup }
                .sorted(by: { $0.order < $1.order })
            directory.defaultAccountId = remaining.first?.id
        }

        try saveDirectory(directory)
        try deleteSnapshot(for: accountId)
    }

    public func setDefaultAccount(accountId: UUID) throws {
        var directory = try loadDirectory()
        guard directory.accounts.contains(where: { $0.id == accountId && !$0.isPendingCleanup }) else {
            return
        }
        directory.defaultAccountId = accountId
        try saveDirectory(directory)
    }

    // MARK: - Snapshot Operations

    private func snapshotURL(for accountId: UUID) -> URL {
        return snapshotsDirectoryURL.appendingPathComponent("\(accountId.uuidString).json")
    }

    public func loadSnapshot(for accountId: UUID) throws -> AccountSnapshot? {
        try prepareDirectories()
        let url = snapshotURL(for: accountId)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: AccountSnapshot) throws {
        try prepareDirectories()
        let url = snapshotURL(for: snapshot.accountId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let tempURL = snapshotsDirectoryURL.appendingPathComponent("\(snapshot.accountId.uuidString).tmp.\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
    }

    public func deleteSnapshot(for accountId: UUID) throws {
        let url = snapshotURL(for: accountId)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Orphan Cleanup

    public func cleanupOrphans(keychain: KeychainStorageProtocol) throws {
        let directory = try loadDirectory()
        let validIds = Set(directory.accounts.map(\.id))

        // Clean orphaned snapshots
        try prepareDirectories()
        let fileURLs = try fileManager.contentsOfDirectory(
            at: snapshotsDirectoryURL,
            includingPropertiesForKeys: nil
        )
        for url in fileURLs where url.pathExtension == "json" {
            let filename = url.deletingPathExtension().lastPathComponent
            if let uuid = UUID(uuidString: filename), !validIds.contains(uuid) {
                try? fileManager.removeItem(at: url)
            }
        }

        // Clean orphaned Keychain entries
        if let storedIds = try? keychain.allStoredAccountIds() {
            for id in storedIds where !validIds.contains(id) {
                try? keychain.deleteToken(for: id)
            }
        }
    }
}
