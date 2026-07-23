// SPDX-License-Identifier: Apache-2.0
import Foundation

// WS-G1 (private/GOOSEWORLD.md §6) — the authorization seam for the **A2A town plane**.
//
// ## Why this exists at all (read before touching `serve`)
//
// `EldrNodeCore.serve`'s C-3 gate admits an inbound frame only when its sender is the
// pinned `ownerIdentityHex`. That is exactly right for the two planes it was written for:
// the owner drives the coding agent (`ACP1|`), and the owner's phone answers the node's
// chat-tool queries (`MCP1|`). In both, "not the owner" means "confused-deputy attempt",
// so a bare identity comparison is the whole policy.
//
// The A2A town plane inverts that premise. A cross-town delegation arrives FROM A PEER
// TOWN — a different human's node, which is a **non-owner by definition**. Reusing the
// owner check would make the plane permanently dead; widening the owner check to admit
// non-owners would hand every stranger on the relay the ACP/MCP planes too, which is the
// single worst thing that could happen to this daemon (GOOSEWORLD §4 adversary class 1:
// the A2A plane is code-execution-adjacent, so its inputs are untrusted remote input
// flowing toward an orchestrator that spawns shells).
//
// So the A2A plane gets its OWN authorizer, and C-3 is left untouched. Two gates, two
// policies, no shared knob to loosen by accident.
//
// ## Deny-all is the default, and that is load-bearing
//
// `serve`'s `townAuthorizer` parameter defaults to `DenyAllTownAuthorizer`, so a node
// with no town configuration behaves byte-identically to the pre-WS-G1 daemon: no A2A
// frame is admitted, no transport is allocated, nothing new is reachable. Turning the
// plane on is a deliberate act by the operator, never a side effect of upgrading.
//
// ## Where WS-G4's standing grants plug in
//
// GOOSEWORLD §5's `standing_grant` — the human-identity-signed, day-scale, scoped,
// revocable grant that replaces "widen a gate per surface" — is being built concurrently
// in `PQRCCore`/`PQRCAgent`. When it lands it becomes ANOTHER `TownAuthorizer`
// conformance (`StandingGrantTownAuthorizer`, or similar) that answers `authorizes` from
// the live grant set instead of a static pin: same seam, same call site, no change to
// `serve`. Nothing in this file imports or references that type — it does not exist here
// yet, and guessing at its shape would be scaffolding pretending to be integration. The
// per-frame consultation below (see `authorizes`) is what makes revocation work when it
// arrives: the answer is re-asked for EVERY frame, so a revoked peer stops being admitted
// on the very next chunk, mid-stream, with no cache to invalidate.
//
// ## What this seam is NOT, stated plainly
//
// `PinnedTownAllowlist` is **operator-side configuration, not a human-signed grant.** SPEC
// §13 / CLAUDE.md invariant 9 require that an agent's autonomous sends be authorized by
// something signed with the HUMAN identity key, time-bounded, and rendered as a visible
// indicator in every client. A pin in a config file is none of those things. It is
// adequate for exactly what ships today — a transport-level admission check on a plane
// that is off by default and has no service behind it in-tree — and it is deliberately
// NOT presented as satisfying §13. GOOSEWORLD §5 is explicit that widening gates ad hoc
// per surface is how invariant 9 erodes; the answer is `standing_grant` (WS-G4), and this
// protocol exists so that answer lands as a new conformance rather than as a diff to the
// gate. Until it does, nothing in this repo should describe the town plane as §13-compliant.
//
// Invariant 8 is likewise unaffected: `A2A1|` is a pairwise CONTROL channel, exactly like
// `ACP1|`/`MCP1|`, and carries no chat authorship. Anything a town interaction later
// causes to be RENDERED in a conversation is agent-authored and must be labeled
// `participant_type: "agent"` by whatever surfaces it — this seam neither knows about nor
// weakens that rule.

/// Decides whether a peer town may reach this node's **A2A plane**. Consulted per inbound
/// A2A frame — never cached — so a revocation takes effect on the next frame rather than
/// at some session boundary.
///
/// The single method is deliberately narrow: it answers ONLY "may this identity speak A2A
/// to us", not "what may they do once admitted". Everything a delegated task then triggers
/// stays behind the unchanged fail-closed permission gate (C-1) and the path jail (C-2) —
/// authorization here is admission to the channel, never a tool-scope grant.
///
/// `async` because the eventual grant-backed implementation must be able to consult
/// actor-isolated state (an expiring, revocable grant set); the pinned implementations
/// below answer synchronously and pay nothing for it.
public protocol TownAuthorizer: Sendable {
    /// - Parameter peerIdentityHex: the sender's VERIFIED PQRC identity hex, as resolved by
    ///   the messenger's 10420/10421 binding check (invariant 7) — not a self-asserted
    ///   value from the frame. Canonically lowercase (`Data.hexString` formats `%02x`).
    /// - Returns: `true` iff this peer may have its A2A frames delivered. Implementations
    ///   MUST return `false` on any doubt: an unknown peer, an empty/malformed hex, an
    ///   expired grant, or an error consulting whatever backs the decision.
    func authorizes(peerIdentityHex: String) async -> Bool
}

/// The default: **nobody**. A node that has not been given a town configuration answers
/// no A2A frames at all, which is what makes the WS-G1 wiring a no-op on every existing
/// deployment. Also the correct fallback whenever a richer authorizer cannot be
/// constructed — never fall back to "allow".
public struct DenyAllTownAuthorizer: TownAuthorizer {
    public init() {}
    public func authorizes(peerIdentityHex: String) async -> Bool { false }
}

/// A static, operator-pinned allowlist of peer-town identities — v1 pairing is
/// invite-based and there is no public town directory (GOOSEWORLD §2), so an explicit pin
/// is the whole trust model until WS-G4's signed grants exist.
///
/// **Matching is exact and case-sensitive, on purpose.** PQRC identity hex is canonically
/// lowercase (`Data.hexString` uses `%02x`), and the C-3 gate next door compares with `==`
/// and nothing else. Rather than quietly case-fold — which would mean this gate accepts a
/// spelling the C-3 gate would reject, i.e. two subtly different notions of "same peer" in
/// one file — entries that are not already canonical lowercase hex are **dropped at
/// construction** and an inbound hex that differs only in case is **denied**. Both
/// directions of the mismatch therefore fail closed, and `peerIdentityHexes` lets an
/// operator (or a test) see exactly which entries survived, so a typo shows up as a
/// missing peer rather than as a silently-lenient comparison.
public struct PinnedTownAllowlist: TownAuthorizer {
    /// The entries that survived canonicalization — the effective allowlist. Exposed so a
    /// caller can assert "the peer I configured is actually in here" instead of trusting
    /// that its input was well-formed.
    public let peerIdentityHexes: Set<String>

    /// - Parameter peerIdentityHexes: pinned peer-town identity hexes. Entries are trimmed
    ///   of surrounding whitespace (config files and QR scans bring their own newlines);
    ///   anything that is not then a non-empty, all-lowercase hex string is DISCARDED.
    ///   Duplicates collapse. An empty (or entirely-discarded) list authorizes no one,
    ///   which is the same posture as `DenyAllTownAuthorizer`.
    public init(peerIdentityHexes: some Sequence<String>) {
        self.peerIdentityHexes = Set(peerIdentityHexes.compactMap(Self.canonicalized))
    }

    public func authorizes(peerIdentityHex: String) async -> Bool {
        // The inbound hex is NOT trimmed or folded: it comes from the messenger's verified
        // binding, so it is already canonical. Normalizing it here would only create a way
        // for a non-canonical spelling to match, which is the failure this type refuses.
        guard !peerIdentityHex.isEmpty else { return false }
        return peerIdentityHexes.contains(peerIdentityHex)
    }

    /// Trim, then accept only a non-empty all-lowercase-hex string. Returns nil for
    /// anything else (empty, uppercase, `0x`-prefixed, an npub, a comment line…).
    static func canonicalized(_ hex: String) -> String? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else { return nil }
        return trimmed
    }
}

/// Services one inbound A2A JSON-RPC line from an **authorized** peer town, and may write
/// zero or more lines back to that same peer.
///
/// This is the second half of the WS-G1 seam, and it is deliberately separate from
/// `TownAuthorizer`: authorization says *who may speak*, this says *what listens*. A node
/// with no service injected has no A2A plane at all — `serve` will not even allocate a
/// transport for a peer, so an authorized-but-unserviced node is inert rather than quietly
/// buffering an unread stream. The two switches default off independently, and BOTH must
/// be thrown for a single A2A frame to be acted on.
///
/// **Everything handed to `handle` is untrusted remote input** (GOOSEWORLD §4 class 1). An
/// implementation must treat `line` as quarantined DATA — never interpolate it into an
/// instruction context — and anything it goes on to execute stays behind the unchanged
/// C-1 permission gate and C-2 path jail. This protocol grants no tool scope by existing.
public protocol TownA2AService: Sendable {
    /// - Parameters:
    ///   - line: one complete, reassembled A2A JSON-RPC line (request or notification).
    ///   - peerIdentityHex: the verified sender — the same value the authorizer approved.
    ///   - reply: writes one A2A JSON-RPC line back to THAT peer (framed, chunked, and
    ///     ratcheted by the transport). Safe to call zero, one, or many times — streaming
    ///     notifications followed by a terminal response are the expected shape, and the
    ///     transport preserves the order in which `reply` was called.
    func handle(
        line: String,
        from peerIdentityHex: String,
        reply: @escaping @Sendable (String) -> Void
    ) async
}
