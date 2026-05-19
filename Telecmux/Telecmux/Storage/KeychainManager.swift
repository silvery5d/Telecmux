import Foundation
import Security

/// Reads and writes raw bytes into the iOS Keychain under a private service
/// namespace. Each Host record holds an opaque `account` string (typically a
/// UUID) that resolves to the private key bytes the SSH layer wants.
///
/// All entries live under one `kSecAttrService` so removing the app cleans
/// up everything. Nothing about the key material leaves the Keychain — the
/// JSON store only sees the account string.
enum KeychainStore {
    static let service = "com.telecmux.ssh-keys"

    enum Failure: LocalizedError {
        case write(OSStatus)
        case read(OSStatus)
        case missing
        case malformed

        var errorDescription: String? {
            switch self {
            case .write(let s):  "Keychain write failed (OSStatus \(s))"
            case .read(let s):   "Keychain read failed (OSStatus \(s))"
            case .missing:       "No key found for that account"
            case .malformed:     "Key data is not valid UTF-8"
            }
        }
    }

    @discardableResult
    static func store(_ bytes: Data, as account: String) throws -> String {
        var query = baseQuery(account: account)
        // Idempotent: clear before write so the same account always replaces.
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = bytes
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.write(status) }
        return account
    }

    static func load(_ account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.malformed }
            return data
        case errSecItemNotFound:
            throw Failure.missing
        default:
            throw Failure.read(status)
        }
    }

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    static func contains(_ account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

/// Thin compatibility shim so existing call sites that read/write keys keep
/// compiling. New code should call `KeychainStore` directly.
enum KeychainManager {
    static func save(key: String, data: Data) throws {
        try KeychainStore.store(data, as: key)
    }
    static func load(key: String) throws -> Data {
        try KeychainStore.load(key)
    }
    static func delete(key: String) {
        KeychainStore.remove(key)
    }
}
