import Foundation
import Testing

@testable import Huginn

/// Regression: the two keychains must stay DISJOINT.
///
/// `ConfigurationStore.saveTokenToKeychain()` writes the LLM token twice — once to the
/// data-protection keychain (Huginn's own prompt-free reads) and once to the legacy FILE
/// keychain (the launcher's `/usr/bin/security` read). `KeychainBox.save()` opens with a
/// `SecItemDelete`. When the file-keychain box omitted `kSecUseDataProtectionKeychain`
/// from its query instead of setting it to `false`, that delete matched the
/// data-protection item too (same service + account) and wiped the token that had just
/// been written — so Huginn read back an EMPTY token on every relaunch and the Mac AI
/// could not authenticate to its LLM.
@Suite("Keychain isolation (data-protection vs file)")
struct KeychainIsolationTests {
    @Test func fileMirrorDoesNotClobberTheDataProtectionItem() throws {
        let service = "test-kc-iso-\(UUID().uuidString)"
        let dp = KeychainBox(service: service)
        let file = KeychainBox(service: service, useDataProtection: false)
        defer {
            dp.delete(account: "llm-token")
            file.delete(account: "llm-token")
        }

        try dp.save(Data("sk-secret-canary".utf8), account: "llm-token")
        try file.save(Data("sk-secret-canary".utf8), account: "llm-token")

        // The mirror must leave the data-protection item intact.
        #expect(
            dp.load(account: "llm-token").flatMap { String(data: $0, encoding: .utf8) }
                == "sk-secret-canary")

        // And deleting one must not delete the other.
        file.delete(account: "llm-token")
        #expect(
            dp.load(account: "llm-token").flatMap { String(data: $0, encoding: .utf8) }
                == "sk-secret-canary")
    }
}
