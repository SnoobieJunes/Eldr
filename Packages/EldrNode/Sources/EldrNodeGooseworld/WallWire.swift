// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCMCP

// WS-G5 — the wall's WIRE shape on the admitted A2A town plane.
//
// A cross-town wall post travels as a JSON-RPC NOTIFICATION line (`world/wall.post`)
// over the same `A2A1|`-framed, gift-wrapped, Double-Ratcheted relay path the WS-G1
// delegation plane rides. One LOGICAL post = one `WallChunkRef.id` = one or more lines,
// each carrying one `WallChunking` piece; the receiver reassembles the complete set
// before its wall ingests anything (fail-closed on any incomplete/mixed set — exactly
// invariant 4's relay-chunking shape, `{id,index,total}`).
//
// The `method` prefix is what `PlaneRoutedTownService` routes on, so a wall line can
// only ever reach the wall service — and only for a sender holding a live `.wall`
// grant. Targets/priority ride as STRUCTURED fields on every chunk line (idempotent
// metadata; the reassembler reads them off the first chunk), never inside the body —
// the same forgery-refusing separation `WallPost` documents.
public enum WallWire {
    /// The one wall method this build sends. MUST keep the
    /// `PlaneRoutedTownService.wallMethodPrefix` prefix or plane routing breaks.
    public static let postMethod = "world/wall.post"

    /// The `params` of one `world/wall.post` line.
    public struct PostParams: Codable, Sendable, Equatable {
        /// Locates this piece within its logical post (invariant-4 shape).
        public let chunk: WallChunkRef
        /// One `WallChunking` piece of the post body (verbatim, hostile until enveloped).
        public let body: String
        /// The posting agent WITHIN the sender's town — the peer NODE's own namespace
        /// claim (their node stamps it, same as ours stamps ours). The town half of the
        /// author is NEVER taken from the wire: the receiver maps it from the VERIFIED
        /// sender identity, so a peer cannot post as another town no matter what it puts
        /// here.
        public let agent: String
        public let priorityForHuman: Bool
        public let targets: [String]

        public init(
            chunk: WallChunkRef, body: String, agent: String, priorityForHuman: Bool,
            targets: [String]
        ) {
            self.chunk = chunk
            self.body = body
            self.agent = agent
            self.priorityForHuman = priorityForHuman
            self.targets = targets
        }
    }

    private struct Envelope: Codable {
        let jsonrpc: String
        let method: String
        let params: PostParams
    }

    /// Encode one chunk line. Deterministic (sorted keys) so tests can compare bytes.
    public static func encodePost(_ params: PostParams) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard
            let data = try? encoder.encode(
                Envelope(jsonrpc: "2.0", method: postMethod, params: params))
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode one line iff it is a well-formed `world/wall.post` notification. Unknown
    /// sibling fields are ignored (forward compatibility, SPEC §12); a wrong method,
    /// non-JSON, or missing field returns nil — the caller drops the line (fail-closed,
    /// counted).
    public static func decodePost(_ line: String) -> PostParams? {
        guard let data = line.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.method == postMethod
        else { return nil }
        return envelope.params
    }
}
