import Foundation
import Testing

@testable import Huginn

// C-8: the LLM token must live in the Keychain (WhenUnlockedThisDeviceOnly), never in
// the cleartext env file the launcher sources (it previously landed world-readable at
// the umask). These tests isolate to a per-run Keychain service so they never touch the
// real item.

@Suite("C-8: LLM token at rest (Keychain, not env file)")
struct LLMTokenAtRestTests {
    @MainActor
    @Test func tokenGoesToKeychainNotEnvFile() throws {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-c8-\(UUID().uuidString)")
        let paths = ConfigPaths(configDir: tmp, binDir: tmp)
        let kc = KeychainBox(service: "test-c8-\(UUID().uuidString)")
        defer {
            kc.delete(account: "llm-token")
            try? FileManager.default.removeItem(atPath: tmp)
        }

        let store = ConfigurationStore(paths: paths, keychain: kc)
        store.llmToken = "sk-secret-canary"
        store.save()

        // The env file exists, is owner-only (0600), and does NOT carry the token.
        let env = (try? String(contentsOfFile: paths.envFile, encoding: .utf8)) ?? ""
        #expect(!env.contains("sk-secret-canary"))
        #expect(!env.contains("ELDR_LLM_TOKEN"))
        let perms =
            try FileManager.default.attributesOfItem(atPath: paths.envFile)[.posixPermissions]
            as? Int
        #expect(perms == 0o600)

        // The token round-trips through the Keychain, and a fresh store reloads it.
        #expect(
            kc.load(account: "llm-token").flatMap { String(data: $0, encoding: .utf8) }
                == "sk-secret-canary")
        let reloaded = ConfigurationStore(paths: paths, keychain: kc)
        #expect(reloaded.llmToken == "sk-secret-canary")
    }

    @MainActor
    @Test func blankTokenClearsTheKeychainItem() throws {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-c8b-\(UUID().uuidString)")
        let paths = ConfigPaths(configDir: tmp, binDir: tmp)
        let kc = KeychainBox(service: "test-c8b-\(UUID().uuidString)")
        defer {
            kc.delete(account: "llm-token")
            try? FileManager.default.removeItem(atPath: tmp)
        }

        let store = ConfigurationStore(paths: paths, keychain: kc)
        store.llmToken = "sk-temp"
        store.save()
        #expect(kc.load(account: "llm-token") != nil)

        store.llmToken = ""
        store.save()
        #expect(kc.load(account: "llm-token") == nil)  // cleared, not left behind
    }
}
