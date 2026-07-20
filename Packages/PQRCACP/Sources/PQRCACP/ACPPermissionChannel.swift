// SPDX-License-Identifier: Apache-2.0
import Foundation

// A1 (tech-week) — the node→phone PERMISSION channel for the chat-bridge path.
//
// The watch-along / My-AI chat bridge (Huginn's `ACPDriverAgentRunner`) spawns
// `eldr-acp` with no interactive client of its own, so until now it hard-denied
// every mutating tool (the CR-1 read-only stance). A1 supersedes that: a mutating
// tool call in the My-AI chat is routed to the OWNER'S PHONE for an explicit
// Allow / Always / Deny — the same `PersonaRuntime.decidePermission` prompt the
// phone-driven coding-agent path uses.
//
// This file is the tiny wire codec both ends share. One permission round-trip is
// two messages riding the EXISTING gift-wrapped + Double-Ratcheted mesh (no new
// crypto, SPEC §2; the relay sees only the same E2EE ciphertext as chat):
//
//   node  → phone   ACPPERM1|<b64url {"v":1,"t":"req","id","title","kind"}>
//   phone → node    ACPPERM1|<b64url {"v":1,"t":"res","id","allowed"}>
//
// Deliberately NOT the `ACP1|` session framing: a bridge turn has no phone-driven
// ACP session (the phone is a chat peer there, not an ACP client), and reusing the
// session stream would entangle this with driver lifecycle + line reordering. The
// payload is one self-contained JSON object per message — small by construction
// (`maxTitleLength`), so it always fits a single relay event and needs no chunking.
//
// Fail-closed by design at every seam:
// - The node treats no answer (timeout), a malformed frame, or an unpaired owner
//   as a DENIAL (C-1 semantics unchanged).
// - The phone services requests ONLY from a paired `coding_agent` contact, and the
//   decision still runs through `decidePermission` (standing consent or a human
//   card; no asker ⇒ deny).
// - Frames are recognized by prefix, always swallowed by the routing layers, and
//   never rendered as chat. `ACPPERM1|` cannot collide with `ACP1|` / `MCP1|`
//   (different prefixes) nor with JSON-RPC lines (those start with `{`).
public enum ACPPermissionChannel {

    /// Fixed magic prefix (with delimiter), mirroring `RelayACPTransport.magic`'s
    /// shape so routing layers can prefix-test cheaply and unambiguously.
    public static let magic = "ACPPERM1|"

    /// Cap on the human-readable title carried in a request. Keeps the whole frame
    /// far below any relay event budget (single message, never chunked) and bounds
    /// what the approval card must render. Titles are already short by construction
    /// (`ToolExecutor.title(for:args:)`), this is a hard backstop.
    public static let maxTitleLength = 300

    /// A node's ask: "may the agent run this mutating tool?" `id` is minted by the
    /// node and echoed in the response; `title`/`kind` feed the phone's approval
    /// card exactly like a phone-driven `session/request_permission` would.
    public struct Request: Sendable, Equatable {
        public let id: String
        public let title: String
        public let kind: String
        public init(id: String, title: String, kind: String) {
            self.id = id
            self.title = title
            self.kind = kind
        }
    }

    /// The phone's answer. `allowed` folds allow-once and allow-always to one bit —
    /// "always" is persisted PHONE-side (standing consent), the node never learns
    /// which; it just gets this call's verdict.
    public struct Response: Sendable, Equatable {
        public let id: String
        public let allowed: Bool
        public init(id: String, allowed: Bool) {
            self.id = id
            self.allowed = allowed
        }
    }

    /// True iff `body` is a permission-channel frame (either direction).
    public static func isFrame(_ body: String) -> Bool {
        body.hasPrefix(magic)
    }

    /// Encode a request frame. The title is truncated to `maxTitleLength` so the
    /// frame is always a single relay message.
    public static func requestFrame(id: String, title: String, kind: String) -> String {
        let boundedTitle = String(title.prefix(maxTitleLength))
        let payload: JSONValue = .object([
            "v": .int(1),
            "t": .string("req"),
            "id": .string(id),
            "title": .string(boundedTitle),
            "kind": .string(kind),
        ])
        return magic + base64URL(payload.serialized())
    }

    /// Encode a response frame.
    public static func responseFrame(id: String, allowed: Bool) -> String {
        let payload: JSONValue = .object([
            "v": .int(1),
            "t": .string("res"),
            "id": .string(id),
            "allowed": .bool(allowed),
        ])
        return magic + base64URL(payload.serialized())
    }

    /// Decode a request frame; nil for anything malformed, non-request, or from a
    /// future incompatible version (forward-compat: v stays 1 for this shape).
    public static func parseRequest(_ body: String) -> Request? {
        guard let payload = decodePayload(body),
            payload["t"]?.stringValue == "req",
            let id = payload["id"]?.stringValue, !id.isEmpty,
            let title = payload["title"]?.stringValue,
            let kind = payload["kind"]?.stringValue
        else { return nil }
        return Request(id: id, title: String(title.prefix(maxTitleLength)), kind: kind)
    }

    /// Decode a response frame; nil for anything malformed or non-response. A
    /// missing/absent `allowed` is NOT defaulted — the frame is rejected, and the
    /// node's timeout then denies (fail closed, never fail open).
    public static func parseResponse(_ body: String) -> Response? {
        guard let payload = decodePayload(body),
            payload["t"]?.stringValue == "res",
            let id = payload["id"]?.stringValue, !id.isEmpty,
            let allowed = payload["allowed"]?.boolValue
        else { return nil }
        return Response(id: id, allowed: allowed)
    }

    // MARK: - Payload plumbing

    private static func decodePayload(_ body: String) -> JSONValue? {
        guard body.hasPrefix(magic) else { return nil }
        let encoded = String(body.dropFirst(magic.count))
        guard let data = base64URLDecode(encoded),
            let json = JSONValue.parse(String(decoding: data, as: UTF8.self))
        else { return nil }
        return json
    }

    /// base64url (RFC 4648 §5, no padding) — the same alphabet the relay framings
    /// use, so a frame never contains a delimiter or JSON-hostile byte.
    private static func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ encoded: String) -> Data? {
        var standard =
            encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }
}
