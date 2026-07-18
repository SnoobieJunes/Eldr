import Foundation
import PQRCACP
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

// A2 — the tool-result aging + spill knobs round-trip through the env file, and A4 —
// the agent-version staleness seam is readable from the store.
@Suite("A2/A4: tool-result knobs + agent version")
struct ToolResultKnobsAndVersionTests {
    @MainActor
    @Test func agingAndSpillKnobsRoundTripThroughEnvFile() {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-a2-\(UUID().uuidString)")
        let paths = ConfigPaths(configDir: tmp, binDir: tmp)
        let kc = KeychainBox(service: "test-a2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = ConfigurationStore(paths: paths, keychain: kc)
        store.toolResultKeepVerbatim = 7
        store.toolResultSpillEnabled = false
        store.save()

        // The env file carries both knobs…
        let env = (try? String(contentsOfFile: paths.envFile, encoding: .utf8)) ?? ""
        #expect(env.contains("ELDR_ACP_TOOL_RESULT_KEEP='7'"))
        #expect(env.contains("ELDR_ACP_TOOL_RESULT_SPILL='0'"))

        // …and a fresh store re-reads them through AgentConfig's own parser.
        let reloaded = ConfigurationStore(paths: paths, keychain: kc)
        #expect(reloaded.toolResultKeepVerbatim == 7)
        #expect(reloaded.toolResultSpillEnabled == false)
        #expect(reloaded.agentConfig.toolResultKeepVerbatim == 7)
        #expect(reloaded.agentConfig.toolResultSpillEnabled == false)
    }

    @MainActor
    @Test func expectedAgentVersionIsNonEmptyAndMatchesPackageConstant() {
        #expect(!ConfigurationStore.expectedAgentVersion.isEmpty)
        #expect(ConfigurationStore.expectedAgentVersion == ACPAgent.agentVersionSummary)
    }

    @MainActor
    @Test func installedAgentVersionNilWhenBinaryAbsent() async {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-a4-\(UUID().uuidString)")
        let store = ConfigurationStore(
            paths: ConfigPaths(configDir: tmp, binDir: tmp),
            keychain: KeychainBox(service: "test-a4-\(UUID().uuidString)"))
        // No binary installed under binDir → nil, not a crash.
        let version = await store.installedAgentVersion()
        #expect(version == nil)
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

// WS-B2: the relay-URL override may use plaintext `ws://` ONLY for loopback — and
// "loopback" must mean an address literal, not a string prefix: `127.evil.com` is a
// DNS name that can resolve anywhere and must be refused plaintext.
@Suite("WS-B2: relay override validation")
struct RelayOverrideValidationTests {
    @MainActor
    @Test func emptyMeansDefault() {
        #expect(ConfigurationStore.validateRelayOverride("  ") == .success(nil))
    }

    @MainActor
    @Test func wssAllowedAnywhere() {
        #expect(
            ConfigurationStore.validateRelayOverride("wss://relay.lerants.com")
                == .success("wss://relay.lerants.com"))
    }

    @MainActor
    @Test func wsAllowedOnLoopbackOnly() {
        for ok in ["ws://127.0.0.1:7777", "ws://localhost:7777", "ws://[::1]:7777",
            "ws://127.1.2.3"] {
            #expect(ConfigurationStore.validateRelayOverride(ok) == .success(ok), "\(ok)")
        }
        for bad in ["ws://relay.lerants.com", "ws://127.evil.com:7777", "ws://127.evil.com",
            "ws://192.168.1.10:7777", "ws://127.0.0.1.attacker.net"] {
            #expect(
                ConfigurationStore.validateRelayOverride(bad) == .failure(.plaintextOffLoopback),
                "\(bad)")
        }
    }

    @MainActor
    @Test func nonWebSocketSchemesRefused() {
        #expect(
            ConfigurationStore.validateRelayOverride("https://relay.lerants.com")
                == .failure(.unsupportedScheme))
        #expect(ConfigurationStore.validateRelayOverride("not a url") == .failure(.invalidURL))
    }
}
