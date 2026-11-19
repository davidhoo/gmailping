import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case unhandledError(status: OSStatus)
    case dataConversionError
    case locked

    public var errorDescription: String? {
        switch self {
        case .unhandledError(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "钥匙串错误 (\(status)): \(msg)"
            }
            return "钥匙串错误: \(status)"
        case .dataConversionError:
            return "钥匙串数据解析错误"
        case .locked:
            return "钥匙串暂处于锁定状态"
        }
    }
}

public final class KeychainStorage: KeychainStorageProtocol, @unchecked Sendable {
    public let service: String

    public init(service: String = "com.gmailping.tokens") {
        self.service = service
    }

    public func saveToken(_ token: OAuthToken) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(token)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: token.accountId.uuidString
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: addStatus)
            }
        } else if status != errSecSuccess {
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw KeychainError.locked
            }
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func getToken(for accountId: UUID) throws -> OAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw KeychainError.locked
            }
            throw KeychainError.unhandledError(status: status)
        }

        guard let data = item as? Data else {
            throw KeychainError.dataConversionError
        }

        let decoder = JSONDecoder()
        return try decoder.decode(OAuthToken.self, from: data)
    }

    public func deleteToken(for accountId: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandledError(status: status)
        }
    }

    public func allStoredAccountIds() throws -> [UUID] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw KeychainError.locked
            }
            throw KeychainError.unhandledError(status: status)
        }

        guard let array = item as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict in
            guard let accountString = dict[kSecAttrAccount as String] as? String,
                  let uuid = UUID(uuidString: accountString) else {
                return nil
            }
            return uuid
        }
    }
}
