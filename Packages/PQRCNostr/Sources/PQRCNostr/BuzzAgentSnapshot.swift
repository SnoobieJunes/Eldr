// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A **Buzz agent snapshot** (`buzz-agent-snapshot` v1) — the portable manifest
/// Buzz Desktop imports to create a managed agent in its **Agents tab**.
///
/// This is how an Eldr/Huginn-hosted local model becomes a *Buzz-managed* agent
/// (Path B, `docs/ELDR-BUZZ-GUI-PLAN.md §7`): Huginn writes a `.agent.json`
/// wired to the local model's provider/model/runtime; the user imports it and
/// Buzz opens its "Edit agent" draft pre-filled (the exact screen the owner
/// showed), then saves — the agent runs under Buzz's own management, brained by
/// Huginn's `:1337`.
///
/// The schema mirrors Buzz's `desktop/src-tauri/src/managed_agents/agent_snapshot.rs`
/// EXACTLY (`format`/`version` discriminators, camelCase keys, `snake_case`
/// `memory.level`). Machine-local secrets (private key, auth tag, relay URL,
/// env, harness command) are DELIBERATELY absent — Buzz fills those in on import
/// (it mints the agent key and sets the relay itself). Verified against Buzz's
/// schema in `BuzzAgentSnapshotTests`; the import applies `provider`/`model`/
/// `runtime` (buzz `persona_events.rs:478-480`).
public struct BuzzAgentSnapshot: Codable, Equatable, Sendable {
    /// Fixed discriminator Buzz sniffs on import — MUST be `buzz-agent-snapshot`.
    public var format: String
    /// Schema version — this producer emits `1`.
    public var version: Int
    public var definition: Definition
    public var profile: Profile
    public var memory: Memory

    public static let formatDiscriminator = "buzz-agent-snapshot"
    public static let formatVersion = 1

    /// Behavioral definition — mirrors Buzz's `AgentSnapshotDefinition`.
    public struct Definition: Codable, Equatable, Sendable {
        public var name: String
        public var systemPrompt: String?
        /// Harness: `goose` (the one that speaks a local OpenAI endpoint),
        /// `claude`, or `codex`.
        public var runtime: String?
        /// Model id as the provider reports it.
        public var model: String?
        /// LLM provider base URL (e.g. `http://127.0.0.1:1337/v1`).
        public var provider: String?
        public var parallelism: Int?
        /// `owner-only` | `allowlist` | `anyone` | `nobody`.
        public var respondTo: String?
        public var respondToAllowlist: [String]?
        public var namePool: [String]?
        public var idleTimeoutSeconds: Int?
        public var maxTurnDurationSeconds: Int?

        public init(
            name: String, systemPrompt: String? = nil, runtime: String? = nil, model: String? = nil,
            provider: String? = nil, parallelism: Int? = nil, respondTo: String? = nil,
            respondToAllowlist: [String]? = nil, namePool: [String]? = nil,
            idleTimeoutSeconds: Int? = nil, maxTurnDurationSeconds: Int? = nil
        ) {
            self.name = name
            self.systemPrompt = systemPrompt
            self.runtime = runtime
            self.model = model
            self.provider = provider
            self.parallelism = parallelism
            self.respondTo = respondTo
            self.respondToAllowlist = respondToAllowlist
            self.namePool = namePool
            self.idleTimeoutSeconds = idleTimeoutSeconds
            self.maxTurnDurationSeconds = maxTurnDurationSeconds
        }
    }

    /// kind:0 presentation — mirrors Buzz's `AgentSnapshotProfile`.
    public struct Profile: Codable, Equatable, Sendable {
        public var displayName: String
        public var about: String?
        /// Avatar inlined as a `data:image/...;base64,…` URI (≤ 2 MB).
        public var avatarDataUrl: String?
        public var avatarUrl: String?

        public init(
            displayName: String, about: String? = nil, avatarDataUrl: String? = nil,
            avatarUrl: String? = nil
        ) {
            self.displayName = displayName
            self.about = about
            self.avatarDataUrl = avatarDataUrl
            self.avatarUrl = avatarUrl
        }
    }

    /// Memory section — mirrors Buzz's `AgentSnapshotMemory`. Default `none`
    /// (config-only, safest for sharing — Buzz's own default).
    public struct Memory: Codable, Equatable, Sendable {
        /// `none` | `core` | `everything`.
        public var level: String
        public var entries: [Entry]?

        public struct Entry: Codable, Equatable, Sendable {
            public var slug: String
            public var body: String
            public init(slug: String, body: String) {
                self.slug = slug
                self.body = body
            }
        }

        public init(level: String = "none", entries: [Entry]? = nil) {
            self.level = level
            self.entries = entries
        }
    }

    public init(definition: Definition, profile: Profile, memory: Memory = Memory()) {
        self.format = Self.formatDiscriminator
        self.version = Self.formatVersion
        self.definition = definition
        self.profile = profile
        self.memory = memory
    }

    // MARK: - Generator

    /// Build a snapshot that registers a LOCAL model (Huginn's `:1337`) as a
    /// Buzz-managed agent. `providerURL` is the OpenAI-compatible base URL and
    /// `model` is the loaded model id (both as shown in Buzz's Edit-agent
    /// screen). Runtime defaults to `goose` (it speaks local OpenAI endpoints).
    public static func forLocalModel(
        displayName: String,
        systemPrompt: String,
        providerURL: String,
        model: String,
        about: String? = nil,
        runtime: String = "goose",
        respondTo: String = "owner-only",
        parallelism: Int = 1,
        avatarDataUrl: String? = nil
    ) -> BuzzAgentSnapshot {
        BuzzAgentSnapshot(
            definition: Definition(
                name: displayName, systemPrompt: systemPrompt, runtime: runtime, model: model,
                provider: providerURL, parallelism: parallelism, respondTo: respondTo,
                namePool: [displayName]),
            profile: Profile(
                displayName: displayName, about: about, avatarDataUrl: avatarDataUrl),
            memory: Memory(level: "none"))
    }

    // MARK: - Encode / decode

    /// Pretty-printed JSON bytes for a `.agent.json` file — matches Buzz's
    /// `encode_snapshot_json` (`serde_json::to_vec_pretty`). Optional nil fields
    /// and empty arrays are omitted (Swift synthesizes `encodeIfPresent`).
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public enum SnapshotError: Error, Equatable { case wrongFormat(String) }

    public static func decode(_ data: Data) throws -> BuzzAgentSnapshot {
        let snapshot = try JSONDecoder().decode(BuzzAgentSnapshot.self, from: data)
        guard snapshot.format == formatDiscriminator else {
            throw SnapshotError.wrongFormat(snapshot.format)
        }
        return snapshot
    }
}
