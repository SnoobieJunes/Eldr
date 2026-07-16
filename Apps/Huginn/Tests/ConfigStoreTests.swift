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

@Suite("resolvedHarnessDescriptor merges the A2A bearer token, leaves others untouched")
struct ResolvedHarnessDescriptorA2ATests {
    @MainActor
    @Test func mergesBearerTokenForA2ARemoteDescriptor() {
        let kc = KeychainBox(service: "test-a2a-\(UUID().uuidString)")
        defer { kc.delete(account: "vendor-a2a-bearer-a2a-local-sample") }

        // No token on file yet: the descriptor still resolves, unauthenticated.
        let bare = ConfigurationStore.resolvedHarnessDescriptor(id: "a2a-local-sample", keychain: kc)
        #expect(bare?.a2aBearerToken == nil)

        let store = ConfigurationStore(
            paths: ConfigPaths(configDir: NSTemporaryDirectory(), binDir: NSTemporaryDirectory()),
            keychain: kc)
        store.setA2ABearerToken("secret-bearer-canary", for: "a2a-local-sample")
        #expect(store.a2aBearerToken(for: "a2a-local-sample") == "secret-bearer-canary")

        let resolved = ConfigurationStore.resolvedHarnessDescriptor(id: "a2a-local-sample", keychain: kc)
        #expect(resolved?.a2aBearerToken == "secret-bearer-canary")
        #expect(resolved?.kind == .a2aRemote)
    }

    @MainActor
    @Test func leavesStdioSpawnDescriptorsUntouchedByBearerLogic() {
        let kc = KeychainBox(service: "test-a2a-b-\(UUID().uuidString)")
        defer {
            kc.delete(account: "vendor-key-claude-code")
            kc.delete(account: "vendor-a2a-bearer-claude-code")
        }
        try? kc.save(Data("sk-ant-canary".utf8), account: "vendor-key-claude-code")

        let resolved = ConfigurationStore.resolvedHarnessDescriptor(id: "claude-code", keychain: kc)
        #expect(resolved?.env["ANTHROPIC_API_KEY"] == "sk-ant-canary")
        #expect(resolved?.a2aBearerToken == nil)  // never merged for a non-a2a descriptor
    }
}
