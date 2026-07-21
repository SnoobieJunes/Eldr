// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security

// macOS Keychain store for the standalone node's long-term secrets (CLAUDE.md inv. 10):
// every item is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never synced, never
// exported, and the raw bytes are NEVER logged (the daemon prints only non-sensitive
// status). This mirrors the Configurator's `KeychainBox` access rules; it lives in the
// (non-unit-tested) executable target on purpose, so `EldrNodeCore`/its tests stay
// Keychain-free and headless.
//
// FOLLOW-UP (documented, not built tonight): a Linux server / Raspberry Pi has NO macOS
// Keychain. `runACPAgent` is macOS-only anyway (it spawns `Foundation.Process`), so the
// node targets macOS tonight; a hardened file-keystore for keychain-less hosts is a
// separate deliverable, NOT attempted here.

/// A tiny generic-password Keychain box, scoped to one service. Used by `eldr-node` to
/// load-or-create its Nostr identity, PQRC identity seed, identity-DH seed, and prekey
/// state across restarts.
struct NodeKeychain {
    let service: String

    init(service: String = "org.eldr.node") {
        self.service = service
    }

    /// Read the item for `account`, or nil if absent. Never logs the bytes.
    func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    /// Store `data` for `account`, replacing any prior value. The item is bound to this
    /// device and only readable while unlocked (inv. 10). Throws on a hard Keychain error.
    func save(_ data: Data, account: String) throws {
        // Delete any existing item first so a re-save updates cleanly (SecItemAdd would
        // otherwise fail with errSecDuplicateItem).
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NodeKeychainError.unhandled(status)
        }
    }

    /// Remove the item for `account` (no-op if absent).
    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum NodeKeychainError: Error {
    case unhandled(OSStatus)
}
