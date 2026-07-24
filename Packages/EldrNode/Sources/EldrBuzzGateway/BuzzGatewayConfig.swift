// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr

/// Configuration for an `eldr-buzz-agent` gateway: the identity, relay, channels,
/// persona, and which agent-plane NIPs to emit.
///
/// **E2EE-termination note (INTEROP-LANDSCAPE §8.1).** A Buzz channel is
/// signed-not-E2EE plaintext. This gateway is an EDGE bridge: content it posts
/// to a Buzz relay is readable by that relay's operator. It MUST be run by the
/// workspace owner, never a third party, and the disclosure is surfaced at
/// startup (`disclosureBanner`). This is inherent to bridging two crypto
/// regimes, not a defect — see DEVIATIONS `[app-only]` Buzz gateway.
public struct BuzzGatewayConfig: Sendable {
    /// Buzz relay WebSocket URL (`ws://` / `wss://`).
    public var relayURL: URL
    /// Workspace channel UUIDs the agent joins and listens on.
    public var channelIds: [String]
    /// kind:0 display name (also the `@mention` trigger name).
    public var displayName: String
    /// kind:0 about text.
    public var about: String
    /// System prompt / persona for the local model.
    public var systemPrompt: String
    /// Owner pubkey (hex, x-only). Required to emit NIP-AM / NIP-AO (they are
    /// encrypted to the owner). When nil, telemetry emission is skipped.
    public var ownerPubkeyHex: String?
    /// NIP-OA auth tag JSON (`["auth", owner, conditions, sig]`) proving owner
    /// attestation to the relay's membership gate. nil ⇒ standalone auth (the
    /// agent key must itself be a relay member).
    public var authTagJSON: String?
    /// Only reply when the agent is @mentioned (p-tag or display name). Default
    /// true — a bot that answers every message is a nuisance.
    public var respondToMentionsOnly: Bool
    /// Emit a NIP-AM kind:44200 turn metric after each reply (needs owner + real
    /// token usage from the endpoint).
    public var emitTurnMetrics: Bool
    /// Emit NIP-AO kind:24200 observer frames (turn_started / session_resolved).
    public var emitObserverFrames: Bool
    /// Self-announce as a channel bot member (kind:9000) on join.
    public var announceMembership: Bool
    /// Max prior messages kept as per-channel context for the model.
    public var historyWindow: Int
    /// Model id recorded in NIP-AM payloads.
    public var model: String
    /// Harness identifier recorded in NIP-AM payloads.
    public var harnessName: String

    public init(
        relayURL: URL, channelIds: [String], displayName: String, about: String,
        systemPrompt: String, ownerPubkeyHex: String? = nil, authTagJSON: String? = nil,
        respondToMentionsOnly: Bool = true, emitTurnMetrics: Bool = true,
        emitObserverFrames: Bool = true, announceMembership: Bool = true, historyWindow: Int = 12,
        model: String = "local-model", harnessName: String = "eldr-buzz-agent"
    ) {
        self.relayURL = relayURL
        self.channelIds = channelIds
        self.displayName = displayName
        self.about = about
        self.systemPrompt = systemPrompt
        self.ownerPubkeyHex = ownerPubkeyHex
        self.authTagJSON = authTagJSON
        self.respondToMentionsOnly = respondToMentionsOnly
        self.emitTurnMetrics = emitTurnMetrics
        self.emitObserverFrames = emitObserverFrames
        self.announceMembership = announceMembership
        self.historyWindow = historyWindow
        self.model = model
        self.harnessName = harnessName
    }

    /// One-line startup disclosure surfaced to the operator (INTEROP §8.1).
    public var disclosureBanner: String {
        "⚠️  E2EE terminates here: messages this gateway posts to \(relayURL.absoluteString) "
            + "are readable by that relay's operator. Run this ONLY as the workspace owner."
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case missing(String)
        case badRelayURL(String)
        case badKey(String)

        public var description: String {
            switch self {
            case .missing(let k): return "missing required env var \(k)"
            case .badRelayURL(let u): return "invalid BUZZ_RELAY_URL: \(u)"
            case .badKey(let m): return "invalid key: \(m)"
            }
        }
    }

    /// Parse config + agent keypair from environment. Env vars mirror `buzz-acp`
    /// (`BUZZ_RELAY_URL`, `BUZZ_PRIVATE_KEY`, `BUZZ_AUTH_TAG`) plus Eldr-specific
    /// options (`ELDR_BUZZ_*`). Returns the parsed config and the agent keypair.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (BuzzGatewayConfig, NostrKeypair) {
        func req(_ k: String) throws -> String {
            guard let v = env[k], !v.isEmpty else { throw ConfigError.missing(k) }
            return v
        }
        let relayString = env["BUZZ_RELAY_URL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "ws://localhost:3000"
        guard let relayURL = URL(string: relayString) else {
            throw ConfigError.badRelayURL(relayString)
        }

        // Agent key: hex or nsec (BUZZ_PRIVATE_KEY, matching buzz-acp).
        let keyString = try req("BUZZ_PRIVATE_KEY")
        let keypair = try Self.parseKey(keyString)

        // Owner: explicit hex, or derived from an owner private key (local demo
        // where we hold both keys), or nil.
        var ownerHex = env["ELDR_BUZZ_OWNER_PUBKEY"].flatMap { $0.isEmpty ? nil : $0 }
        var authTag = env["BUZZ_AUTH_TAG"].flatMap { $0.isEmpty ? nil : $0 }
        if let ownerKeyString = env["ELDR_BUZZ_OWNER_PRIVATE_KEY"], !ownerKeyString.isEmpty {
            let ownerKey = try Self.parseKey(ownerKeyString)
            ownerHex = ownerHex ?? ownerKey.publicKeyHex
            // Compute a NIP-OA auth tag if one wasn't supplied.
            if authTag == nil {
                let conditions = env["ELDR_BUZZ_OA_CONDITIONS"] ?? ""
                authTag = try NIPOA.computeAuthTag(
                    ownerPrivateKey: ownerKey.privateKeyData, agentPublicKeyHex: keypair.publicKeyHex,
                    conditions: conditions, randomSource: SystemRandomSource())
            }
        }

        let channels = (env["ELDR_BUZZ_CHANNELS"] ?? env["BUZZ_CHANNEL_ID"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let config = BuzzGatewayConfig(
            relayURL: relayURL,
            channelIds: channels,
            displayName: env["ELDR_BUZZ_DISPLAY_NAME"] ?? "Eldr",
            about: env["ELDR_BUZZ_ABOUT"]
                ?? "A local, on-device AI hosted by Eldr/Huginn, bridged into Buzz.",
            systemPrompt: env["ELDR_BUZZ_SYSTEM_PROMPT"]
                ?? "You are a helpful AI participating in a Buzz workspace channel. "
                    + "You are hosted locally on the owner's own machine via Eldr/Huginn. "
                    + "Keep replies concise and useful.",
            ownerPubkeyHex: ownerHex,
            authTagJSON: authTag,
            respondToMentionsOnly: env["ELDR_BUZZ_MENTIONS_ONLY"] != "0",
            emitTurnMetrics: env["ELDR_BUZZ_EMIT_METRICS"] != "0",
            emitObserverFrames: env["ELDR_BUZZ_EMIT_OBSERVER"] != "0",
            announceMembership: env["ELDR_BUZZ_ANNOUNCE_MEMBERSHIP"] != "0",
            historyWindow: env["ELDR_BUZZ_HISTORY"].flatMap { Int($0) } ?? 12,
            model: env["ELDR_LLM_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "local-model",
            harnessName: "eldr-buzz-agent")
        return (config, keypair)
    }

    /// Parse a hex or bech32 `nsec` private key into a `NostrKeypair`.
    public static func parseKey(_ s: String) throws -> NostrKeypair {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("nsec1") {
            guard let (hrp, data) = Bech32.decode(trimmed), hrp == "nsec", data.count == 32,
                let kp = try? NostrKeypair(privateKey: data)
            else { throw ConfigError.badKey("nsec did not decode to a 32-byte key") }
            return kp
        }
        guard let data = Data(hexString: trimmed), data.count == 32,
            let kp = try? NostrKeypair(privateKey: data)
        else { throw ConfigError.badKey("expected 64 hex chars or an nsec1… string") }
        return kp
    }
}
