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
            providerURL: "http://127.0.0.1:1337/v1",
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
        #expect(json.contains("\"provider\" : \"http:\\/\\/127.0.0.1:1337\\/v1\"") || json.contains("\"provider\" : \"http://127.0.0.1:1337/v1\""))
        #expect(json.contains("\"runtime\" : \"goose\""))
        #expect(json.contains("\"model\" :"))
        #expect(json.contains("\"systemPrompt\" :"))
        #expect(json.contains("\"respondTo\" : \"owner-only\""))
        #expect(json.contains("\"displayName\" : \"Eldr (local model)\""))
        #expect(json.contains("\"level\" : \"none\""))
    }

    @Test("nil/empty optional fields are omitted (matches serde skip_serializing_if)")
    func omitsEmpties() throws {
        // A minimal snapshot with no about/avatar/allowlist must not emit those keys.
        let snap = BuzzAgentSnapshot(
            definition: .init(name: "X", provider: "http://127.0.0.1:1337/v1"),
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
        #expect(decoded.definition.provider == "http://127.0.0.1:1337/v1")
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
            providerURL: env["ELDR_LLM_URL"] ?? "http://127.0.0.1:1337/v1",
            model: env["ELDR_LLM_MODEL"]
                ?? "dawncr0w/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-OptiQ-5bpw-MLX",
            about: "A local, on-device AI hosted on this machine via Eldr/Huginn.")
        let data = try snapshot.encodedJSON()
        try data.write(to: URL(fileURLWithPath: path))
        print("SNAPSHOT: wrote \(data.count) bytes to \(path)")
        print("SNAPSHOT: import it in Buzz Desktop (Agents → import) to add the local model as a managed agent.")
    }
}
