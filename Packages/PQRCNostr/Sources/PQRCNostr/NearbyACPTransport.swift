// SPDX-License-Identifier: Apache-2.0
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
/// - **Replay/reorder-protected per connection.** Each sealed frame's plaintext
///   is prefixed with a per-connection monotonic counter before sealing, so the
///   ChaChaPoly tag authenticates it (`SealCipher` takes no associated-data
///   parameter; folding the counter into the sealed plaintext IS the AD binding).
///   The receiver delivers a frame only if its counter is strictly greater than
///   the last accepted on that connection — a captured frame re-injected by an
///   on-link attacker (same counter) or a reordered/earlier frame (lower
///   counter) is dropped, never handed to the ACP layer. The relay path gets
///   anti-replay from the Double Ratchet; this local seal has no ratchet under
///   it, so the counter supplies it.
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

    /// Per-connection send counter, prefixed into each frame's plaintext before
    /// sealing so the AEAD tag covers it (replay/reorder protection — see
    /// `FrameCounter`). The first frame on a connection carries counter 0; it
    /// increments by one per sealed frame in send order and resets to 0 on
    /// disconnect (a new connection re-runs the hello, so the receiver resets its
    /// expected counter in lockstep — see `lastAcceptedCounter`).
    private var sendCounter: UInt64 = 0

    /// Highest frame counter accepted from the proven peer on THIS connection.
    /// A frame is delivered only if its (tag-authenticated) counter is strictly
    /// greater — so a replayed frame (equal counter) or a reordered/earlier one
    /// (lower counter) is dropped, never handed to the ACP layer. `nil` until the
    /// first frame is accepted; reset on disconnect so the next connection's
    /// counter stream starts fresh.
    private var lastAcceptedCounter: UInt64?

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
        // Prefix a per-connection monotonic counter onto the ACP line, then seal
        // the WHOLE thing. `SealCipher` (pqrc-seal-v1 ChaChaPoly over a secp256k1
        // ECDH key) takes no associated-data parameter, so folding the counter
        // into the sealed plaintext is how we bind it into the AEAD: the
        // ChaChaPoly tag now covers the counter, so a frame whose counter is
        // tampered, stripped, or rewritten fails the tag and is dropped. (A bare
        // envelope counter would be unauthenticated — an injector could rewrite
        // it — so the counter lives ONLY inside the seal, never on the wire in
        // the clear.) The receiver re-derives replay/reorder trust from this
        // authenticated copy in `acceptCounter(_:)`.
        let counter = sendCounter
        let framed = FrameCounter.prefix(counter, onto: line)
        guard let sealed = try? SealCipher.encrypt(
            framed, privateKey: nostrKeypair.privateKeyData,
            peerPublicKeyHex: peerNostrPubkeyHex, nonceSource: nonceSource)
        else {
            droppedFrameCount += 1
            return
        }
        // Advance only after a successful seal so a transient seal failure does
        // not burn a counter value (which the receiver would then see as a gap;
        // gaps are tolerated — strictly-increasing is the rule — but no reason to
        // create them).
        sendCounter = counter + 1
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
                // The frame-counter stream is per-connection: a fresh connection
                // re-runs the hello and starts its sender counter at 0, so the
                // receiver MUST forget the old window or it would reject the new
                // connection's early (lower-numbered) frames as replays.
                sendCounter = 0
                lastAcceptedCounter = nil
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
                    sealed, privateKey: nostrKeypair.privateKeyData, peerPublicKeyHex: peerNostr),
                // Split the tag-authenticated counter prefix off the ACP line. A
                // malformed prefix means the sealed bytes weren't produced by a
                // counter-prefixing sender → drop (don't deliver raw to ACP).
                let (counter, line) = FrameCounter.split(plaintext)
            else {
                droppedFrameCount += 1
                return
            }
            // Replay/reorder gate: the counter is authenticated by the AEAD tag
            // (it's inside the seal), so a recorded frame an attacker re-injects
            // carries its original counter — which is now ≤ the last we accepted
            // and is rejected here. A reordered (earlier) frame is rejected the
            // same way. Only a strictly-increasing counter advances the window
            // and reaches the ACP layer.
            guard acceptCounter(counter) else {
                droppedFrameCount += 1
                return
            }
            inboundContinuation.yield(line)
        }
    }

    /// Replay/reorder check for an inbound frame's (tag-authenticated) counter.
    /// Returns `true` and advances the window only when `counter` is strictly
    /// greater than the highest accepted on this connection; returns `false`
    /// (caller drops the frame) for an equal counter (replay) or a lower one
    /// (reorder / late duplicate). Actor-isolated, so the window is mutated
    /// race-free under Swift 6 strict concurrency.
    private func acceptCounter(_ counter: UInt64) -> Bool {
        if let last = lastAcceptedCounter, counter <= last { return false }
        lastAcceptedCounter = counter
        return true
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
        sendCounter = 0
        lastAcceptedCounter = nil
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

// MARK: - Frame counter codec (replay/reorder protection)

/// Encodes/decodes the per-connection monotonic counter that prefixes every
/// sealed ACP frame's plaintext. Because the counter is sealed WITH the ACP line
/// (and `SealCipher` exposes no associated-data parameter), the ChaChaPoly tag
/// authenticates it — so the receiver can trust the decoded counter to reject
/// replays and reorders (`NearbyACPTransport.acceptCounter`).
///
/// Layout: 8-byte big-endian counter || UTF-8 ACP line. A fixed-width binary
/// prefix is unambiguous (no delimiter the ACP JSON could collide with) and the
/// ACP line bytes are carried verbatim, so the round trip is byte-exact.
enum FrameCounter {
    /// Width of the big-endian counter prefix, in bytes.
    static let width = 8

    /// Sealed-plaintext bytes for `line` carrying `counter` as an 8-byte
    /// big-endian prefix.
    static func prefix(_ counter: UInt64, onto line: String) -> Data {
        var out = Data(capacity: width + line.utf8.count)
        withUnsafeBytes(of: counter.bigEndian) { out.append(contentsOf: $0) }
        out.append(Data(line.utf8))
        return out
    }

    /// Splits a decrypted frame back into its counter and ACP line, or `nil` if
    /// the bytes are too short to carry an 8-byte prefix (a malformed frame the
    /// caller must drop, not deliver).
    static func split(_ plaintext: Data) -> (counter: UInt64, line: String)? {
        guard plaintext.count >= width else { return nil }
        let counter = plaintext.prefix(width).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let line = String(decoding: plaintext.dropFirst(width), as: UTF8.self)
        return (counter, line)
    }
}
