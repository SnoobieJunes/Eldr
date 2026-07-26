// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

/// Wire-layer guarantees for standing town grants (GOOSEWORLD §5, DEVIATIONS
/// AC126): domain separation, scope binding, canonical tags, structural
/// validation, and SPEC §12 backward/forward compatibility.
@Suite("Standing town grant wire format")
struct StandingGrantWireTests {
    static let peerHex = String(repeating: "b7", count: 32)
    static let otherPeerHex = String(repeating: "c9", count: 32)

    static func alice() throws -> PQRCIdentity {
        try PQRCIdentity(seed: Data(repeating: 0xA7, count: 32))
    }
    static func bob() throws -> PQRCIdentity {
        try PQRCIdentity(seed: Data(repeating: 0xB7, count: 32))
    }

    static let budget = StandingGrant.Budget(
        messagesPerDay: 200, bytesPerDay: 1_000_000, maxConcurrentTasks: 2)

    // MARK: - Signature domain separation (requirement 1)

    /// No signature made in any of the other three roles may validate as a
    /// standing grant, and a standing-grant signature may not validate as any of
    /// them. Four types, both directions.
    @Test func domainSeparation_noCrossReplayAmongAllFourTypes() throws {
        let alice = try Self.alice()
        let pub = alice.publicKeyData
        let until: Int64 = 1_756_000_000
        let scope = AIContextGrant.Scope.conversation("c1")

        let grant = try StandingGrant.make(
            grantID: "g1", peer: Self.peerHex, planes: [.wall], budget: Self.budget,
            activeUntil: until, identity: alice)

        // window / invite / context-grant / revocation signatures, all by the same
        // identity key over the same activeUntil.
        let windowSig = try alice.sign(
            AIWindowAnnouncement.signatureMessage(
                activeUntil: until, enabledBy: pub, threadID: nil))
        let inviteSig = try alice.sign(
            AIWindowAnnouncement.signatureMessage(
                activeUntil: until, enabledBy: pub, threadID: "t1"))
        let contextSig = try alice.sign(
            AIContextGrant.signatureMessage(scope: scope, activeUntil: until, enabledBy: pub))
        let revocationSig = try alice.sign(
            StandingGrantRevocation.signatureMessage(
                grantID: "g1", revokedAt: until, enabledBy: pub))

        // → standing grant: every foreign signature is rejected.
        for foreign in [windowSig, inviteSig, contextSig, revocationSig] {
            let forged = StandingGrant(
                grantID: grant.grantID, peer: grant.peer, planes: grant.planes,
                budget: grant.budget, activeUntil: until, enabledBy: pub, sig: foreign)
            #expect(forged.hasValidSignature() == false)
        }

        // standing grant → the other three: its signature is rejected everywhere.
        #expect(
            AIWindowAnnouncement(activeUntil: until, enabledBy: pub, sig: grant.sig)
                .hasValidSignature() == false)
        #expect(
            AIInvite(threadID: "t1", activeUntil: until, enabledBy: pub, sig: grant.sig)
                .hasValidSignature() == false)
        #expect(
            AIContextGrant(scope: scope, activeUntil: until, enabledBy: pub, sig: grant.sig)
                .hasValidSignature() == false)
        #expect(
            StandingGrantRevocation(
                grantID: "g1", revokedAt: until, enabledBy: pub, sig: grant.sig)
                .hasValidSignature() == false)

        // …and a revocation signature is not a grant signature (the transplant
        // that would turn "stop" into "go").
        let revocation = try StandingGrantRevocation.make(
            grantID: "g1", revokedAt: until, identity: alice)
        let goFromStop = StandingGrant(
            grantID: "g1", peer: Self.peerHex, planes: grant.planes, budget: Self.budget,
            activeUntil: until, enabledBy: pub, sig: revocation.sig)
        #expect(goFromStop.hasValidSignature() == false)
        #expect(revocation.hasValidSignature() == true)
        #expect(grant.hasValidSignature() == true)
    }

    // MARK: - Scope binding (requirement 2)

    /// Every scoped field is inside the signature: change any one of them on a
    /// signed grant and verification fails. This is the "reflected onto peer B /
    /// plane delegate / a fatter budget" attack, enumerated.
    @Test func everyScopedFieldIsBoundIntoTheSignature() throws {
        let alice = try Self.alice()
        let until: Int64 = 1_756_000_000
        let grant = try StandingGrant.make(
            grantID: "g1", peer: Self.peerHex, planes: [.wall], budget: Self.budget,
            activeUntil: until, identity: alice)
        #expect(grant.hasValidSignature() == true)

        func tampered(
            grantID: String? = nil, peer: String? = nil, planes: [String]? = nil,
            budget: StandingGrant.Budget? = nil, activeUntil: Int64? = nil
        ) -> StandingGrant {
            StandingGrant(
                grantID: grantID ?? grant.grantID, peer: peer ?? grant.peer,
                planes: planes ?? grant.planes, budget: budget ?? grant.budget,
                activeUntil: activeUntil ?? grant.activeUntil,
                enabledBy: grant.enabledBy, sig: grant.sig)
        }

        #expect(tampered(grantID: "g2").hasValidSignature() == false)
        #expect(tampered(peer: Self.otherPeerHex).hasValidSignature() == false)
        #expect(tampered(planes: ["delegate"]).hasValidSignature() == false)
        #expect(tampered(planes: ["wall", "delegate"]).hasValidSignature() == false)
        #expect(tampered(activeUntil: until + 1).hasValidSignature() == false)
        #expect(
            tampered(
                budget: StandingGrant.Budget(
                    messagesPerDay: 201, bytesPerDay: 1_000_000, maxConcurrentTasks: 2)
            ).hasValidSignature() == false)
        #expect(
            tampered(
                budget: StandingGrant.Budget(
                    messagesPerDay: 200, bytesPerDay: 1_000_001, maxConcurrentTasks: 2)
            ).hasValidSignature() == false)
        #expect(
            tampered(
                budget: StandingGrant.Budget(
                    messagesPerDay: 200, bytesPerDay: 1_000_000, maxConcurrentTasks: 3)
            ).hasValidSignature() == false)
        #expect(
            tampered(
                budget: StandingGrant.Budget(
                    messagesPerDay: 200, bytesPerDay: 1_000_000, maxConcurrentTasks: 2,
                    toolCeiling: ["read"])
            ).hasValidSignature() == false)
    }

    /// The tool ceiling is bound too, including the difference between "no
    /// ceiling", "an empty ceiling", and a ceiling naming a tool called `*`.
    @Test func toolCeilingIsBoundAndUnambiguous() throws {
        let alice = try Self.alice()
        func tag(_ ceiling: [String]?) -> String {
            StandingGrant(
                grantID: "g1", peer: Self.peerHex, planes: ["delegate"],
                budget: StandingGrant.Budget(
                    messagesPerDay: 1, bytesPerDay: 1, maxConcurrentTasks: 1,
                    toolCeiling: ceiling),
                activeUntil: 1, enabledBy: alice.publicKeyData, sig: Data()
            ).scopeTag
        }
        let none = tag(nil)
        let empty = tag([])
        let star = tag(["*"])
        let two = tag(["read", "write"])
        #expect(Set([none, empty, star, two]).count == 4)

        // A colon-and-comma-laden tool name cannot forge another grant's tag —
        // length prefixing is injective.
        let sneaky = tag(["read|1:write", "x"])
        let honest = tag(["read", "1:write", "x"])
        #expect(sneaky != honest)
    }

    /// Regression, found in adversarial review of the FIRST draft of `scopeTag`.
    ///
    /// That draft bound planes as `planes.joined(separator: "+")`. `["", "wall"]`
    /// and `["+wall"]` join to the identical string, yet the first authorizes the
    /// `wall` plane and the second authorizes nothing — so a signature over the
    /// harmless grant could be transplanted onto the powerful one, which is
    /// precisely the escalation the tag exists to prevent. Planes are now emitted
    /// count-then-length-prefixed. Two defences, both asserted here: the tags
    /// differ, and an empty plane name is refused outright.
    @Test func emptyPlaneStringCannotCollideWithAJoinedPlane() throws {
        let alice = try Self.alice()
        func tag(_ planes: [String]) -> String {
            StandingGrant(
                grantID: "g1", peer: Self.peerHex, planes: planes, budget: Self.budget,
                activeUntil: 1, enabledBy: alice.publicKeyData, sig: Data()
            ).scopeTag
        }
        #expect(tag(["", "wall"]) != tag(["+wall"]))
        #expect(tag(["wall", "delegate"]) != tag(["wall+delegate"]))
        #expect(tag(["a", "b", "c"]) != tag(["a+b", "c"]))

        let empty = StandingGrant(
            grantID: "g1", peer: Self.peerHex, planes: ["", "wall"], budget: Self.budget,
            activeUntil: 1, enabledBy: alice.publicKeyData, sig: Data())
        #expect(throws: StandingGrantError.malformedPlanes) { try empty.validateStructure() }
    }

    /// Plane ORDER is canonical on the send side, so two clients granting the same
    /// thing sign the same bytes.
    @Test func planeOrderIsCanonical() throws {
        #expect(StandingGrant.canonicalPlanes([.delegate, .wall]) == ["wall", "delegate"])
        #expect(StandingGrant.canonicalPlanes([.wall, .delegate]) == ["wall", "delegate"])
        #expect(StandingGrant.canonicalPlanes([.wall, .wall]) == ["wall"])

        let alice = try Self.alice()
        let a = try StandingGrant.make(
            grantID: "g1", peer: Self.peerHex, planes: [.wall, .delegate],
            budget: Self.budget, activeUntil: 7, identity: alice)
        let b = try StandingGrant.make(
            grantID: "g1", peer: Self.peerHex, planes: [.delegate, .wall],
            budget: Self.budget, activeUntil: 7, identity: alice)
        // Compare the SIGNED BYTES, not the signatures: CryptoKit's Ed25519 is
        // randomized, so two signatures over identical material differ.
        #expect(a.scopeTag == b.scopeTag)
        #expect(a.planes == b.planes)
        #expect(b.hasValidSignature() == true)
        #expect(a.knownPlanes == [.wall, .delegate])
        #expect(a.covers(.wall) && a.covers(.delegate))
    }

    // MARK: - Structural validation

    @Test func structurallyInvalidGrantsAreRejected() throws {
        let alice = try Self.alice()
        func make(
            grantID: String = "g1", peer: String = Self.peerHex, planes: [StandingGrant.Plane] = [.wall],
            budget: StandingGrant.Budget = Self.budget
        ) throws -> StandingGrant {
            try StandingGrant.make(
                grantID: grantID, peer: peer, planes: planes, budget: budget,
                activeUntil: 1_756_000_000, identity: alice)
        }

        #expect(throws: StandingGrantError.malformedGrantID) { _ = try make(grantID: "") }
        #expect(throws: StandingGrantError.malformedGrantID) {
            _ = try make(grantID: String(repeating: "z", count: 65))
        }
        #expect(throws: StandingGrantError.malformedPeer) { _ = try make(peer: "not-hex") }
        #expect(throws: StandingGrantError.malformedPeer) {
            _ = try make(peer: Self.peerHex.uppercased())  // case must be pinned
        }
        #expect(throws: StandingGrantError.malformedPeer) {
            _ = try make(peer: String(repeating: "ab", count: 31))  // 31 bytes, not 32
        }
        #expect(throws: StandingGrantError.malformedPlanes) { _ = try make(planes: []) }
        #expect(throws: StandingGrantError.malformedBudget) {
            _ = try make(
                budget: StandingGrant.Budget(
                    messagesPerDay: -1, bytesPerDay: 1, maxConcurrentTasks: 1))
        }
        #expect(throws: StandingGrantError.malformedBudget) {
            _ = try make(
                budget: StandingGrant.Budget(
                    messagesPerDay: 1, bytesPerDay: StandingGrant.Budget.maxBytesPerDay + 1,
                    maxConcurrentTasks: 1))
        }
        #expect(throws: StandingGrantError.malformedBudget) {
            _ = try make(
                budget: StandingGrant.Budget(
                    messagesPerDay: 1, bytesPerDay: 1, maxConcurrentTasks: 1,
                    toolCeiling: [""]))
        }
        // A decoded grant with duplicate planes is malformed (the tag binds the
        // array verbatim, so we never silently dedupe).
        let dupes = StandingGrant(
            grantID: "g1", peer: Self.peerHex, planes: ["wall", "wall"], budget: Self.budget,
            activeUntil: 1, enabledBy: alice.publicKeyData, sig: Data())
        #expect(throws: StandingGrantError.malformedPlanes) { try dupes.validateStructure() }
    }

    @Test func revocationRejectsMalformedGrantID() throws {
        let alice = try Self.alice()
        #expect(throws: StandingGrantError.malformedGrantID) {
            _ = try StandingGrantRevocation.make(grantID: "", revokedAt: 1, identity: alice)
        }
    }

    // MARK: - Duration bounding (requirement 3)

    @Test func durationsAreBoundedInDays() throws {
        let alice = try Self.alice()
        #expect(PQRCConstants.maxStandingGrantDuration == 30 * 24 * 60 * 60)
        // Bound to a local first: inside #expect the literal-plus-map is one
        // expression the type-checker gives up on (it maps untyped integer
        // literals through arithmetic, then compares to [Int64]).
        let expectedDurations: [Int64] = [1, 3, 7, 14, 30].map { $0 * 24 * 60 * 60 }
        #expect(PQRCConstants.allowedStandingGrantDurations == expectedDurations)
        // Every allowed duration is inside the cap; the cap itself is the longest.
        for duration in PQRCConstants.allowedStandingGrantDurations {
            #expect(duration <= PQRCConstants.maxStandingGrantDuration)
        }
        let now: Int64 = 1_756_000_000
        let atCap = try StandingGrant.make(
            grantID: "g1", peer: Self.peerHex, planes: [.wall], budget: Self.budget,
            activeUntil: now + PQRCConstants.maxStandingGrantDuration, identity: alice)
        #expect(atCap.hasBoundedDuration(now: now) == true)
        let oneOver = try StandingGrant.make(
            grantID: "g1", peer: Self.peerHex, planes: [.wall], budget: Self.budget,
            activeUntil: now + PQRCConstants.maxStandingGrantDuration + 1, identity: alice)
        #expect(oneOver.hasBoundedDuration(now: now) == false)
    }

    // MARK: - Wire round-trip + SPEC §12 compatibility (requirement 8)

    @Test func messageBodyRoundTripsStandingGrantAndRevocation() throws {
        let alice = try Self.alice()
        let grant = try StandingGrant.make(
            grantID: "g1", peer: Self.peerHex, planes: [.wall, .delegate],
            budget: StandingGrant.Budget(
                messagesPerDay: 200, bytesPerDay: 1_000_000, maxConcurrentTasks: 2,
                toolCeiling: ["read_file", "grep"]),
            activeUntil: 1_756_000_000, identity: alice)
        let revocation = try StandingGrantRevocation.make(
            grantID: "g1", revokedAt: 1_756_000_500, identity: alice)

        let body = MessageBody(
            text: "granting", sentAt: 1_756_000_001,
            standingGrant: grant, standingGrantRevocation: revocation)
        let data = try WireJSON.encoder().encode(body)
        let decoded = try WireJSON.decoder().decode(MessageBody.self, from: data)
        #expect(decoded == body)
        #expect(decoded.standingGrant?.hasValidSignature() == true)
        #expect(decoded.standingGrantRevocation?.hasValidSignature() == true)
        #expect(decoded.standingGrant?.knownPlanes == [.wall, .delegate])
        #expect(decoded.standingGrant?.budget.toolCeiling == ["read_file", "grep"])

        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"standing_grant\""))
        #expect(json.contains("\"standing_grant_revocation\""))
        #expect(json.contains("\"messages_per_day\""))
        #expect(json.contains("\"bytes_per_day\""))
        #expect(json.contains("\"max_concurrent_tasks\""))
        #expect(json.contains("\"tool_ceiling\""))
        #expect(json.contains("\"grant_id\""))
    }

    /// The compatibility contract: a body with no standing grant encodes EXACTLY
    /// as it did before this feature existed. If this fails, frozen vectors and
    /// older peers are broken.
    @Test func absentStandingGrantIsOmittedFromTheEncoding() throws {
        let body = MessageBody(text: "hi", sentAt: 7)
        let json = String(decoding: try WireJSON.encoder().encode(body), as: UTF8.self)
        #expect(json == #"{"sent_at":7,"text":"hi"}"#)
        #expect(!json.contains("standing"))
        // A nil tool ceiling is likewise omitted, not encoded as null.
        let budgetJSON = String(
            decoding: try WireJSON.encoder().encode(Self.budget), as: UTF8.self)
        #expect(!budgetJSON.contains("tool_ceiling"))
    }

    /// An older client must tolerate the new keys, and this client must tolerate
    /// a grant carrying a plane it has never heard of (SPEC §12) — the unknown
    /// plane stays bound in the signature and authorizes nothing.
    @Test func forwardCompatibleWithUnknownPlanes() throws {
        let alice = try Self.alice()
        let unknownPlane = StandingGrant(
            grantID: "g1", peer: Self.peerHex, planes: ["wall", "teleport"],
            budget: Self.budget, activeUntil: 1_756_000_000,
            enabledBy: alice.publicKeyData, sig: Data())
        let signed = StandingGrant(
            grantID: unknownPlane.grantID, peer: unknownPlane.peer,
            planes: unknownPlane.planes, budget: unknownPlane.budget,
            activeUntil: unknownPlane.activeUntil, enabledBy: alice.publicKeyData,
            sig: try alice.sign(
                StandingGrant.signatureMessage(
                    scopeTag: unknownPlane.scopeTag, activeUntil: unknownPlane.activeUntil,
                    enabledBy: alice.publicKeyData)))
        #expect(signed.hasValidSignature() == true)  // verifies despite the unknown plane
        #expect(signed.knownPlanes == [.wall])  // …but only `wall` can ever gate
        #expect(signed.covers(.delegate) == false)

        // Round-trips without loss, so a newer peer still sees "teleport".
        let data = try WireJSON.encoder().encode(signed)
        let decoded = try WireJSON.decoder().decode(StandingGrant.self, from: data)
        #expect(decoded.planes == ["wall", "teleport"])
        #expect(decoded.hasValidSignature() == true)
    }

    @Test func olderClientBodyDecodesWithoutTheNewKeys() throws {
        let json = #"{"text":"hi","sent_at":1,"surprise_field":42}"#
        let body = try WireJSON.decoder().decode(MessageBody.self, from: Data(json.utf8))
        #expect(body.standingGrant == nil)
        #expect(body.standingGrantRevocation == nil)
        #expect(body.text == "hi")
    }

    @Test func rumorTypeRawValuesAreStable() {
        #expect(RumorType.standingGrant.rawValue == "standing_grant")
        #expect(RumorType.standingGrantRevocation.rawValue == "standing_grant_revocation")
    }

    /// An agent-derived key signing a grant does not produce a valid grant: only
    /// the human identity key can (invariant 9, enforced again at the engine).
    @Test func agentKeyCannotProduceAValidGrant() throws {
        let bob = try Self.bob()
        let agentKey = try AgentKeyDeriver.deriveAgentKey(from: bob)
        let template = StandingGrant(
            grantID: "g1", peer: Self.peerHex, planes: ["wall"], budget: Self.budget,
            activeUntil: 1_756_000_000, enabledBy: bob.publicKeyData, sig: Data())
        let forged = StandingGrant(
            grantID: template.grantID, peer: template.peer, planes: template.planes,
            budget: template.budget, activeUntil: template.activeUntil,
            enabledBy: bob.publicKeyData,
            sig: try agentKey.signature(
                for: StandingGrant.signatureMessage(
                    scopeTag: template.scopeTag, activeUntil: template.activeUntil,
                    enabledBy: bob.publicKeyData)))
        #expect(forged.hasValidSignature() == false)
    }
}
