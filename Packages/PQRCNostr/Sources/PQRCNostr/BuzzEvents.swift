// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// Builders for the Buzz (Block) event kinds an Eldr-hosted agent needs to join
/// a Buzz workspace as a first-class member and speak its agent-plane NIPs.
///
/// All builders return an UNSIGNED `NostrEvent` (id computed, empty sig); the
/// caller signs with the agent keypair. Tag layouts mirror `buzz-sdk`'s
/// builders exactly (verified against `crates/buzz-sdk/src/builders.rs` and the
/// NIP-AM / NIP-AO drafts) so a Buzz relay accepts them unchanged.
public enum BuzzEvents {
    // Buzz kind registry (subset Eldr emits). See buzz-core/src/kind.rs.
    public enum Kind {
        public static let profile = 0  // NIP-01 kind:0 metadata
        public static let streamMessage = 9  // NIP-29 group chat message
        public static let agentProfile = 10100  // agent metadata + owner ref
        public static let putUser = 9000  // NIP-29 add-user (self-announce as bot)
        public static let observerFrame = 24200  // NIP-AO ephemeral telemetry/control
        public static let turnMetric = 44200  // NIP-AM durable per-turn usage
    }

    // MARK: - kind:0 profile

    /// Build a kind:0 profile. Content is a JSON object with the standard Buzz
    /// fields (`display_name`, `name`, `about`, `picture`), omitting nil values.
    public static func profile(
        pubkey: String, displayName: String?, name: String?, about: String?, picture: String? = nil
    ) -> NostrEvent {
        var map: [String: String] = [:]
        if let displayName { map["display_name"] = displayName }
        if let name { map["name"] = name }
        if let about { map["about"] = about }
        if let picture { map["picture"] = picture }
        let content = jsonObject(map)
        return NostrEvent(pubkey: pubkey, createdAt: now(), kind: Kind.profile, tags: [], content: content)
    }

    // MARK: - kind:9 stream message (a channel reply / post)

    /// Build a kind:9 channel message. `channelId` is the workspace channel
    /// UUID (the `h` tag). `mentions` become `p` tags (deduped, lowercased).
    /// When `replyToEventId` is set, the NIP-10 `e` reply tags are added
    /// (direct reply if `rootEventId` equals it, nested otherwise).
    public static func streamMessage(
        pubkey: String, channelId: String, content: String, mentions: [String] = [],
        replyToEventId: String? = nil, rootEventId: String? = nil,
        createdAt: Int64? = nil
    ) -> NostrEvent {
        var tags: [[String]] = [["h", channelId]]
        if let replyTo = replyToEventId {
            let root = rootEventId ?? replyTo
            if root == replyTo {
                tags.append(["e", root, "", "reply"])
            } else {
                tags.append(["e", root, "", "root"])
                tags.append(["e", replyTo, "", "reply"])
            }
        }
        var seen = Set<String>()
        for m in mentions {
            let lower = m.lowercased()
            if seen.insert(lower).inserted { tags.append(["p", lower]) }
        }
        return NostrEvent(
            pubkey: pubkey, createdAt: createdAt ?? now(), kind: Kind.streamMessage, tags: tags,
            content: content)
    }

    // MARK: - kind:9000 self-announce as a channel bot member

    /// Announce this agent as a channel member (`role=bot`). On open relays this
    /// self-adds; on closed channels an admin must have added the pubkey (the
    /// relay rejects otherwise — the caller treats a rejection as non-fatal, as
    /// the countdown-bot reference does).
    public static func membershipAnnounce(pubkey: String, channelId: String) -> NostrEvent {
        NostrEvent(
            pubkey: pubkey, createdAt: now(), kind: Kind.putUser,
            tags: [["h", channelId], ["p", pubkey], ["role", "bot"]], content: "")
    }

    // MARK: - kind:10100 agent profile (owner reference) — additive provenance

    /// Build a kind:10100 agent profile carrying an owner `p` reference. This is
    /// additive metadata (Buzz tracks the agent via kind:0 + NIP-OA); it is
    /// published best-effort and a rejection is non-fatal.
    public static func agentProfile(
        pubkey: String, ownerPubkeyHex: String, displayName: String?, about: String?
    ) -> NostrEvent {
        var map: [String: String] = ["owner": ownerPubkeyHex]
        if let displayName { map["display_name"] = displayName }
        if let about { map["about"] = about }
        return NostrEvent(
            pubkey: pubkey, createdAt: now(), kind: Kind.agentProfile,
            tags: [["p", ownerPubkeyHex]], content: jsonObject(map))
    }

    // MARK: - NIP-AM kind:44200 agent turn metric (encrypted to owner)

    /// Build a kind:44200 turn metric: NIP-44 encrypt the payload with
    /// `(agentPrivateKey, ownerPubkey)`, tag exactly one `p` (owner) and one
    /// `agent` (== pubkey), no `h` tag. Returns unsigned (caller signs).
    public static func turnMetric(
        agentPrivateKey: Data, agentPubkeyHex: String, ownerPubkeyHex: String,
        payload: AgentTurnMetricPayload, randomSource: any RandomSource
    ) throws -> NostrEvent {
        let json = try payload.jsonString()
        let content = try NIP44.encrypt(
            plaintext: json, senderPrivateKey: agentPrivateKey,
            recipientPublicKeyHex: ownerPubkeyHex, randomSource: randomSource)
        return NostrEvent(
            pubkey: agentPubkeyHex, createdAt: now(), kind: Kind.turnMetric,
            tags: [["p", ownerPubkeyHex], ["agent", agentPubkeyHex]], content: content)
    }

    // MARK: - NIP-AO kind:24200 observer frame (encrypted telemetry, ephemeral)

    /// Build a kind:24200 telemetry observer frame (agent → owner). NIP-44
    /// encrypt with `(agentPrivateKey, ownerPubkey)`; tags `p`=owner,
    /// `agent`=agent, `frame`=telemetry. Optional `h` channel tag when the turn
    /// runs within a channel context. Returns unsigned (caller signs).
    public static func observerTelemetryFrame(
        agentPrivateKey: Data, agentPubkeyHex: String, ownerPubkeyHex: String,
        event: ObserverEvent, channelId: String? = nil, randomSource: any RandomSource
    ) throws -> NostrEvent {
        let json = try event.jsonString()
        let content = try NIP44.encrypt(
            plaintext: json, senderPrivateKey: agentPrivateKey,
            recipientPublicKeyHex: ownerPubkeyHex, randomSource: randomSource)
        var tags: [[String]] = [
            ["p", ownerPubkeyHex], ["agent", agentPubkeyHex], ["frame", "telemetry"],
        ]
        if let channelId { tags.append(["h", channelId]) }
        return NostrEvent(
            pubkey: agentPubkeyHex, createdAt: now(), kind: Kind.observerFrame, tags: tags,
            content: content)
    }

    // MARK: - Helpers

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    /// Deterministic-key-order JSON object of string values (sorted keys).
    static func jsonObject(_ map: [String: String]) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: map, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - NIP-AM payload (docs/nips/NIP-AM.md §Decrypted Payload)

/// Token usage for a turn or session (all fields nullable — a null MUST NOT be
/// summed as zero).
public struct TokenCounts: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var costUsd: Double?
    public init(
        inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil,
        costUsd: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.costUsd = costUsd
    }
}

/// Decrypted payload of a kind:44200 Agent Turn Metric. `harness` and
/// `timestamp` are REQUIRED; `sessionId`/`turnSeq` REQUIRED when `cumulative`
/// is present. camelCase JSON matches Buzz's `AgentTurnMetricPayload`.
public struct AgentTurnMetricPayload: Codable, Equatable, Sendable {
    public var harness: String
    public var model: String?
    public var channelId: String?
    public var sessionId: String?
    public var turnId: String?
    public var turnSeq: Int?
    public var timestamp: String
    public var turn: TokenCounts?
    public var cumulative: TokenCounts?
    public var deltaReliable: Bool
    public var stopReason: String?

    public init(
        harness: String, timestamp: String, model: String? = nil, channelId: String? = nil,
        sessionId: String? = nil, turnId: String? = nil, turnSeq: Int? = nil,
        turn: TokenCounts? = nil, cumulative: TokenCounts? = nil, deltaReliable: Bool = true,
        stopReason: String? = nil
    ) {
        self.harness = harness
        self.timestamp = timestamp
        self.model = model
        self.channelId = channelId
        self.sessionId = sessionId
        self.turnId = turnId
        self.turnSeq = turnSeq
        self.turn = turn
        self.cumulative = cumulative
        self.deltaReliable = deltaReliable
        self.stopReason = stopReason
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func parse(_ json: String) throws -> AgentTurnMetricPayload {
        try JSONDecoder().decode(AgentTurnMetricPayload.self, from: Data(json.utf8))
    }
}

// MARK: - NIP-AO ObserverEvent (docs/nips/NIP-AO.md §Decrypted Payload)

/// A single NIP-AO telemetry frame body. `seq`, `timestamp`, `kind`, and
/// `payload` are REQUIRED; the rest MAY be null before they are known.
public struct ObserverEvent: Codable, Equatable, Sendable {
    public var seq: Int
    public var timestamp: String
    public var kind: String  // acp_read | acp_write | turn_started | session_resolved
    public var agentIndex: Int?
    public var channelId: String?
    public var sessionId: String?
    public var turnId: String?
    public var payload: [String: String]

    public init(
        seq: Int, timestamp: String, kind: String, agentIndex: Int? = nil, channelId: String? = nil,
        sessionId: String? = nil, turnId: String? = nil, payload: [String: String] = [:]
    ) {
        self.seq = seq
        self.timestamp = timestamp
        self.kind = kind
        self.agentIndex = agentIndex
        self.channelId = channelId
        self.sessionId = sessionId
        self.turnId = turnId
        self.payload = payload
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
