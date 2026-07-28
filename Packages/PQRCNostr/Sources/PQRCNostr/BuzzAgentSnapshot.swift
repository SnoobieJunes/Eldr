// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A **Buzz agent snapshot** (`buzz-agent-snapshot` v1) — the portable manifest
/// Buzz Desktop imports to create a managed agent in its **Agents tab**.
///
/// This is how an Eldr/Huginn-hosted local model becomes a *Buzz-managed* agent
/// (Path B, `docs/done/2026-07-24/ELDR-BUZZ-GUI-PLAN.md §7`): Huginn writes a `.agent.json`
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

    // MARK: - Local-model providers

    /// How a Buzz-managed **goose** agent is pointed at a LOCAL OpenAI-compatible
    /// endpoint (Huginn's `:1337`).
    ///
    /// Buzz's `definition.provider` is a **provider ID**, not a URL: at spawn time
    /// Buzz projects it into the runtime's `provider_env_var` (`GOOSE_PROVIDER` for
    /// the goose runtime — `desktop/src-tauri/src/managed_agents/discovery.rs`), and
    /// goose then resolves the base URL from that provider's OWN host variable
    /// (`LMSTUDIO_HOST`, `OPENAI_HOST`, `OLLAMA_HOST`). Writing the base URL into
    /// `provider` therefore yields `GOOSE_PROVIDER=http://127.0.0.1:1337/v1`, which
    /// goose rejects as an unknown provider — the agent imports and then never
    /// answers. `environmentHints` carries the host variable the user pastes into
    /// Buzz's Advanced ▸ env-vars box, because a snapshot deliberately CANNOT carry
    /// env vars (Buzz excludes them as potential credentials — `agent_snapshot.rs`
    /// §Secret exclusion).
    public enum LocalProvider: String, Codable, Sendable, CaseIterable {
        /// goose `lmstudio`: `base_url = ${LMSTUDIO_HOST}/v1/chat/completions`.
        /// Any OpenAI-compatible server (MLX's `mlx_lm.server`, LM Studio) fits.
        case lmstudio
        /// goose `openai` against a custom host (`OPENAI_HOST` + `OPENAI_BASE_PATH`).
        case openai
        /// goose `ollama` (`OLLAMA_HOST`).
        case ollama

        /// The `GOOSE_PROVIDER` value — what goes in `definition.provider`.
        public var providerID: String { rawValue }

        /// The env var carrying the endpoint's host for this provider.
        public var hostEnvVar: String {
            switch self {
            case .lmstudio: return "LMSTUDIO_HOST"
            case .openai: return "OPENAI_HOST"
            case .ollama: return "OLLAMA_HOST"
            }
        }

        /// The env vars a user must have set (in goose's own config, or pasted into
        /// Buzz's Advanced ▸ env vars) for this provider to reach `baseURL`.
        /// `baseURL` is the OpenAI-compatible base (`http://127.0.0.1:1337/v1`);
        /// goose appends its own path, so the `/v1…` suffix is stripped here.
        public func environmentHints(baseURL: String) -> [(key: String, value: String)] {
            let host = Self.originOf(baseURL)
            switch self {
            case .lmstudio, .ollama:
                return [(hostEnvVar, host)]
            case .openai:
                return [
                    (hostEnvVar, host),
                    ("OPENAI_BASE_PATH", "v1/chat/completions"),
                    // goose requires a key even for a local server; any value works.
                    ("OPENAI_API_KEY", "local"),
                ]
            }
        }

        /// `http://127.0.0.1:1337/v1/` → `http://127.0.0.1:1337`. Tolerates a bare
        /// host, a trailing slash, and a missing scheme.
        public static func originOf(_ baseURL: String) -> String {
            var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            for suffix in ["/v1/chat/completions", "/v1"] where s.hasSuffix(suffix) {
                s.removeLast(suffix.count)
                break
            }
            return s
        }
    }

    // MARK: - Generator

    /// Build a snapshot that registers a LOCAL model (Huginn's `:1337`) as a
    /// Buzz-managed agent. `provider` selects the goose provider ID written into
    /// `definition.provider`; `providerBaseURL` is the OpenAI-compatible base URL
    /// the matching env var must point at (see `LocalProvider`). `model` is the
    /// loaded model id, exactly as the endpoint reports it. Runtime defaults to
    /// `goose` — the runtime that speaks local OpenAI-compatible endpoints.
    public static func forLocalModel(
        displayName: String,
        systemPrompt: String,
        providerBaseURL: String,
        model: String,
        provider: LocalProvider = .lmstudio,
        about: String? = nil,
        runtime: String = "goose",
        respondTo: String = "owner-only",
        parallelism: Int = 1,
        avatarDataUrl: String? = nil
    ) -> BuzzAgentSnapshot {
        _ = providerBaseURL  // carried by `environmentHints`, never by the manifest
        return BuzzAgentSnapshot(
            definition: Definition(
                name: displayName, systemPrompt: systemPrompt, runtime: runtime, model: model,
                provider: provider.providerID, parallelism: parallelism, respondTo: respondTo,
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
