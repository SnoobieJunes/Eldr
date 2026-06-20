import Crypto
import Foundation
import PQRCACP
import PQRCCore

/// A **sealed** `ACPTransport` over any `NearbyLink` (ACPRouterplan P-4/P-8).
///
/// The phone↔Mac ACP channel carries `session/prompt` turns, file reads/writes,
/// permission requests, shell output — exactly the things that must never cross
/// a radio in the clear. `InMemoryACPTransport` (in PQRCACP) is plaintext, for
/// tests; the real link must not trust the socket. This wraps a `NearbyLink`
/// (MultipeerConnectivity in production, the LAN/loopback `SimulatedNearbyLink`
/// under test — both conform to `NearbyLink`, so ONE type covers both backends)
/// and gives each ACP line confidentiality + authenticity:
///
/// - **Sealed per line.** Every outbound ACP line is encrypted with `SealCipher`
///   — the SAME `pqrc-seal-v1` AEAD the message mesh's kind-13 seal layer uses
///   (`MultipeerLinkTransport`): a secp256k1 ECDH conversation key (HKDF), then
///   ChaChaPoly. No new crypto is invented (SPEC §2); the ACP line is just a
///   different plaintext fed through the existing seal. Inbound frames are
///   unsealed back into the `inboundLines()` stream.
/// - **Paired-peer-only, authenticated.** Before any ACP frame flows, the peer
///   completes the SAME challenge-response hello the mesh uses
///   (`MultipeerLinkTransport`): each side claims its Ed25519 PQRC identity and
///   proves it by signing the other's fresh random challenge. The hello here
///   ALSO binds the secp256k1 Nostr key used for sealing into that signed proof,
///   so the AEAD key is authenticated by the identity key — an anonymous
///   man-in-the-middle on the radio cannot substitute its own sealing key
///   without failing the proof. Frames from an unproven/forged peer are dropped.
///
/// Trust model mirrors `MultipeerLinkTransport`: the radio link authenticates
/// nobody (MultipeerConnectivity encrypts with anonymous keys), so confidentiality
/// and authenticity rest entirely on the seal + the identity-signed hello, never
/// on the link. A compromised link can at worst drop frames.
public actor NearbyACPTransport: ACPTransport {
    /// Our long-term Ed25519 PQRC identity — proves who we are in the hello.
    private let identity: PQRCIdentity
    /// Our secp256k1 Nostr keypair — the seal's ECDH private half. The mesh
    /// seals to/from these same keys; here it keys the per-line ACP frames.
    private let nostrKeypair: NostrKeypair
    /// The radio link we send sealed frames over / receive them from.
    private let link: any NearbyLink
    /// The single peer this ACP transport talks to, by its Ed25519 identity
    /// pubkey (raw 32 bytes). ACP is point-to-point (one client ↔ one agent), so
    /// frames are only ever sealed to / accepted from THIS peer.
    private let peerIdentityKey: Data
    private let randomSource: any RandomSource
    private let nonceSource: any NonceSource

    private var started = false
    private var pumpTask: Task<Void, Never>?

    /// The challenge we issued the peer on connect, awaiting its proof. Consumed
    /// on the first proof attempt, so a failed proof can't be retried.
    private var issuedChallenge: Data?
    /// The peer's link handle + its proven Nostr sealing pubkey, set once the
    /// hello proof verifies. `nil` until then → no ACP frame is sealed or
    /// accepted (don't-trust-the-socket).
    private var peer: NearbyPeerID?
    private var peerNostrPubkeyHex: String?

    /// Outbound ACP lines that arrived (via the synchronous `send`) before the
    /// peer finished proving itself. Flushed, in order, the instant it does —
    /// so a caller need not block on the hello.
    private var pendingOutbound: [String] = []

    /// The inbound ACP-line stream handed to the ACP client/agent. Sealed frames
    /// are unsealed into here.
    private let inbound: AsyncStream<String>
    private let inboundContinuation: AsyncStream<String>.Continuation

    /// Frames rejected by unseal / proof / decode, for test introspection. The
    /// values themselves are NEVER logged (CLAUDE.md invariant 12).
    public private(set) var droppedFrameCount = 0

    /// Whether the peer has completed the hello and is proven — i.e. ACP frames
    /// now flow. Presence/readiness signal for callers and tests.
    public func isPeerProven() -> Bool { peer != nil && peerNostrPubkeyHex != nil }

    public init(
        identity: PQRCIdentity,
        nostrKeypair: NostrKeypair,
        link: any NearbyLink,
        peerIdentityKey: Data,
        randomSource: any RandomSource,
        nonceSource: any NonceSource
    ) {
        self.identity = identity
        self.nostrKeypair = nostrKeypair
        self.link = link
        self.peerIdentityKey = peerIdentityKey
        self.randomSource = randomSource
        self.nonceSource = nonceSource
        (self.inbound, self.inboundContinuation) = AsyncStream.makeStream(of: String.self)
    }

    // MARK: Lifecycle

    /// Starts the link and the event pump. Idempotent. Call before driving the
    /// ACP client/agent so no early connection event is missed.
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

    // MARK: ACPTransport

    /// Queue one ACP line for sealed delivery. Synchronous + Sendable per the
    /// `ACPTransport` contract (it may be called from inside a JSON-RPC
    /// continuation without `await`). The actual seal+send happens on a hop
    /// onto this actor; ordering follows call order because each hop is enqueued
    /// in turn and `pendingOutbound` preserves arrival order until the peer is
    /// proven.
    public nonisolated func send(_ line: String) {
        Task { await self.enqueue(line) }
    }

    public nonisolated func inboundLines() -> AsyncStream<String> { inbound }

    public nonisolated func close() {
        Task { await self.shutdown() }
    }

    // MARK: Outbound

    private func enqueue(_ line: String) async {
        guard started else { return }
        // Hold lines until the peer has proven itself: an ACP frame must never
        // be sealed to (or routed at) an unauthenticated peer.
        guard let peer, let peerNostrPubkeyHex else {
            pendingOutbound.append(line)
            return
        }
        await sealAndSend(line, to: peer, peerNostrPubkeyHex: peerNostrPubkeyHex)
    }

    private func sealAndSend(_ line: String, to peer: NearbyPeerID, peerNostrPubkeyHex: String) async {
        // The ACP line is the plaintext fed through the EXACT mesh seal
        // (`SealCipher` = pqrc-seal-v1 ChaChaPoly over a secp256k1 ECDH key).
        guard let sealed = try? SealCipher.encrypt(
            Data(line.utf8), privateKey: nostrKeypair.privateKeyData,
            peerPublicKeyHex: peerNostrPubkeyHex, nonceSource: nonceSource)
        else {
            droppedFrameCount += 1
            return
        }
        await sendPayload(ACPLinkPayload(kind: .frame, frame: sealed), to: peer)
    }

    private func flushPending(to peer: NearbyPeerID, peerNostrPubkeyHex: String) async {
        let queued = pendingOutbound
        pendingOutbound.removeAll()
        for line in queued {
            await sealAndSend(line, to: peer, peerNostrPubkeyHex: peerNostrPubkeyHex)
        }
    }

    // MARK: Event pump

    private func handle(_ event: NearbyLinkEvent) async {
        switch event {
        case .connected(let peer):
            // Fresh challenge per connection, sent with our identity + sealing
            // pubkey claim. Symmetric: both sides do this, both end up holding a
            // proof from the other.
            let challenge = randomSource.bytes(32)
            issuedChallenge = challenge
            await sendPayload(
                ACPLinkPayload(
                    kind: .hello,
                    identity: identity.publicKeyData,
                    nostrPubkey: Data(hexString: nostrKeypair.publicKeyHex),
                    challenge: challenge),
                to: peer)
        case .disconnected(let downed):
            if downed == peer {
                peer = nil
                peerNostrPubkeyHex = nil
            }
            issuedChallenge = nil
        case .data(let data, let from):
            guard let payload = try? WireJSON.decoder().decode(ACPLinkPayload.self, from: data) else {
                droppedFrameCount += 1
                return
            }
            await handlePayload(payload, from: from)
        }
    }

    private func handlePayload(_ payload: ACPLinkPayload, from: NearbyPeerID) async {
        switch payload.kind {
        case .hello:
            // Answer the peer's challenge with a signature by OUR identity key
            // that also commits to OUR sealing (Nostr) pubkey — binding the AEAD
            // key to the identity. The peer's own identity claim here is ignored;
            // only its separately-arriving signed proof attaches identity.
            guard let challenge = payload.challenge,
                let proof = try? identity.sign(
                    ACPLinkPayload.helloProofMessage(
                        identity: identity.publicKeyData,
                        nostrPubkey: Data(hexString: nostrKeypair.publicKeyHex) ?? Data(),
                        challenge: challenge))
            else {
                droppedFrameCount += 1
                return
            }
            await sendPayload(
                ACPLinkPayload(
                    kind: .helloProof,
                    identity: identity.publicKeyData,
                    nostrPubkey: Data(hexString: nostrKeypair.publicKeyHex),
                    sig: proof),
                to: from)
        case .helloProof:
            // Consume the challenge first: exactly one proof attempt per
            // connection, valid or not.
            guard let challenge = issuedChallenge else {
                droppedFrameCount += 1
                return
            }
            issuedChallenge = nil
            guard let claimedIdentity = payload.identity,
                let claimedNostr = payload.nostrPubkey, claimedNostr.count == 32,
                let sig = payload.sig,
                // It must be the EXACT peer this ACP transport is paired with —
                // not just any prover (point-to-point, paired-peer-only).
                claimedIdentity == peerIdentityKey,
                PQRCIdentity.verify(
                    signature: sig,
                    message: ACPLinkPayload.helloProofMessage(
                        identity: claimedIdentity, nostrPubkey: claimedNostr, challenge: challenge),
                    publicKey: claimedIdentity)
            else {
                droppedFrameCount += 1
                return
            }
            // Proven. Record the peer + its identity-bound sealing key, then
            // release any ACP lines that were waiting on the hello.
            peer = from
            let peerNostr = claimedNostr.hexString
            peerNostrPubkeyHex = peerNostr
            await flushPending(to: from, peerNostrPubkeyHex: peerNostr)
        case .frame:
            // Accept sealed ACP frames ONLY from the proven peer, and unseal with
            // its identity-bound sealing key. Anything else is noise on a public
            // radio. A tampered frame fails ChaChaPoly's tag → dropped, channel
            // survives.
            guard let provenPeer = peer, provenPeer == from,
                let peerNostr = peerNostrPubkeyHex,
                let sealed = payload.frame,
                let plaintext = try? SealCipher.decrypt(
                    sealed, privateKey: nostrKeypair.privateKeyData, peerPublicKeyHex: peerNostr)
            else {
                droppedFrameCount += 1
                return
            }
            inboundContinuation.yield(String(decoding: plaintext, as: UTF8.self))
        }
    }

    private func sendPayload(_ payload: ACPLinkPayload, to peer: NearbyPeerID) async {
        guard let data = try? WireJSON.encoder().encode(payload) else { return }
        // Hello/frame sends are best-effort at the link layer: a failed send means
        // the connection already died; the next `.connected` restarts the hello.
        try? await link.send(data, to: peer)
    }

    private func shutdown() async {
        guard started else { return }
        started = false
        pumpTask?.cancel()
        pumpTask = nil
        await link.stop()
        issuedChallenge = nil
        peer = nil
        peerNostrPubkeyHex = nil
        pendingOutbound.removeAll()
        inboundContinuation.finish()
    }
}

// MARK: - Link wire payload

/// Payloads exchanged over the raw link for the sealed ACP channel. JSON with
/// stable snake_case field names (repo-wide wire convention); unknown fields are
/// tolerated by construction (forward compatibility, SPEC §12). Deliberately
/// distinct from `LinkPayload` (the message-mesh wire) so an ACP frame and a
/// mesh seal can never be confused on the wire, and so the two hello proofs use
/// different domain separation.
struct ACPLinkPayload: Codable, Sendable {
    enum Kind: String, Codable {
        /// Identity + sealing-key claim + fresh anti-replay challenge, on connect.
        case hello
        /// Signed answer proving ownership of the claimed identity AND binding the
        /// claimed sealing (Nostr) key to it.
        case helloProof = "hello_proof"
        /// One sealed ACP line (the `SealCipher` base64 frame).
        case frame
    }

    var kind: Kind
    /// `hello`/`helloProof`: sender's Ed25519 PQRC identity pubkey (32 bytes).
    var identity: Data?
    /// `hello`/`helloProof`: sender's secp256k1 Nostr pubkey (32 bytes, x-only)
    /// used for the seal ECDH. Bound into the proof so the AEAD key is
    /// authenticated by the identity key.
    var nostrPubkey: Data?
    /// `hello`: fresh random 32-byte challenge the receiver must sign back.
    var challenge: Data?
    /// `helloProof`: Ed25519 signature over `helloProofMessage`.
    var sig: Data?
    /// `frame`: the `SealCipher` base64 ciphertext of one ACP line.
    var frame: String?

    enum CodingKeys: String, CodingKey {
        case kind, identity
        case nostrPubkey = "nostr_pubkey"
        case challenge, sig, frame
    }

    /// Domain-separated proof message: "pqrc-acp-hello-v1" prevents this proof
    /// from being confused with the mesh hello ("pqrc-local-hello-v1") or any
    /// other PQRC signature, binds it to THIS connection via the fresh challenge
    /// (captured proofs can't be replayed), AND commits to the sealing key so a
    /// MITM can't swap in its own AEAD key under a stolen identity claim.
    static func helloProofMessage(identity: Data, nostrPubkey: Data, challenge: Data) -> Data {
        Data("pqrc-acp-hello-v1".utf8) + identity + nostrPubkey + challenge
    }
}
