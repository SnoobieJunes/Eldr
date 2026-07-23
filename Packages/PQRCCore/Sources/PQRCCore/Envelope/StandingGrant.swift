// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Why a standing grant was rejected as structurally invalid.
///
/// A dedicated typed error, rather than a `PQRCError.protocolViolation(String)`,
/// so tests and UI can assert on the exact reason without string-matching — and
/// so the reason never becomes a place where a peer's identity hex could get
/// interpolated into an error message that later lands in a log.
public enum StandingGrantError: Error, Equatable, Sendable {
    case wrongType
    case malformedGrantID
    case malformedPeer
    case malformedPlanes
    case malformedBudget
    case malformedEnabledBy
}

/// Human-signed **standing town grant** (GOOSEWORLD §5, DEVIATIONS AC126) — a
/// day-scale, scoped, budgeted, revocable authorization for MY agent to act
/// autonomously toward ONE named peer town on ONE named plane.
///
/// ## Why this exists at all
///
/// SPEC §13 gates every autonomous agent send on a human-signed `ai_window`
/// (minutes-to-hours) or a thread `ai_invite`. A week-long two-town co-build fits
/// neither: windows lapse mid-build (the AC110 "tether went silent forever" class
/// of failure is exactly this surfacing), and per-task approval is unusable on a
/// cross-town wall with hundreds of posts. The wrong fix — the one that erodes
/// invariant 9 — is to widen the existing gate "just a bit" per surface until it
/// no longer means anything. So this is a SEPARATE first-class object with its own
/// signature domain, its own storage, and its own gate
/// (`AgentEngine.authorizeTownSend`). It does **not** widen
/// `authorizeAutonomousSend`; holding a standing grant authorizes exactly nothing
/// in an ordinary conversation or thread. §13's silent, fail-closed default is
/// untouched.
///
/// ## What a grant is
///
/// Signed by the granter's HUMAN identity key, exactly like `ai_window` /
/// `ai_invite` / `ai_context_grant`: agents cannot self-grant (SPEC §13.3,
/// CLAUDE.md invariant 9). A distinct domain string (`pqrc-standing-grant-v1`)
/// makes it impossible to replay a window / invite / context-grant signature as a
/// standing grant, or the reverse.
///
/// Every scoped field — grant id, peer, planes, all three budget numbers, and the
/// optional tool ceiling — is bound into the signature through ``scopeTag``, so a
/// grant issued for peer A on the `wall` plane can never be reflected as a grant
/// for peer B, or onto the `delegate` plane, or with a fatter budget.
///
/// ## What a grant is NOT
///
/// It is not a capability to run tools. `toolCeiling` only ever NARROWS: the
/// existing fail-closed ACP permission gates and path jail still run on everything
/// a remote task triggers (GOOSEWORLD §4 adversary class 1). A grant with no
/// ceiling therefore does not "allow all tools"; it simply adds no extra
/// narrowing on top of the gates that were already there.
public struct StandingGrant: Codable, Equatable, Sendable {
    /// The cooperation surfaces a grant can cover. Deliberately a closed, tiny set:
    /// each plane is a distinct blast radius and is granted separately.
    ///
    /// - `wall`: cross-town Town-Wall posts (text broadcast, WS-G5).
    /// - `delegate`: accepting/producing delegated TASKS (code-execution-adjacent,
    ///   WS-G1/G3) — strictly the more dangerous of the two.
    ///
    /// Declaration order IS the canonical order (see ``canonicalPlanes(_:)``).
    public enum Plane: String, Codable, Sendable, CaseIterable {
        case wall
        case delegate
    }

    /// Per-day spending limits plus the concurrency ceiling for the `delegate`
    /// plane. Budgets exist because "runaway loops / cost" is a named adversary
    /// class (GOOSEWORLD §4.4) and because a standing grant lives for days: without
    /// a ceiling, one prompt-injected orchestrator could burn a month of tokens or
    /// exfiltrate a repository one wall post at a time.
    ///
    /// **There is no way to express "unlimited".** `0` means "none" (fail closed),
    /// and every field is capped (see ``validate()``) both as a sanity ceiling and
    /// so day-accounting can never overflow.
    public struct Budget: Codable, Equatable, Sendable {
        /// Normative sanity ceilings. A grant claiming more is malformed, not
        /// merely greedy — this is the arithmetic bound that keeps the engine's
        /// `Int` day-counters from overflowing, so it is a wire rule, not a policy.
        public static let maxMessagesPerDay = 1_000_000
        public static let maxBytesPerDay = 1_000_000_000
        public static let maxConcurrentTaskCeiling = 1024
        /// Ceiling on the size of the optional tool allow-list.
        public static let maxToolCeilingCount = 256
        /// Ceiling on one tool name's length.
        public static let maxToolNameLength = 128

        /// Autonomous messages this grant permits per UTC day. `0` = none.
        public let messagesPerDay: Int
        /// Autonomous message BYTES this grant permits per UTC day. `0` = none.
        public let bytesPerDay: Int
        /// Simultaneous in-flight delegated tasks. `0` = none.
        public let maxConcurrentTasks: Int
        /// Optional allow-list of tool names for delegated tasks. `nil` = this
        /// grant adds no narrowing beyond the permission gates that already run;
        /// a list = ONLY these, and only if the gates also allow them.
        public let toolCeiling: [String]?

        enum CodingKeys: String, CodingKey {
            case messagesPerDay = "messages_per_day"
            case bytesPerDay = "bytes_per_day"
            case maxConcurrentTasks = "max_concurrent_tasks"
            case toolCeiling = "tool_ceiling"
        }

        public init(
            messagesPerDay: Int, bytesPerDay: Int, maxConcurrentTasks: Int,
            toolCeiling: [String]? = nil
        ) {
            self.messagesPerDay = messagesPerDay
            self.bytesPerDay = bytesPerDay
            self.maxConcurrentTasks = maxConcurrentTasks
            self.toolCeiling = toolCeiling
        }

        /// Structural validity. Callers get a thrown error; the engine turns this
        /// into a rejected grant. Fail closed on anything out of range.
        public func validate() throws {
            guard (0...Self.maxMessagesPerDay).contains(messagesPerDay),
                (0...Self.maxBytesPerDay).contains(bytesPerDay),
                (0...Self.maxConcurrentTaskCeiling).contains(maxConcurrentTasks)
            else { throw StandingGrantError.malformedBudget }
            if let toolCeiling {
                guard toolCeiling.count <= Self.maxToolCeilingCount else {
                    throw StandingGrantError.malformedBudget
                }
                for tool in toolCeiling {
                    guard !tool.isEmpty, tool.utf8.count <= Self.maxToolNameLength else {
                        throw StandingGrantError.malformedBudget
                    }
                }
            }
        }
    }

    /// Longest grant id we will canonicalize (ids are opaque; the signature binds
    /// them, so length is the only thing that needs bounding).
    public static let maxGrantIDLength = 64

    public let type: String
    /// Stable id for this grant, minted by the granter. Revocation targets it.
    public let grantID: String
    /// The peer TOWN this grant is about, as a 64-char lowercase-hex PQRC identity
    /// pubkey. Bound into the signature: a grant for one town is meaningless for
    /// another.
    public let peer: String
    /// The planes this grant covers, as raw strings.
    ///
    /// Deliberately NOT `[Plane]` on the wire: a future plane must not make the
    /// whole grant undecodable on today's clients (SPEC §12). Unknown strings
    /// round-trip, stay bound in the signature (so the grant still verifies), and
    /// simply never match a gate query here — forward-compatible AND fail-closed.
    public let planes: [String]
    public let budget: Budget
    public let activeUntil: Int64
    public let enabledBy: Data
    public let sig: Data

    enum CodingKeys: String, CodingKey {
        case type
        case grantID = "grant_id"
        case peer
        case planes
        case budget
        case activeUntil = "active_until"
        case enabledBy = "enabled_by"
        case sig
    }

    public init(
        grantID: String, peer: String, planes: [String], budget: Budget,
        activeUntil: Int64, enabledBy: Data, sig: Data
    ) {
        self.type = "standing_grant"
        self.grantID = grantID
        self.peer = peer
        self.planes = planes
        self.budget = budget
        self.activeUntil = activeUntil
        self.enabledBy = enabledBy
        self.sig = sig
    }

    // MARK: - Canonical scope tag (what the signature actually binds)

    /// Canonical, unambiguous encoding of EVERY scoped field.
    ///
    /// `AIContextGrant.Scope.tag` gets away with `"kind:id"` because both halves
    /// come from a closed vocabulary. A standing grant does not: it carries an
    /// opaque grant id and caller-supplied tool names, and a plain
    /// delimiter-joined string would let two DIFFERENT grants share one tag (put a
    /// `:` in a tool name and the parse boundary moves). A tag collision is a
    /// signature transplant, so every free-form component is emitted
    /// **length-prefixed** — `|<utf8-byte-count>:<value>` — which is injective by
    /// construction: no choice of contents can produce another grant's bytes.
    ///
    /// Both variable-length ARRAYS are emitted as a count followed by that many
    /// length-prefixed components, never as a delimiter-joined string. That is not
    /// belt-and-braces; joining is actively unsafe here. `["", "wall"]` and
    /// `["+wall"]` join to the same `"+wall"` — the first authorizes the `wall`
    /// plane, the second authorizes nothing — so a joined tag would let a
    /// signature over the harmless grant be transplanted onto the powerful one.
    /// (This bug was written, then found in review; the test
    /// `emptyPlaneStringCannotCollideWithAJoinedPlane` is the tombstone.)
    ///
    /// The `tools` component likewise distinguishes "no ceiling" (`tools=*`, one
    /// component) from a list (`tools=<n>` + `n` components), so an empty list —
    /// "no tools at all" — is not confusable with an absent one.
    public var scopeTag: String {
        var out = "standing-grant-v1"
        func add(_ value: String) { out += "|\(value.utf8.count):\(value)" }
        add(grantID)
        add(peer)
        // Order and multiplicity are bound too: a reorder or a duplicate changes
        // the tag, so neither survives verification.
        add("planes=\(planes.count)")
        for plane in planes { add(plane) }
        add("m=\(budget.messagesPerDay)")
        add("b=\(budget.bytesPerDay)")
        add("c=\(budget.maxConcurrentTasks)")
        if let tools = budget.toolCeiling {
            add("tools=\(tools.count)")
            for tool in tools { add(tool) }
        } else {
            add("tools=*")
        }
        return out
    }

    /// Domain-separated message the human identity key signs. The domain string is
    /// deliberately distinct from `pqrc-ai-window-v1`,
    /// `pqrc-ai-context-grant-v1`, and `pqrc-standing-grant-revocation-v1`, and is
    /// not a prefix of any of them, so no signature is ever valid in two roles.
    public static func signatureMessage(
        scopeTag: String, activeUntil: Int64, enabledBy: Data
    ) -> Data {
        var msg = Data("pqrc-standing-grant-v1".utf8)
        msg.append(Data(int64BE: activeUntil))
        msg.append(enabledBy)
        msg.append(Data(scopeTag.utf8))
        return msg
    }

    // MARK: - Construction + validation

    /// Canonical plane ordering: declaration order, deduped. Used on the SEND side
    /// so two clients granting the same thing produce the same tag.
    public static func canonicalPlanes(_ planes: [Plane]) -> [String] {
        Plane.allCases.filter(planes.contains).map(\.rawValue)
    }

    /// Signs a grant with the human identity key. Throws
    /// `PQRCError.invalidStandingGrant` on anything structurally out of range —
    /// the caller cannot mint a grant this engine would refuse to honor.
    ///
    /// Duration bounding is NOT checked here (there is no clock in the wire layer);
    /// `AgentEngine.startMyStandingGrant` enforces the allowed-duration set and
    /// `receiveStandingGrant` enforces the hard cap on the way in.
    public static func make(
        grantID: String, peer: String, planes: [Plane], budget: Budget,
        activeUntil: Int64, identity: PQRCIdentity
    ) throws -> StandingGrant {
        let planeStrings = canonicalPlanes(planes)
        let pub = identity.publicKeyData
        let grant = StandingGrant(
            grantID: grantID, peer: peer, planes: planeStrings, budget: budget,
            activeUntil: activeUntil, enabledBy: pub, sig: Data())
        try grant.validateStructure()
        let sig = try identity.sign(
            signatureMessage(
                scopeTag: grant.scopeTag, activeUntil: activeUntil, enabledBy: pub))
        return StandingGrant(
            grantID: grantID, peer: peer, planes: planeStrings, budget: budget,
            activeUntil: activeUntil, enabledBy: pub, sig: sig)
    }

    /// Structural checks that do not need a clock or a key. Everything here is a
    /// hard wire rule: a grant that fails it is rejected, never "repaired".
    public func validateStructure() throws {
        guard type == "standing_grant" else { throw StandingGrantError.wrongType }
        guard !grantID.isEmpty, grantID.utf8.count <= Self.maxGrantIDLength else {
            throw StandingGrantError.malformedGrantID
        }
        // A town identity is a 32-byte Ed25519 pubkey in lowercase hex. Anything
        // else is not a town we could ever address, so it is malformed, not merely
        // unknown. Pinning the case matters too: `peer` is a dictionary key in the
        // engine, and two spellings of one town would be two independent budgets.
        guard peer.count == 64, peer == peer.lowercased(),
            Data(hexString: peer)?.count == 32
        else { throw StandingGrantError.malformedPeer }
        // Duplicates are rejected rather than deduped: the tag binds the array
        // verbatim, so silently normalizing here would make a signature that
        // verifies for one canonical form and not the other. Empty plane names are
        // rejected as belt-and-braces on the tag's injectivity — the tag no longer
        // joins planes, but a nameless plane is meaningless in any case.
        guard !planes.isEmpty, Set(planes).count == planes.count,
            !planes.contains(where: \.isEmpty),
            planes.allSatisfy({ $0.utf8.count <= Budget.maxToolNameLength })
        else {
            throw StandingGrantError.malformedPlanes
        }
        guard enabledBy.count == 32 else { throw StandingGrantError.malformedEnabledBy }
        try budget.validate()
    }

    // MARK: - Queries

    /// The planes this grant covers that THIS build understands. Unknown plane
    /// strings are dropped here (never at decode time) so they stay bound in the
    /// signature while authorizing nothing.
    public var knownPlanes: Set<Plane> {
        Set(planes.compactMap(Plane.init(rawValue:)))
    }

    public func covers(_ plane: Plane) -> Bool { knownPlanes.contains(plane) }

    /// Signature check only — time bounds and budgets are enforced by the
    /// AgentEngine gate, exactly as with windows and invites.
    public func hasValidSignature() -> Bool {
        PQRCIdentity.verify(
            signature: sig,
            message: Self.signatureMessage(
                scopeTag: scopeTag, activeUntil: activeUntil, enabledBy: enabledBy),
            publicKey: enabledBy)
    }

    /// Whether this grant's remaining life is inside the protocol's hard cap.
    /// An unbounded (or absurdly long) grant is not a grant — it is an
    /// abdication — so the engine refuses it rather than clamping it.
    public func hasBoundedDuration(now: Int64) -> Bool {
        activeUntil - now <= PQRCConstants.maxStandingGrantDuration
    }
}

/// Signed withdrawal of a ``StandingGrant``, effective on receipt.
///
/// Mirrors `AgentEngine.endMyWindowEarly`'s discipline: the local gate closes
/// even if signing fails, and publishing the signed object is what closes it
/// everywhere else. Its own domain string means a revocation signature can never
/// be replayed as a grant (which, given both are signed by the same identity key,
/// is the one transplant that would actually be worth an attacker's time: turning
/// "stop" into "go").
///
/// Only `grantID` is targeted — not the scope — because the scope is already bound
/// into the grant that id names. A revocation naming a grant the receiver has
/// never seen is a SAFE NO-OP, deliberately: returning an error there would turn
/// this into an oracle for "do you hold grant X?", which is exactly the kind of
/// state probe SPEC §0 says to close off.
public struct StandingGrantRevocation: Codable, Equatable, Sendable {
    public let type: String
    public let grantID: String
    /// When the granter signed the withdrawal. Informational for display; the
    /// engine acts on RECEIPT, so a doctored timestamp cannot delay a revocation.
    public let revokedAt: Int64
    public let enabledBy: Data
    public let sig: Data

    enum CodingKeys: String, CodingKey {
        case type
        case grantID = "grant_id"
        case revokedAt = "revoked_at"
        case enabledBy = "enabled_by"
        case sig
    }

    public init(grantID: String, revokedAt: Int64, enabledBy: Data, sig: Data) {
        self.type = "standing_grant_revocation"
        self.grantID = grantID
        self.revokedAt = revokedAt
        self.enabledBy = enabledBy
        self.sig = sig
    }

    /// Domain-separated, with the grant id length-prefixed for the same
    /// injectivity reason as ``StandingGrant/scopeTag``.
    public static func signatureMessage(
        grantID: String, revokedAt: Int64, enabledBy: Data
    ) -> Data {
        var msg = Data("pqrc-standing-grant-revocation-v1".utf8)
        msg.append(Data(int64BE: revokedAt))
        msg.append(enabledBy)
        msg.append(Data("\(grantID.utf8.count):\(grantID)".utf8))
        return msg
    }

    public static func make(
        grantID: String, revokedAt: Int64, identity: PQRCIdentity
    ) throws -> StandingGrantRevocation {
        guard !grantID.isEmpty, grantID.utf8.count <= StandingGrant.maxGrantIDLength else {
            throw StandingGrantError.malformedGrantID
        }
        let pub = identity.publicKeyData
        let sig = try identity.sign(
            signatureMessage(grantID: grantID, revokedAt: revokedAt, enabledBy: pub))
        return StandingGrantRevocation(
            grantID: grantID, revokedAt: revokedAt, enabledBy: pub, sig: sig)
    }

    public func hasValidSignature() -> Bool {
        PQRCIdentity.verify(
            signature: sig,
            message: Self.signatureMessage(
                grantID: grantID, revokedAt: revokedAt, enabledBy: enabledBy),
            publicKey: enabledBy)
    }
}
