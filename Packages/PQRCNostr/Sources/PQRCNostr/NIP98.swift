// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// NIP-98 HTTP Auth (kind:27235) — the stateless `Authorization: Nostr <base64>`
/// header Buzz's REST surface requires. It is the credential for the one call
/// that matters most to us: `POST /api/invites/claim`, which is *deliberately
/// exempt* from the relay-membership gate ("the whole point is that the caller
/// is not a member yet" — `buzz-relay/src/api/invites.rs`). NIP-98 is therefore
/// how an Eldr user joins a Buzz workspace at all.
///
/// Wire contract verified against Buzz's own verifier, `buzz-auth/src/nip98.rs`:
///
/// 1. `kind == 27235`
/// 2. a valid BIP-340 signature over the NIP-01 id
/// 3. `created_at` within ±60 s of *server* time
/// 4. a single-letter `["u", <url>]` tag — **not** `"url"` — compared after
///    normalisation (case-insensitive scheme/host, trailing slash stripped)
/// 5. a `["method", <verb>]` tag, compared case-insensitively
/// 6. an OPTIONAL `["payload", <sha256-hex>]` tag; when present *and* the server
///    has the body, `SHA-256(body)` must equal it — this is what stops body
///    substitution, so we always send it for requests that carry one
///
/// On (4): a URL differing only in case or a trailing slash still verifies, but
/// anything else — a different path, a dropped query string — does not. Sign the
/// exact URL you are about to request.
public enum NIP98 {
    /// NIP-98 HTTP Auth event kind.
    public static let kind = 27235

    /// Buzz's `TIMESTAMP_TOLERANCE_SECS`. Exposed so a caller can render an
    /// honest "your clock is off" diagnostic instead of a bare 403.
    public static let timestampToleranceSeconds: Int64 = 60

    /// Build the UNSIGNED kind-27235 event authorizing one request.
    ///
    /// `body` is hashed into a `payload` tag when non-empty. `createdAt` is
    /// injectable for deterministic tests; production passes nil (wall clock).
    /// Note this is a *freshness* clock, never a key-schedule input — SPEC §5.2
    /// bans clocks from key derivation, not from HTTP auth.
    public static func authorizationEvent(
        method: String, url: String, body: Data?, pubkeyHex: String, createdAt: Int64? = nil
    ) -> NostrEvent {
        var tags: [[String]] = [["u", url], ["method", method.uppercased()]]
        if let body, !body.isEmpty {
            tags.append(["payload", sha256(body).hexString])
        }
        return NostrEvent(
            pubkey: pubkeyHex, createdAt: createdAt ?? Int64(Date().timeIntervalSince1970),
            kind: kind, tags: tags, content: "")
    }

    /// The full `Authorization` header value: `Nostr <base64(signed event JSON)>`.
    public static func authorizationHeader(
        method: String, url: String, body: Data?, keypair: NostrKeypair,
        randomSource: any RandomSource, createdAt: Int64? = nil
    ) throws -> String {
        let unsigned = authorizationEvent(
            method: method, url: url, body: body, pubkeyHex: keypair.publicKeyHex,
            createdAt: createdAt)
        let signed = try keypair.sign(unsigned, randomSource: randomSource)
        let json = try WireJSON.encoder().encode(signed)
        return "Nostr " + json.base64EncodedString()
    }

    /// Decode a header value back to its event — the verification half, used by
    /// the conformance tests (and by any Eldr service that ever accepts NIP-98).
    public static func event(fromHeader header: String) -> NostrEvent? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 6, trimmed.prefix(6).lowercased() == "nostr " else { return nil }
        let encoded = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: encoded),
            let event = try? WireJSON.decoder().decode(NostrEvent.self, from: data)
        else { return nil }
        return event
    }

    /// Mirror of Buzz's `normalize_url`: lowercase scheme and host, strip a
    /// trailing slash. Best-effort — an unparseable string is returned unchanged
    /// so this can never be the thing that breaks a request.
    public static func normalizedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string ?? raw
    }
}
