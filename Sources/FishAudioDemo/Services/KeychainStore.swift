import Foundation
import Security

enum KeychainError: Error {
    case unhandledStatus(OSStatus)
}

/// Minimal generic-password wrapper. One (service, account) pair = one secret.
struct KeychainStore {
    let service: String
    let account: String

    /// Values are trimmed: a pasted key with a trailing newline would corrupt the
    /// Authorization header and surface as an unexplained 401.
    func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary) // upsert
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
    }

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-empty stored value, or nil — the common case at call sites.
    var value: String? {
        guard let v = read(), !v.isEmpty else { return nil }
        return v
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }
}

extension KeychainStore {
    static let fishAPIKey = KeychainStore(service: "com.bornwest.fishaudiodemo", account: "fishAPIKey")
    static let brainAPIKey = KeychainStore(service: "com.bornwest.fishaudiodemo", account: "brainAPIKey")
}
