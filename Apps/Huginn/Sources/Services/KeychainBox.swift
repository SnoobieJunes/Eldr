import Foundation
import Security

/// Minimal Keychain wrapper for the Configurator's long-term secret (its Nostr
/// identity). Mirrors the app's SPEC §3.1 rules exactly: every item is
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable:false`
/// — never iCloud-synced, never leaves the device. (The app's `KeychainStore` lives
/// in the app target, so the Configurator carries its own copy of the same policy.)
struct KeychainBox: Sendable {
    let service: String
    init(service: String = "chat.eldr.huginn") { self.service = service }

    func save(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainBoxError.status(status) }
    }

    func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Test/audit hook: raw attributes of an item, for asserting the access flags.
    func attributes(account: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? [String: Any]
    }

    enum KeychainBoxError: Error { case status(OSStatus) }
}
