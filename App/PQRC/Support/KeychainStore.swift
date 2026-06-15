import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case notFound
}

/// Outcome of a biometric-gated read, so the caller can message precisely:
/// a missing item, a user cancel, and a real auth failure are all different
/// (and only the last should look like an error to the user).
enum BiometricLoad {
    case success(Data)
    case missing
    case cancelled
    case failed(OSStatus)
}

/// Keychain access for long-term secrets (SPEC §3.1, APP-SPEC §3).
/// Every item: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never
/// iCloud-synced, never exported. Enforced by the security test suite.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "chat.pqrc.keys") {
        self.service = service
    }

    func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func load(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    func loadIfPresent(account: String) -> Data? {
        try? load(account: account)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Saves a secret gated behind biometrics / device passcode (`.userPresence`):
    /// reading it later prompts Face ID / Touch ID. Used for the convenience
    /// "unlock with Face ID" tier — the high-security tier stores nothing here.
    func saveBiometric(_ data: Data, account: String) throws {
        delete(account: account)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error)
        else { throw KeychainError.unexpectedStatus(errSecParam) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessControl as String: access,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Reads a biometric-gated secret, presenting `prompt` in the Face ID sheet.
    /// Distinguishes a missing item, a user cancel, and a real auth failure so
    /// the caller can message accordingly (a cancel is not an error — the user
    /// may want to type a different account's passphrase). Call off the main
    /// thread (the biometric prompt blocks).
    func loadBiometric(account: String, prompt: String) -> BiometricLoad {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: prompt,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            if let data = result as? Data { return .success(data) }
            return .failed(status)
        case errSecItemNotFound:
            return .missing
        // -128: the user tapped Cancel in the Face ID / passcode sheet.
        case errSecUserCanceled:
            return .cancelled
        default:
            return .failed(status)
        }
    }

    func contains(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Don't trigger biometric auth just to check existence.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
    }

    /// Test hook: raw attributes of an item, for asserting accessibility flags.
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
}
