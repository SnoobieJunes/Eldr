// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import EldrNodeCore
@testable import PQRCCore

// WS-G4 → WS-G1 integration: the `StandingGrant`-backed `TownAuthorizer`. `TownA2APlaneTests`
// proves the town GATE (that it is not C-3, deny-all by default, reachable only when both
// switches are thrown). THIS suite proves the grant-backed AUTHORIZER that populates that
// gate the §13-shaped way: a peer is admitted iff the owner currently holds a live, validly
// signed `standing_grant` naming that peer on the delegation plane — and every way that can
// lapse (expiry, revocation-by-absence, wrong peer, wrong plane, a peer self-signing, a
// tampered signature) fails closed. Nothing here touches a network, a clock, or a Keychain.

#if os(macOS)

@Suite("WS-G4→G1 StandingGrantTownAuthorizer", .tags(.security))
struct StandingGrantTownAuthorizerTests {
    static let day = PQRCConstants.secondsPerDay

    /// Owner (the node's human) + a peer town + a stranger, all deterministic off seeds.
    static func parties() throws -> (owner: PQRCIdentity, peer: PQRCIdentity, stranger: PQRCIdentity) {
        (
            try PQRCIdentity(seed: nodeHex(String(repeating: "a1", count: 32))),
            try PQRCIdentity(seed: nodeHex(String(repeating: "b2", count: 32))),
            try PQRCIdentity(seed: nodeHex(String(repeating: "c3", count: 32)))
        )
    }

    static func budget() -> StandingGrant.Budget {
        StandingGrant.Budget(messagesPerDay: 100, bytesPerDay: 100_000, maxConcurrentTasks: 4)
    }

    /// A grant the OWNER signs authorizing `peer` on the given planes, expiring `days` out
    /// from `issuedAt`.
    static func grant(
        from owner: PQRCIdentity, to peer: PQRCIdentity, planes: [StandingGrant.Plane] = [.delegate],
        issuedAt: Int64 = 1_756_000_000, days: Int64 = 7, grantID: String = "g1"
    ) throws -> StandingGrant {
        try StandingGrant.make(
            grantID: grantID, peer: peer.publicKeyData.hexString, planes: planes,
            budget: budget(), activeUntil: issuedAt + days * day, identity: owner)
    }

    /// The production shape: pin the granter to the owner, clock fixed mid-grant.
    static func authorizer(
        ownerHex: String?, now: Int64 = 1_756_000_500, plane: StandingGrant.Plane = .delegate,
        grants: @escaping @Sendable () -> [StandingGrant]
    ) -> StandingGrantTownAuthorizer {
        StandingGrantTownAuthorizer(
            plane: plane, requiredGranterHex: ownerHex, now: { now }, liveGrants: { grants() })
    }

    // MARK: - The positive case (so every refusal below is non-vacuous)

    @Test func liveOwnerSignedDelegateGrantAdmitsThePeer() async throws {
        let (owner, peer, _) = try Self.parties()
        let g = try Self.grant(from: owner, to: peer)
        let auth = Self.authorizer(ownerHex: owner.publicKeyData.hexString) { [g] }
        #expect(await auth.authorizes(peerIdentityHex: peer.publicKeyData.hexString))
    }

    // MARK: - Expiry (message-driven, from the injected clock)

    @Test func anExpiredGrantIsRefused() async throws {
        let (owner, peer, _) = try Self.parties()
        let issued: Int64 = 1_756_000_000
        let g = try Self.grant(from: owner, to: peer, issuedAt: issued, days: 1)
        let auth = Self.authorizer(
            ownerHex: owner.publicKeyData.hexString, now: issued + Self.day + 1) { [g] }
        #expect(await auth.authorizes(peerIdentityHex: peer.publicKeyData.hexString) == false)
    }

    @Test func exactlyAtExpiryIsAlreadyExpired() async throws {
        let (owner, peer, _) = try Self.parties()
        let issued: Int64 = 1_756_000_000
        let g = try Self.grant(from: owner, to: peer, issuedAt: issued, days: 1)
        // activeUntil == now: the convention is "> now", so this is expired.
        let auth = Self.authorizer(
            ownerHex: owner.publicKeyData.hexString, now: issued + Self.day) { [g] }
        #expect(await auth.authorizes(peerIdentityHex: peer.publicKeyData.hexString) == false)
    }

    // MARK: - Revocation modeled as absence (the per-frame re-read)

    @Test func revocationBitesOnTheNextFrameByDisappearingFromTheSet() async throws {
        let (owner, peer, _) = try Self.parties()
        let g = try Self.grant(from: owner, to: peer)
        // A mutable box the closure reads each call: the authorizer re-invokes `liveGrants`
        // per frame, so removing the grant (what revocation does upstream) denies the very
        // next call with no cache to clear.
        let box = GrantBox(grants: [g])
        let auth = StandingGrantTownAuthorizer(
            requiredGranterHex: owner.publicKeyData.hexString, now: { 1_756_000_500 },
            liveGrants: { await box.current() })
        let peerHex = peer.publicKeyData.hexString
        #expect(await auth.authorizes(peerIdentityHex: peerHex))
        await box.clear()
        #expect(await auth.authorizes(peerIdentityHex: peerHex) == false)
    }

    // MARK: - Scope: wrong peer, wrong plane

    @Test func aGrantForAnotherPeerDoesNotAdmitThisOne() async throws {
        let (owner, peer, stranger) = try Self.parties()
        let g = try Self.grant(from: owner, to: peer)  // names peer, not stranger
        let auth = Self.authorizer(ownerHex: owner.publicKeyData.hexString) { [g] }
        #expect(await auth.authorizes(peerIdentityHex: stranger.publicKeyData.hexString) == false)
    }

    @Test func aWallOnlyGrantDoesNotOpenTheDelegationPlane() async throws {
        let (owner, peer, _) = try Self.parties()
        let wallOnly = try Self.grant(from: owner, to: peer, planes: [.wall])
        // Default authorizer plane is .delegate — a wall-only grant must not cover it.
        let auth = Self.authorizer(ownerHex: owner.publicKeyData.hexString) { [wallOnly] }
        #expect(await auth.authorizes(peerIdentityHex: peer.publicKeyData.hexString) == false)
    }

    @Test func aBothPlanesGrantOpensEither() async throws {
        let (owner, peer, _) = try Self.parties()
        let both = try Self.grant(from: owner, to: peer, planes: [.wall, .delegate])
        let peerHex = peer.publicKeyData.hexString
        let asDelegate = Self.authorizer(ownerHex: owner.publicKeyData.hexString, plane: .delegate) { [both] }
        let asWall = Self.authorizer(ownerHex: owner.publicKeyData.hexString, plane: .wall) { [both] }
        #expect(await asDelegate.authorizes(peerIdentityHex: peerHex))
        #expect(await asWall.authorizes(peerIdentityHex: peerHex))
    }

    // MARK: - The load-bearing fail-closed: a peer cannot self-authorize

    @Test func aPeerSelfSignedGrantIsRefusedWhenTheGranterIsPinned() async throws {
        let (owner, peer, _) = try Self.parties()
        // The PEER signs a grant naming itself — a valid signature over its OWN enabled_by.
        // Without the granter pin this would verify and admit (self-authorization); with the
        // owner pin it is refused because enabled_by != owner.
        let selfSigned = try StandingGrant.make(
            grantID: "evil", peer: peer.publicKeyData.hexString, planes: [.delegate],
            budget: Self.budget(), activeUntil: 1_756_000_000 + 7 * Self.day, identity: peer)
        let auth = Self.authorizer(ownerHex: owner.publicKeyData.hexString) { [selfSigned] }
        #expect(await auth.authorizes(peerIdentityHex: peer.publicKeyData.hexString) == false)
    }

    @Test func aGrantFromAThirdPartyIsRefusedWhenTheGranterIsPinned() async throws {
        let (owner, peer, stranger) = try Self.parties()
        // A stranger signs a grant naming the peer — verifies against the stranger's key, but
        // the owner never authorized it. Pinned to owner ⇒ refused.
        let g = try Self.grant(from: stranger, to: peer)
        let auth = Self.authorizer(ownerHex: owner.publicKeyData.hexString) { [g] }
        #expect(await auth.authorizes(peerIdentityHex: peer.publicKeyData.hexString) == false)
    }

    // MARK: - Tampering fails the signature re-check

    @Test func aTamperedExpiryFailsTheSignatureRecheck() async throws {
        let (owner, peer, _) = try Self.parties()
        let g = try Self.grant(from: owner, to: peer, days: 1)
        // Extend the expiry far into the future WITHOUT re-signing: the signature was over the
        // original activeUntil, so it no longer verifies. hasValidSignature() catches it.
        let forged = StandingGrant(
            grantID: g.grantID, peer: g.peer, planes: g.planes, budget: g.budget,
            activeUntil: g.activeUntil + 3650 * Self.day, enabledBy: g.enabledBy, sig: g.sig)
        let auth = Self.authorizer(
            ownerHex: owner.publicKeyData.hexString, now: 1_756_000_000 + 500) { [forged] }
        #expect(await auth.authorizes(peerIdentityHex: peer.publicKeyData.hexString) == false)
    }

    @Test func aTamperedPeerFailsTheSignatureRecheck() async throws {
        let (owner, peer, stranger) = try Self.parties()
        let g = try Self.grant(from: owner, to: peer)
        // Repoint the grant at the stranger without re-signing — the scope tag (and thus the
        // signed bytes) changes, so the owner's signature no longer verifies.
        let forged = StandingGrant(
            grantID: g.grantID, peer: stranger.publicKeyData.hexString, planes: g.planes,
            budget: g.budget, activeUntil: g.activeUntil, enabledBy: g.enabledBy, sig: g.sig)
        let auth = Self.authorizer(ownerHex: owner.publicKeyData.hexString) { [forged] }
        #expect(await auth.authorizes(peerIdentityHex: stranger.publicKeyData.hexString) == false)
    }

    // MARK: - Degenerate inputs

    @Test func emptyPeerAndEmptyGrantSetAreRefused() async throws {
        let (owner, peer, _) = try Self.parties()
        let g = try Self.grant(from: owner, to: peer)
        let auth = Self.authorizer(ownerHex: owner.publicKeyData.hexString) { [g] }
        #expect(await auth.authorizes(peerIdentityHex: "") == false)
        #expect(await auth.authorizes(peerIdentityHex: "   ") == false)
        let none = Self.authorizer(ownerHex: owner.publicKeyData.hexString) { [] }
        #expect(await none.authorizes(peerIdentityHex: peer.publicKeyData.hexString) == false)
    }

    /// Multiple grants, only one of which is the live matching one — the scan must find it and
    /// must not be tricked by the decoys (expired, wrong peer, wrong plane).
    @Test func theRightGrantIsFoundAmongDecoys() async throws {
        let (owner, peer, stranger) = try Self.parties()
        let issued: Int64 = 1_756_000_000
        let expired = try Self.grant(from: owner, to: peer, issuedAt: issued - 30 * Self.day, days: 1, grantID: "old")
        let wrongPeer = try Self.grant(from: owner, to: stranger, grantID: "other")
        let wrongPlane = try Self.grant(from: owner, to: peer, planes: [.wall], grantID: "wall")
        let good = try Self.grant(from: owner, to: peer, issuedAt: issued, days: 7, grantID: "good")
        let auth = Self.authorizer(
            ownerHex: owner.publicKeyData.hexString, now: issued + 500) { [expired, wrongPeer, wrongPlane, good] }
        #expect(await auth.authorizes(peerIdentityHex: peer.publicKeyData.hexString))
    }
}

/// A mutable, actor-guarded grant set, so a test can model revocation as removal between two
/// authorization calls.
private actor GrantBox {
    private var grants: [StandingGrant]
    init(grants: [StandingGrant]) { self.grants = grants }
    func current() -> [StandingGrant] { grants }
    func clear() { grants = [] }
}

#endif  // os(macOS)
