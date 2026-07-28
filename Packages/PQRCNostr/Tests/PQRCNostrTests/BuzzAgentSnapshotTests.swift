// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCNostr

/// Proves the Eldr-generated Buzz agent snapshot matches Buzz's
/// `buzz-agent-snapshot` v1 schema exactly, so Buzz Desktop imports it into the
/// Agents tab pre-wired to Huginn's local model.
@Suite("Buzz agent snapshot")
struct BuzzAgentSnapshotTests {

    private func localModelSnapshot() -> BuzzAgentSnapshot {
        BuzzAgentSnapshot.forLocalModel(
            displayName: "Eldr (local model)",
            systemPrompt:
                "You are a helpful AI running locally on the owner's own machine (Huginn). "
                + "Answer directly and concisely. Nothing you process leaves this machine to a "
                + "cloud model.",
            providerBaseURL: "http://127.0.0.1:1337/v1",
            model: "dawncr0w/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-OptiQ-5bpw-MLX",
            about: "A local, on-device AI hosted on this machine via Eldr/Huginn.")
    }

    @Test("snapshot encodes to Buzz's exact schema keys")
    func schemaKeys() throws {
        let json = String(decoding: try localModelSnapshot().encodedJSON(), as: UTF8.self)
        // Discriminators Buzz sniffs on import.
        #expect(json.contains("\"format\" : \"buzz-agent-snapshot\""))
        #expect(json.contains("\"version\" : 1"))
        // The wiring that makes it use the LOCAL model (camelCase, per Buzz's rename_all).
        // `provider` is a goose PROVIDER ID (it becomes GOOSE_PROVIDER at spawn),
        // never a URL — a URL here imports fine and then never answers.
        #expect(json.contains("\"provider\" : \"lmstudio\""))
        #expect(!json.contains("127.0.0.1"), "a base URL must not leak into `provider`")
        #expect(json.contains("\"runtime\" : \"goose\""))
        #expect(json.contains("\"model\" :"))
        #expect(json.contains("\"systemPrompt\" :"))
        #expect(json.contains("\"respondTo\" : \"owner-only\""))
        #expect(json.contains("\"displayName\" : \"Eldr (local model)\""))
        #expect(json.contains("\"level\" : \"none\""))
    }

    @Test("local-provider env hints carry the endpoint Buzz's manifest cannot")
    func providerEnvironmentHints() {
        // Buzz excludes env_vars from snapshots by design, so the host variable is
        // what the user pastes into Advanced ▸ env vars (or already has in goose's
        // own config). goose's lmstudio provider appends `/v1/chat/completions`,
        // so the hint is the ORIGIN, not the `/v1` base.
        let lmstudio = BuzzAgentSnapshot.LocalProvider.lmstudio
        #expect(lmstudio.providerID == "lmstudio")
        #expect(
            lmstudio.environmentHints(baseURL: "http://127.0.0.1:1337/v1").map { [$0.key, $0.value] }
                == [["LMSTUDIO_HOST", "http://127.0.0.1:1337"]])

        // openai-against-a-local-host also needs the base path and a (dummy) key.
        let openai = BuzzAgentSnapshot.LocalProvider.openai
        let hints = openai.environmentHints(baseURL: "http://127.0.0.1:1337/v1/")
        #expect(hints.first?.key == "OPENAI_HOST")
        #expect(hints.first?.value == "http://127.0.0.1:1337")
        #expect(hints.contains { $0.key == "OPENAI_BASE_PATH" && $0.value == "v1/chat/completions" })
        #expect(hints.contains { $0.key == "OPENAI_API_KEY" })

        // Origin extraction tolerates the shapes a user actually types.
        #expect(BuzzAgentSnapshot.LocalProvider.originOf("http://127.0.0.1:1337") == "http://127.0.0.1:1337")
        #expect(
            BuzzAgentSnapshot.LocalProvider.originOf("http://127.0.0.1:1337/v1/chat/completions")
                == "http://127.0.0.1:1337")
        #expect(BuzzAgentSnapshot.LocalProvider.originOf("  http://mac.local:1337/v1/ ") == "http://mac.local:1337")
    }

    @Test("nil/empty optional fields are omitted (matches serde skip_serializing_if)")
    func omitsEmpties() throws {
        // A minimal snapshot with no about/avatar/allowlist must not emit those keys.
        let snap = BuzzAgentSnapshot(
            definition: .init(name: "X", provider: "lmstudio"),
            profile: .init(displayName: "X"))
        let json = String(decoding: try snap.encodedJSON(), as: UTF8.self)
        #expect(!json.contains("about"))
        #expect(!json.contains("avatarDataUrl"))
        #expect(!json.contains("respondToAllowlist"))
        #expect(!json.contains("systemPrompt"))
    }

    @Test("round-trips through encode/decode")
    func roundTrip() throws {
        let original = localModelSnapshot()
        let decoded = try BuzzAgentSnapshot.decode(try original.encodedJSON())
        #expect(decoded == original)
        #expect(decoded.definition.provider == "lmstudio")
        #expect(decoded.definition.runtime == "goose")
    }

    @Test("decode rejects a non-Buzz manifest")
    func rejectsWrongFormat() {
        let bad = Data(#"{"format":"not-buzz","version":1,"definition":{"name":"x"},"profile":{"displayName":"x"},"memory":{"level":"none"}}"#.utf8)
        #expect(throws: (any Error).self) { try BuzzAgentSnapshot.decode(bad) }
    }

    /// Writes a ready-to-import `.agent.json` to `BUZZ_SNAPSHOT_OUT`. Gated so it
    /// only runs when explicitly asked (it touches the filesystem).
    ///   BUZZ_SNAPSHOT_OUT=/path/Eldr.agent.json swift test --filter writeEldrAgentSnapshotFile
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUZZ_SNAPSHOT_OUT"] != nil))
    func writeEldrAgentSnapshotFile() throws {
        let path = ProcessInfo.processInfo.environment["BUZZ_SNAPSHOT_OUT"]!
        let env = ProcessInfo.processInfo.environment
        let snapshot = BuzzAgentSnapshot.forLocalModel(
            displayName: env["BUZZ_SNAPSHOT_NAME"] ?? "Eldr (local model)",
            systemPrompt: env["BUZZ_SNAPSHOT_PROMPT"]
                ?? "You are a helpful AI running locally on the owner's own machine (Huginn). "
                    + "Answer directly and concisely. Nothing you process leaves this machine.",
            providerBaseURL: env["ELDR_LLM_URL"] ?? "http://127.0.0.1:1337/v1",
            model: env["ELDR_LLM_MODEL"]
                ?? "dawncr0w/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-OptiQ-5bpw-MLX",
            about: "A local, on-device AI hosted on this machine via Eldr/Huginn.")
        let data = try snapshot.encodedJSON()
        try data.write(to: URL(fileURLWithPath: path))
        print("SNAPSHOT: wrote \(data.count) bytes to \(path)")
        print("SNAPSHOT: import it in Buzz Desktop (Agents → import) to add the local model as a managed agent.")
    }
}
