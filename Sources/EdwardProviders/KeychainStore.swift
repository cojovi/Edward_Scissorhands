import Foundation
import Security
import EdwardDomain

/// Credentials are stored outside project files and never included in provider configuration.
public enum KeychainStore {
    private static let service = "com.edwardscissorhands.provider-credentials"

    public static func save(_ key: String, providerID: String) throws {
        guard !providerID.isEmpty, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EdwardError.invalidInput("Enter a provider ID and API key.")
        }
        let query = baseQuery(providerID)
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(update) }
    }

    public static func read(providerID: String) throws -> String? {
        var query = baseQuery(providerID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw EdwardError.provider("The saved credential could not be read. Save the API key again.")
        }
        return value
    }

    public static func delete(providerID: String) throws {
        let status = SecItemDelete(baseQuery(providerID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func baseQuery(_ id: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw EdwardError.provider("Keychain access failed (\(status)). Unlock your login keychain and try again.")
        }
    }
}
