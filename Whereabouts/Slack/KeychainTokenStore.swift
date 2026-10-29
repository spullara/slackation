import Foundation
import Security

struct KeychainTokenStore {
    let service: String
    let account: String

    init(service: String = "com.whereabouts.slack-token", account: String = "slack-user") {
        self.service = service
        self.account = account
    }

    func save(_ token: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            // Region events must work while the phone is locked after its first unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = query.merging(attributes) { _, new in new }
            try check(SecItemAdd(insertion as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func read() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw StoreError(status: errSecDecode)
        }
        return token
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    struct StoreError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not access the credential in Keychain (\(status))." }
    }
}
