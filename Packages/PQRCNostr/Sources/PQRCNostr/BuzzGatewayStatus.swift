// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The `eldr-buzz-agent` ↔ supervisor status vocabulary: ONE definition of the
/// machine-readable lines the gateway prints on stderr and Huginn's
/// `BuzzGatewayService` parses back out of the log it tails.
///
/// Why a shared type instead of scraping the human log: the GUI's status row
/// ("● connected — 4 replies · 1.2k tokens") is derived from these lines, and a
/// reworded log message must not silently zero the counters. The gateway emits
/// via `line`, the supervisor consumes via `parse`, and both sides are pinned by
/// `BuzzGatewayStatusTests` — so a change on either side fails a test rather than
/// a user's dashboard. Human-readable logging continues unchanged alongside it.
///
/// Wire form: `ELDR-BUZZ-STATUS {"kind":"…",…}` — one line, JSON after the
/// prefix, unknown kinds ignored by the parser (forward compatibility, SPEC §12).
public enum BuzzGatewayStatus: Equatable, Sendable {
    /// Process is up and about to dial; carries the identity it will present.
    case starting(relay: String, agentPubkey: String)
    /// NIP-42 AUTH accepted — the agent is a live member of the workspace.
    case connected(relay: String)
    /// Listening on `channels` for mentions of the agent.
    case listening(channels: Int)
    /// A reply was accepted by the relay.
    case reply(channel: String, characters: Int)
    /// Token usage observed for one turn (from the endpoint's own usage report).
    case tokens(turn: Int)
    /// A turn (or the connection) failed; `message` is already redaction-safe.
    case failed(message: String)

    public static let prefix = "ELDR-BUZZ-STATUS "

    // MARK: - Emit

    /// The single stderr line encoding this status.
    public var line: String {
        let object: [String: Any]
        switch self {
        case .starting(let relay, let agentPubkey):
            object = ["kind": "starting", "relay": relay, "agent": agentPubkey]
        case .connected(let relay):
            object = ["kind": "connected", "relay": relay]
        case .listening(let channels):
            object = ["kind": "listening", "channels": channels]
        case .reply(let channel, let characters):
            object = ["kind": "reply", "channel": channel, "characters": characters]
        case .tokens(let turn):
            object = ["kind": "tokens", "turn": turn]
        case .failed(let message):
            object = ["kind": "failed", "message": message]
        }
        let data =
            (try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parse

    /// Decode one log line. Returns nil for ordinary human log output, a line
    /// whose JSON doesn't parse, or an unknown `kind` (a newer gateway talking to
    /// an older supervisor must never crash or corrupt the counters).
    public static func parse(_ rawLine: String) -> BuzzGatewayStatus? {
        // The supervisor tails a file the child writes; a line may carry the
        // gateway's own "eldr-buzz-agent: " prefix or leading whitespace.
        guard let range = rawLine.range(of: prefix) else { return nil }
        let json = String(rawLine[range.upperBound...])
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["kind"] as? String
        else { return nil }
        switch kind {
        case "starting":
            return .starting(
                relay: object["relay"] as? String ?? "",
                agentPubkey: object["agent"] as? String ?? "")
        case "connected":
            return .connected(relay: object["relay"] as? String ?? "")
        case "listening":
            return .listening(channels: object["channels"] as? Int ?? 0)
        case "reply":
            return .reply(
                channel: object["channel"] as? String ?? "",
                characters: object["characters"] as? Int ?? 0)
        case "tokens":
            return .tokens(turn: object["turn"] as? Int ?? 0)
        case "failed":
            return .failed(message: object["message"] as? String ?? "")
        default:
            return nil
        }
    }
}

/// Running totals a supervisor keeps for one gateway child, folded from the
/// status lines above. Pure and value-typed so the GUI's counters are unit
/// tested without a process, a socket, or a clock.
public struct BuzzGatewayCounters: Equatable, Sendable {
    public var replies = 0
    public var tokens = 0
    public var agentPubkey = ""
    public var channelsListening = 0
    /// True once AUTH succeeded — the honest "connected" light, distinct from
    /// "the process is running".
    public var authenticated = false
    /// Last failure the gateway reported, if any (cleared by a later success).
    public var lastFailure: String?

    public init() {}

    /// Fold one status into the counters. Unknown/ordinary lines are no-ops, so a
    /// caller can hand it every log line it sees.
    public mutating func ingest(line: String) {
        guard let status = BuzzGatewayStatus.parse(line) else { return }
        ingest(status)
    }

    public mutating func ingest(_ status: BuzzGatewayStatus) {
        switch status {
        case .starting(_, let agentPubkey):
            self.agentPubkey = agentPubkey
        case .connected:
            authenticated = true
            lastFailure = nil
        case .listening(let channels):
            channelsListening = channels
        case .reply(_, let characters):
            replies += 1
            _ = characters
            lastFailure = nil
        case .tokens(let turn):
            tokens += max(0, turn)
        case .failed(let message):
            lastFailure = message
        }
    }
}
