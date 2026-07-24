// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

// WS-G4 → WS-G1 integration (private/GOOSEWORLD.md §5, §6). This is the conformance
// `TownAuthorizer.swift` promised but deliberately could not write while the grant type was
// being built concurrently: a `TownAuthorizer` whose answer comes from the live set of
// human-signed `standing_grant`s (PQRCCore) rather than a static operator pin
// (`PinnedTownAllowlist`). Same seam, same call site in `serve`, no change to the gate —
// exactly the "lands as a new conformance, not a diff to the gate" property that file
// argued for.
//
// ## What makes THIS one §13-shaped where the pin is not
//
// `PinnedTownAllowlist` is config: adequate as a transport admission check, but not
// human-signed, not time-bounded, not visible — so `TownAuthorizer.swift` is careful to say
// it does NOT satisfy SPEC §13 / invariant 9. A `StandingGrant` is the opposite on all three
// counts (GOOSEWORLD §5): signed by the owner's HUMAN identity key, bounded in days with an
// explicit expiry, and surfaced to every client as an indicator for its lifetime (the engine
// exposes `activeStandingGrants()` for exactly that). So gating the town plane on a live
// grant is what lets the plane be authorized the way §13 requires, instead of by a pin that
// merely resembles authorization.
//
// This type does NOT re-implement the grant's meaning; it consumes the already-validated
// `StandingGrant` value type and re-checks the three properties that can lapse between
// issuance and this inbound frame — expiry, the owner's signature, and plane coverage —
// because a `TownAuthorizer` must fail closed on any doubt (that protocol's contract) and an
// authorizer handed a raw grant set cannot assume someone else already checked. Budgets and
// the concurrent-task ceiling are NOT enforced here: this seam answers only "may this peer
// speak A2A to us at all", the same narrow question `PinnedTownAllowlist` answers. Per-send
// byte budgets and task limits are the sending side's gate (`AgentEngine.authorizeTownSend` /
// `beginTownTask`, PQRCAgent), enforced where the send actually happens — admission to the
// channel is not a budget grant, precisely as `TownAuthorizer`'s doc comment states.

/// A `TownAuthorizer` backed by the live set of human-signed standing grants. Admits a peer
/// town's inbound A2A frames iff the node owner currently holds a valid, unexpired
/// `StandingGrant` naming that peer on the relevant plane.
///
/// Consulted per inbound frame by `serve` (the protocol is `async` for exactly this): the
/// `liveGrants` closure is re-invoked every time, so a grant that expired or was revoked
/// since the last frame stops admitting the peer on the very next chunk — no cache to
/// invalidate, which is what makes revocation bite mid-stream (the whole reason
/// `TownAuthorizer.authorizes` is per-frame).
public struct StandingGrantTownAuthorizer: TownAuthorizer {
    /// Which plane a peer must be granted to reach the A2A channel. Defaults to `.delegate`
    /// because the A2A town plane *is* the task-delegation channel (GOOSEWORLD §2: "Town A's
    /// orchestrator delegates a bead to Town B's flock | A2A v1.0 over the ratchet stream").
    /// The cross-town *wall* rides the shared-AI-thread transport (WS-G5), not this A2A
    /// plane, so a `.wall`-only grant must NOT open the delegation channel — hence the plane
    /// is an explicit, checked field rather than "any live grant".
    public let plane: StandingGrant.Plane

    /// If non-nil, ONLY grants signed by this identity are honored — the node owner's own
    /// hex. This is the load-bearing fail-closed check: a `standing_grant` is signed by the
    /// human authorizing *their* side of a co-build, so on this node the grants that admit a
    /// peer are the ones the OWNER signed. Without this filter a grant that happened to carry
    /// a peer-produced signature (a peer "authorizing themselves") would be honored the moment
    /// it verified against its own `enabled_by` — self-authorization, the exact confused-
    /// deputy the C-3 gate exists to prevent. nil disables the filter (any validly-signed
    /// grant in the set is honored); production always passes the owner hex.
    public let requiredGranterHex: String?

    /// Reads the current live grant set. Wired by the integration to
    /// `AgentEngine`-owned state (e.g. a snapshot of `activeStandingGrants()` mapped back to
    /// the underlying grants, or a store the engine writes through). Kept as a closure so
    /// this type needs no dependency on PQRCAgent and stays a pure value over PQRCCore.
    private let liveGrants: @Sendable () async -> [StandingGrant]

    /// Current unix time in seconds, injected so tests never touch the real clock
    /// (CLAUDE.md: "No unit test touches the network or the real clock").
    private let now: @Sendable () -> Int64

    public init(
        plane: StandingGrant.Plane = .delegate,
        requiredGranterHex: String? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        liveGrants: @escaping @Sendable () async -> [StandingGrant]
    ) {
        self.plane = plane
        // Normalize the owner hex to canonical lowercase once, so the per-frame comparison is
        // a plain `==` against `enabledBy.hexString` (which is already lowercase). An empty
        // string after trimming means "no owner pin" → treated as nil (fail toward the
        // stricter of the two only if a caller explicitly passes nil; an empty string is a
        // caller bug we refuse to silently read as "honor everyone").
        let trimmed = requiredGranterHex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.requiredGranterHex = (trimmed?.isEmpty == true) ? nil : trimmed
        self.now = now
        self.liveGrants = liveGrants
    }

    public func authorizes(peerIdentityHex: String) async -> Bool {
        StandingGrantAdmission.admits(
            peer: peerIdentityHex, plane: plane, requiredGranterHex: requiredGranterHex,
            cutoff: now(), grants: await liveGrants())
    }
}

/// The single grant-admission predicate, extracted (WS-G5) so the transport-level
/// authorizer above and the per-LINE plane router (`PlaneRoutedTownService`) can never
/// drift apart: both answer "does a live, owner-signed, unexpired grant cover this peer
/// on this plane?" with the same checks in the same order. Pure — no clock, no I/O.
public enum StandingGrantAdmission {
    /// `requiredGranterHex`, when non-nil, must already be canonical lowercase (both
    /// callers normalize once at init) — the comparison is a plain `==` against
    /// `enabledBy.hexString`, which is lowercase by construction.
    public static func admits(
        peer peerIdentityHex: String,
        plane: StandingGrant.Plane,
        requiredGranterHex: String?,
        cutoff: Int64,
        grants: [StandingGrant]
    ) -> Bool {
        // An empty/whitespace peer is never a real verified identity — refuse before any
        // scan, same first line as `PinnedTownAllowlist`.
        let peer = peerIdentityHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { return false }

        for grant in grants {
            // Peer scope: the grant must name THIS peer. Case-sensitive exact match, matching
            // the C-3 gate's `==` and `PinnedTownAllowlist` — one notion of "same peer".
            guard grant.peer == peer else { continue }
            // Plane scope: `.covers` returns false for a grant that only lists other planes,
            // so a wall-only grant never opens the delegation channel (and vice versa).
            guard grant.covers(plane) else { continue }
            // Expiry: strictly in the future. `activeUntil == cutoff` is already expired
            // (mirrors the engine's `activeWindow`/`authorizeTownSend` "> now" convention).
            guard grant.activeUntil > cutoff else { continue }
            // Granter pin: only the owner's own signed grant admits a peer (see the field's
            // doc — this refuses peer self-authorization).
            if let owner = requiredGranterHex, grant.enabledBy.hexString != owner { continue }
            // Signature LAST (it is the costly check): re-verify the human signature over the
            // domain-separated, length-prefixed scope, so a tampered grant in the set fails
            // closed even though the engine also verified it at receipt. Defense in depth.
            guard grant.hasValidSignature() else { continue }
            return true
        }
        return false
    }
}
