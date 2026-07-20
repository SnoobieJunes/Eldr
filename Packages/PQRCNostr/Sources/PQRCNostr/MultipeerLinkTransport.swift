// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import PQRCCore

// MARK: - NearbyLink seam

/// Opaque link-level peer handle. In production this is the random
/// `MCPeerID.displayName`; in tests it is a simulator-assigned name. It is
/// deliberately NOT an identity: identities are only attached to peers after
/// the signed hello exchange below.
public struct NearbyPeerID: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// Lifecycle + data events surfaced by a nearby radio link.
public enum NearbyLinkEvent: Sendable {
    case connected(NearbyPeerID)
    case disconnected(NearbyPeerID)
    case data(Data, from: NearbyPeerID)
}

/// The determinism seam under `MultipeerLinkTransport` (TEST-PLAN §1):
/// production injects `MultipeerNearbyLink` (MultipeerConnectivity); tests
/// inject links vended by `LocalLinkSimulator`. Everything above this
/// protocol — framing, peer verification, routing, fallback — is exercised
/// headlessly; only the thin MC adapter below it needs real radios.
public protocol NearbyLink: Sendable {
    /// Begin discovering peers. Events flow on `events()` after this.
    func start() async throws
    /// Tear down discovery and all connections.
    func stop() async
    /// Single-consumer stream of link events.
    func events() async -> AsyncStream<NearbyLinkEvent>
    /// Reliable, in-order delivery of one payload to a connected peer.
    func send(_ data: Data, to peer: NearbyPeerID) async throws
}

// MARK: - Link wire payloads

/// Payloads exchanged over the raw link. JSON with stable snake_case field
/// names, matching the repo-wide wire conventions. Unknown fields are
/// tolerated by construction (forward compatibility, SPEC §12).
struct LinkPayload: Codable, Sendable {
    enum Kind: String, Codable {
        /// Identity claim + fresh anti-replay challenge, sent on connect.
        case hello
        /// Signed answer proving ownership of the claimed identity.
        case helloProof = "hello_proof"
        /// A kind-13 seal event (the actual message traffic).
        case seal
        /// Our signed kind-10420 binding + prekey bundle, so a co-present peer
        /// can verify and add us with no relay (SPEC §10). Sent only after the
        /// hello proof, i.e. to a peer that proved its own identity.
        case bundle
    }

    var kind: Kind
    /// `hello`/`helloProof`: the sender's Ed25519 PQRC identity pubkey (32 bytes).
    var identity: Data?
    /// `hello`: fresh random 32-byte challenge the receiver must sign back.
    var challenge: Data?
    /// `helloProof`: Ed25519 signature over `helloProofMessage`.
    var sig: Data?
    /// `seal`: the seal event, JSON-encoded with the standard event codec.
    var seal: Data?
    /// `bundle`: JSON-encoded `BundleAnnouncement`.
    var bundle: Data?

    /// Domain-separated proof message: prevents a hello proof from being
    /// confused with any other PQRC signature ("pqrc-agent-msg-v1",
    /// "pqrc-ai-window-v1", …) and binds it to THIS connection via the fresh
    /// challenge, so captured proofs cannot be replayed to impersonate a peer.
    static func helloProofMessage(identity: Data, challenge: Data) -> Data {
        Data("pqrc-local-hello-v1".utf8) + identity + challenge
    }
}

/// The contents of a `.bundle` payload: a peer's signed kind-10420 binding
/// event plus its prekey bundle. Both are signature-self-verifying, so a
/// receiver can establish trust offline (no relay) exactly as it would from
/// relay-fetched copies.
struct BundleAnnouncement: Codable, Sendable {
    let bindingEvent: NostrEvent
    let prekeyBundle: PrekeyBundle

    enum CodingKeys: String, CodingKey {
        case bindingEvent = "binding_event"
        case prekeyBundle = "prekey_bundle"
    }
}

// MARK: - Transport

/// SPEC §10 local-first transport (stretch goal S1), implemented over any
/// `NearbyLink`.
///
/// Trust model:
/// - The radio link authenticates NOBODY (MultipeerConnectivity encrypts with
///   anonymous keys, so an active man-in-the-middle is always possible).
/// - Identity→peer routing therefore rests on a challenge-response hello: each
///   side claims its PQRC identity pubkey and proves it by signing the other
///   side's fresh random challenge with the identity key. Claiming someone
///   else's identity fails at the proof step, so an attacker cannot attract
///   traffic addressed to a victim (sends to unproven identities fall back to
///   the relay path instead).
/// - Message confidentiality/authenticity never depends on the hello at all:
///   every payload is a kind-13 seal — signed by the sender's Nostr key and
///   encrypted to the recipient's Nostr key — and the ratchet beneath it
///   provides the real end-to-end guarantees. The hello exchange is purely a
///   routing/anti-annoyance layer; a compromised link can at worst drop
///   traffic, which the relay fallback absorbs.
public actor MultipeerLinkTransport: LocalLinkTransport {
    private let identity: PQRCIdentity
    private let link: any NearbyLink
    private let randomSource: any RandomSource

    private var started = false
    private var pumpTask: Task<Void, Never>?

    /// Challenges we issued, awaiting a proof from that peer. One per
    /// connection: consumed (removed) on first proof attempt, so a failed
    /// proof cannot be retried against the same challenge.
    private var issuedChallenges: [NearbyPeerID: Data] = [:]
    /// Both directions of the verified identity↔peer mapping.
    private var peerByIdentityHex: [String: NearbyPeerID] = [:]
    private var identityHexByPeer: [NearbyPeerID: String] = [:]

    /// Single-consumer delivery stream handed to the messenger.
    private let sealStream: AsyncStream<NostrEvent>
    private let sealContinuation: AsyncStream<NostrEvent>.Continuation

    /// Our own signed binding + prekey bundle to advertise to co-present peers
    /// (set by the messenger when the Nearby setting is on). nil = don't
    /// advertise; we still receive others' bundles.
    private var ownBundleBlob: Data?
    /// Stream of binding-verified nearby peers handed to the messenger.
    private let discoveredStream: AsyncStream<DiscoveredContact>
    private let discoveredContinuation: AsyncStream<DiscoveredContact>.Continuation
    /// Identities we've already surfaced this session — one discovery per peer.
    private var discoveredIdentityHexes: Set<String> = []

    /// Payloads rejected by verification/decoding, for test introspection —
    /// the values are never logged (CLAUDE.md invariant 12).
    public private(set) var droppedPayloadCount = 0

    public init(identity: PQRCIdentity, link: any NearbyLink, randomSource: any RandomSource) {
        self.identity = identity
        self.link = link
        self.randomSource = randomSource
        (self.sealStream, self.sealContinuation) = AsyncStream.makeStream(of: NostrEvent.self)
        (self.discoveredStream, self.discoveredContinuation) =
            AsyncStream.makeStream(of: DiscoveredContact.self)
    }

    // MARK: Lifecycle

    /// Starts the link and the event pump. Call before `PQRCMessenger.start()`
    /// so no early connection events are missed.
    public func start() async throws {
        guard !started else { return }
        started = true
        try await link.start()
        let events = await link.events()
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    public func stop() async {
        guard started else { return }
        started = false
        pumpTask?.cancel()
        pumpTask = nil
        await link.stop()
        issuedChallenges.removeAll()
        peerByIdentityHex.removeAll()
        identityHexByPeer.removeAll()
        discoveredIdentityHexes.removeAll()
        sealContinuation.finish()
        discoveredContinuation.finish()
    }

    // MARK: LocalLinkTransport

    public func send(_ seal: NostrEvent, to peerIdentity: Data) async throws {
        guard started else { throw LocalLinkError.linkNotStarted }
        // Route only to a peer that PROVED this identity. An unverified or
        // absent peer surfaces as `peerNotReachable`, which the messenger
        // translates into automatic relay fallback (SPEC §10).
        guard let peer = peerByIdentityHex[peerIdentity.hexString] else {
            throw LocalLinkError.peerNotReachable
        }
        let payload = LinkPayload(kind: .seal, seal: try WireJSON.encoder().encode(seal))
        do {
            try await link.send(try WireJSON.encoder().encode(payload), to: peer)
        } catch {
            // The peer vanished between lookup and send (walked out of radio
            // range). Drop the stale mapping and report unreachable so the
            // caller falls back to the relay rather than losing the message.
            unmap(peer)
            throw LocalLinkError.peerNotReachable
        }
    }

    public func incoming() async -> AsyncStream<NostrEvent> {
        sealStream
    }

    /// C7: number of co-present peers whose identity has proven out (the signed
    /// hello completed both ways) — drives the live "Nearby: N" indicator.
    /// Purely observational; never gates delivery.
    public var verifiedPeerCount: Int { peerByIdentityHex.count }

    public func advertiseOwnBundle(bindingEvent: NostrEvent, prekeyBundle: PrekeyBundle) async {
        let announcement = BundleAnnouncement(bindingEvent: bindingEvent, prekeyBundle: prekeyBundle)
        ownBundleBlob = try? WireJSON.encoder().encode(announcement)
        // Push to any peer already verified (they connected before we had our
        // bundle ready); new peers get it right after their hello proof.
        guard let blob = ownBundleBlob else { return }
        for peer in peerByIdentityHex.values {
            await sendPayload(LinkPayload(kind: .bundle, bundle: blob), to: peer)
        }
    }

    public func discoveredContacts() async -> AsyncStream<DiscoveredContact> {
        discoveredStream
    }

    /// Identities of currently connected-and-proven peers (presence UI, tests).
    public func reachableIdentities() -> Set<Data> {
        Set(peerByIdentityHex.keys.compactMap { Data(hexString: $0) })
    }

    // MARK: Event pump

    private func handle(_ event: NearbyLinkEvent) async {
        switch event {
        case .connected(let peer):
            // Fresh challenge per connection; sent alongside our own identity
            // claim. Both sides do this symmetrically, so each ends up holding
            // a proof from the other.
            let challenge = randomSource.bytes(32)
            issuedChallenges[peer] = challenge
            await sendPayload(
                LinkPayload(kind: .hello, identity: identity.publicKeyData, challenge: challenge),
                to: peer)
        case .disconnected(let peer):
            issuedChallenges[peer] = nil
            unmap(peer)
        case .data(let data, let peer):
            guard let payload = try? WireJSON.decoder().decode(LinkPayload.self, from: data) else {
                droppedPayloadCount += 1
                return
            }
            await handlePayload(payload, from: peer)
        }
    }

    private func handlePayload(_ payload: LinkPayload, from peer: NearbyPeerID) async {
        switch payload.kind {
        case .hello:
            guard let challenge = payload.challenge else {
                droppedPayloadCount += 1
                return
            }
            // Answer their challenge with a signature by OUR identity key.
            // (Their identity claim in the hello is ignored — only their
            // signed proof of it, arriving separately, attaches an identity.)
            guard let sig = try? identity.sign(
                LinkPayload.helloProofMessage(
                    identity: identity.publicKeyData, challenge: challenge))
            else {
                droppedPayloadCount += 1
                return
            }
            await sendPayload(
                LinkPayload(kind: .helloProof, identity: identity.publicKeyData, sig: sig),
                to: peer)
        case .helloProof:
            // Consume the challenge first: a peer gets exactly one proof
            // attempt per connection, valid or not.
            guard let challenge = issuedChallenges.removeValue(forKey: peer),
                let claimed = payload.identity, let sig = payload.sig,
                PQRCIdentity.verify(
                    signature: sig,
                    message: LinkPayload.helloProofMessage(identity: claimed, challenge: challenge),
                    publicKey: claimed)
            else {
                droppedPayloadCount += 1
                return
            }
            // Reconnects: the newest proven connection for an identity wins,
            // and any stale mapping for this peer handle is cleared.
            unmap(peer)
            if let stale = peerByIdentityHex[claimed.hexString] {
                unmap(stale)
            }
            peerByIdentityHex[claimed.hexString] = peer
            identityHexByPeer[peer] = claimed.hexString
            // The peer just proved its identity; if we're advertising (Nearby
            // on), hand it our signed binding + bundle so it can add us with
            // no relay. Symmetric — it does the same for us.
            if let blob = ownBundleBlob {
                await sendPayload(LinkPayload(kind: .bundle, bundle: blob), to: peer)
            }
        case .bundle:
            // A co-present peer's signed binding + prekey bundle. Accept only
            // from a hello-proven peer, then verify the binding in BOTH
            // directions and every prekey signature — identical to the relay
            // path (the relay was never a trust anchor). One discovery per
            // identity per session.
            guard let claimedHex = identityHexByPeer[peer],
                let blob = payload.bundle,
                let announcement = try? WireJSON.decoder().decode(BundleAnnouncement.self, from: blob),
                let (verified, raw) = try? PQRCEvents.verifyBindingEventWithRaw(announcement.bindingEvent),
                // The binding's identity MUST match the identity this peer proved
                // over the hello — otherwise a proven peer could hand us someone
                // else's binding.
                verified.identityPubkey.hexString == claimedHex,
                // Every prekey must be signed by that binding-verified identity
                // key (same check the relay path runs via verifyPrekeyBundleEvent).
                (try? announcement.prekeyBundle.verifySignatures(
                    identityPubkey: verified.identityPubkey)) != nil
            else {
                droppedPayloadCount += 1
                return
            }
            guard !discoveredIdentityHexes.contains(claimedHex) else { return }
            discoveredIdentityHexes.insert(claimedHex)
            discoveredContinuation.yield(
                DiscoveredContact(
                    contact: VerifiedContact(binding: verified, raw: raw),
                    bundle: announcement.prekeyBundle))
        case .seal:
            // Seals are accepted only from peers that completed the hello
            // proof — everyone else is noise on a public radio. The seal's own
            // signature/encryption is verified downstream by GiftWrap.unseal.
            guard identityHexByPeer[peer] != nil,
                let sealData = payload.seal,
                let seal = try? WireJSON.decoder().decode(NostrEvent.self, from: sealData)
            else {
                droppedPayloadCount += 1
                return
            }
            sealContinuation.yield(seal)
        }
    }

    private func sendPayload(_ payload: LinkPayload, to peer: NearbyPeerID) async {
        guard let data = try? WireJSON.encoder().encode(payload) else { return }
        // Hello traffic is best-effort: a failed send means the connection
        // already died, and the next .connected event restarts the exchange.
        try? await link.send(data, to: peer)
    }

    private func unmap(_ peer: NearbyPeerID) {
        if let identityHex = identityHexByPeer.removeValue(forKey: peer) {
            if peerByIdentityHex[identityHex] == peer {
                peerByIdentityHex[identityHex] = nil
            }
        }
    }
}
