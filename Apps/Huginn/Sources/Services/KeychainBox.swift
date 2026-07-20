// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Security

/// Minimal Keychain wrapper for the Configurator's long-term secrets (its Nostr
/// identity, the bridge PQRC identity, and the LLM token). Mirrors the app's SPEC §3.1
/// rules exactly: every item is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
/// `kSecAttrSynchronizable:false` — never iCloud-synced, never leaves the device. (The
/// app's `KeychainStore` lives in the app target, so the Configurator carries its own
/// copy of the same policy.)
///
/// `useDataProtection` (default ON) routes items into the **data-protection keychain**
/// instead of the legacy FILE keychain. The file keychain attaches a per-application
/// ACL to each item; because a re-signed build (every Xcode rebuild) presents a
/// different code signature, macOS no longer recognizes it as the item's owner and
/// re-prompts ("…wants to use your confidential information — Always Allow") — and the
/// grant never sticks, so the Configurator's ~5 items each prompt again on the next
/// build. The data-protection keychain has NO such ACL dialog: access is gated by the
/// app's `keychain-access-groups` entitlement (team-scoped, signature-independent), so
/// the same-team build reads silently every time. Requires the entitlement (see
/// `Huginn.entitlements`); we pass no explicit `kSecAttrAccessGroup`, so items land in
/// the entitlement's single group by default (the pattern the iOS `KeychainStore` uses).
///
/// The one item still kept in the FILE keychain is the LLM token's launcher-read mirror
/// (`ConfigurationStore`), because the `eldr-acp` launcher reads it with `/usr/bin/security`,
/// which cannot see data-protection items. That mirror prompts at most once and the grant
/// DOES stick there, because `/usr/bin/security` is Apple-signed and its signature never
/// changes between Huginn rebuilds.
struct KeychainBox: Sendable {
    let service: String
    let useDataProtection: Bool

    init(service: String = "chat.eldr.huginn", useDataProtection: Bool = true) {
        self.service = service
        self.useDataProtection = useDataProtection
    }

    /// The keychain-selection key merged into every query. It is set EXPLICITLY in both
    /// directions — `false` is not the same as omitting the key. Omitting it lets a query
    /// match items in EITHER keychain, and `save()` opens with a `SecItemDelete`: the
    /// launcher's file-keychain mirror (`useDataProtection: false`, same service+account)
    /// would delete the data-protection item that was just written, so the token vanished
    /// the moment it was saved and Huginn read back an empty token on every relaunch.
    /// Pinning the selector keeps the two keychains disjoint.
    private var keychainSelector: [String: Any] {
        [kSecUseDataProtectionKeychain as String: useDataProtection]
    }

    func save(_ data: Data, account: String) throws {
        var base: [String: Any] = keychainSelector
        base[kSecClass as String] = kSecClassGenericPassword
        base[kSecAttrService as String] = service
        base[kSecAttrAccount as String] = account
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainBoxError.status(status) }
    }

    /// Attribute-only existence probe — never touches the secret data, so it cannot
    /// trigger a keychain ACL prompt (data reads of another creator's item can).
    func hasItem(account: String) -> Bool {
        var query: [String: Any] = keychainSelector
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    func load(account: String) -> Data? {
        var query: [String: Any] = keychainSelector
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    func delete(account: String) {
        var query: [String: Any] = keychainSelector
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        SecItemDelete(query as CFDictionary)
    }

    /// Test/audit hook: raw attributes of an item, for asserting the access flags.
    func attributes(account: String) -> [String: Any]? {
        var query: [String: Any] = keychainSelector
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? [String: Any]
    }

    enum KeychainBoxError: Error { case status(OSStatus) }
}
