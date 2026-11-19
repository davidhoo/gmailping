import Foundation

public protocol PreferencesStorageProtocol: Sendable {
    func loadPreferences() -> AppPreferences
    func savePreferences(_ preferences: AppPreferences)
}

public final class UserDefaultsPreferencesStorage: PreferencesStorageProtocol, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "com.gmailping.preferences"
    private let lock = NSLock()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func loadPreferences() -> AppPreferences {
        lock.lock()
        defer { lock.unlock() }
        guard let data = userDefaults.data(forKey: key) else {
            return AppPreferences()
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(AppPreferences.self, from: data)) ?? AppPreferences()
    }

    public func savePreferences(_ preferences: AppPreferences) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(preferences) {
            userDefaults.set(data, forKey: key)
        }
    }
}

public final class MockPreferencesStorage: PreferencesStorageProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: AppPreferences

    public init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
    }

    public func loadPreferences() -> AppPreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferences
    }

    public func savePreferences(_ preferences: AppPreferences) {
        lock.lock()
        defer { lock.unlock() }
        self.preferences = preferences
    }
}
