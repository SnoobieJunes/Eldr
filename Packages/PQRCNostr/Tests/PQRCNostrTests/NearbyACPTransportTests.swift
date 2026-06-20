import Crypto
import Foundation
import PQRCACP
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// ACPRouterplan P-4/P-8: the phone↔Mac ACP channel must be sealed (every line
/// ciphertext) and paired-peer-only (don't trust the socket). `NearbyACPTransport`
/// wraps a `NearbyLink` with the message-mesh seal + the mesh's challenge-response
/// hello; this suite proves it end-to-end against `LocalLinkSimulator` — the
/// LAN/loopback `NearbyLink` backend, no real radios (TEST-PLAN §1). The SAME
/// transport runs over `MultipeerNearbyLink` in production (both are `NearbyLink`).
@Suite("Sealed ACP transport (ACPRouterplan P-4/P-8)", .tags(.transport, .security))
struct NearbyACPTransportTests {
    /// One endpoint of a sealed ACP transport pair: the transport, its link
    /// handle in the sim hub, and a collector draining its inbound ACP lines.
    struct Endpoint {
        let transport: NearbyACPTransport
        let peerID: NearbyPeerID
        let lines: ACPLineCollector
    }

    /// Builds Alice↔Bob sealed ACP transports over one `LocalLinkSimulator`,
    /// each pointed at the other's identity, both started and pumping. Returns
    /// once both have completed the hello (peer proven both directions), so a
    /// test can `send` immediately.
    static func makePair(
        hub: LocalLinkSimulator
    ) async throws -> (alice: Endpoint, bob: Endpoint) {
        let aliceIdentity = try PQRCIdentity(seed: hexData(String(repeating: "a1", count: 32)))
        let bobIdentity = try PQRCIdentity(seed: hexData(String(repeating: "b2", count: 32)))
        let aliceNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 701))
        let bobNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 702))

        let alice = NearbyACPTransport(
            identity: aliceIdentity, nostrKeypair: aliceNostr,
            link: await hub.makeLink(name: "alice"),
            peerIdentityKey: bobIdentity.publicKeyData,
            randomSource: SeededRandomSource(seed: 751),
            nonceSource: SeededRandomSource(seed: 761))
        let bob = NearbyACPTransport(
            identity: bobIdentity, nostrKeypair: bobNostr,
            link: await hub.makeLink(name: "bob"),
            peerIdentityKey: aliceIdentity.publicKeyData,
            randomSource: SeededRandomSource(seed: 752),
            nonceSource: SeededRandomSource(seed: 762))

        let aliceEndpoint = Endpoint(
            transport: alice, peerID: NearbyPeerID("alice"), lines: ACPLineCollector())
        let bobEndpoint = Endpoint(
            transport: bob, peerID: NearbyPeerID("bob"), lines: ACPLineCollector())
        await aliceEndpoint.lines.attach(alice.inboundLines())
        await bobEndpoint.lines.attach(bob.inboundLines())

        try await alice.start()
        try await bob.start()
        #expect(await waitPaired(alice))
        #expect(await waitPaired(bob))
        return (aliceEndpoint, bobEndpoint)
    }

    /// Polls until `transport` has a proven peer (the hello is async).
    static func waitPaired(
        _ transport: NearbyACPTransport, timeoutMillis: Int = 5_000
    ) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if await transport.isPeerProven() { return true }
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return false
    }

    // MARK: - Round trip

    @Test func sealedPair_roundTripsACPLineByteIntact() async throws {
        let hub = LocalLinkSimulator()
        let (alice, bob) = try await Self.makePair(hub: hub)

        // A realistic ACP JSON-RPC line (the shape `runACPAgent` ships) survives
        // seal → link → unseal byte-for-byte.
        let line = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"text":"hi"}}"#
        alice.transport.send(line)
        let got = await bob.lines.waitFor(1)
        #expect(got.first == line)

        // And the reverse direction, proving both sealing keys agree.
        let reply = #"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}"#
        bob.transport.send(reply)
        let back = await alice.lines.waitFor(1)
        #expect(back.first == reply)
    }

    @Test func ordering_isPreservedAcrossManyLines() async throws {
        let hub = LocalLinkSimulator()
        let (alice, bob) = try await Self.makePair(hub: hub)
        let lines = (0..<20).map { #"{"id":\#($0),"method":"session/update"}"# }
        for line in lines { alice.transport.send(line) }
        let got = await bob.lines.waitFor(lines.count)
        #expect(got == lines)
    }

    /// Lines `send` before the hello completes are queued and flushed in order
    /// once the peer proves itself — a caller need not block on pairing.
    @Test func linesQueuedBeforePairing_flushInOrderAfter() async throws {
        let hub = LocalLinkSimulator()
        let aliceIdentity = try PQRCIdentity(seed: hexData(String(repeating: "a1", count: 32)))
        let bobIdentity = try PQRCIdentity(seed: hexData(String(repeating: "b2", count: 32)))
        let aliceNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 701))
        let bobNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 702))

        let alice = NearbyACPTransport(
            identity: aliceIdentity, nostrKeypair: aliceNostr,
            link: await hub.makeLink(name: "alice"), peerIdentityKey: bobIdentity.publicKeyData,
            randomSource: SeededRandomSource(seed: 751), nonceSource: SeededRandomSource(seed: 761))
        try await alice.start()
        // Send BEFORE Bob exists — these must be held, not dropped or sent clear.
        alice.send(#"{"id":1}"#)
        alice.send(#"{"id":2}"#)

        let bob = NearbyACPTransport(
            identity: bobIdentity, nostrKeypair: bobNostr,
            link: await hub.makeLink(name: "bob"), peerIdentityKey: aliceIdentity.publicKeyData,
            randomSource: SeededRandomSource(seed: 752), nonceSource: SeededRandomSource(seed: 762))
        let bobLines = ACPLineCollector()
        await bobLines.attach(bob.inboundLines())
        try await bob.start()
        #expect(await Self.waitPaired(alice))

        let got = await bobLines.waitFor(2)
        #expect(got == [#"{"id":1}"#, #"{"id":2}"#])
    }

    // MARK: - P-8 canary: frames are ciphertext, never plaintext

    @Test func p8Canary_rawLinkBytesNeverContainPlaintextOrSecret() async throws {
        let hub = LocalLinkSimulator()
        let (alice, bob) = try await Self.makePair(hub: hub)

        // A line carrying both a known ACP method name and a planted secret.
        let secret = "sk-CANARY123"
        let line = #"{"method":"session/prompt","params":{"apiKey":"\#(secret)"}}"#
        alice.transport.send(line)
        _ = await bob.lines.waitFor(1)

        // Every byte Alice handed the underlying link, across ALL frames (hello,
        // proof, the sealed frame): the plaintext method and the secret must NOT
        // appear anywhere. The frame is ciphertext.
        let rawPayloads = await hub.payloads(from: alice.peerID, to: bob.peerID)
        #expect(!rawPayloads.isEmpty)
        let secretBytes = Data(secret.utf8)
        let methodBytes = Data("session/prompt".utf8)
        for raw in rawPayloads {
            #expect(!raw.contains(subsequence: secretBytes), "planted secret leaked in clear on the link")
            #expect(!raw.contains(subsequence: methodBytes), "ACP method name leaked in clear on the link")
        }
        // Sanity: the canary would have FIRED on the plaintext line itself —
        // proves the check isn't vacuous.
        let plain = Data(line.utf8)
        #expect(plain.contains(subsequence: secretBytes))
        #expect(plain.contains(subsequence: methodBytes))
    }

    // MARK: - Don't trust the socket: unauthenticated / forged / tampered

    /// An unpaired peer (never proved an identity) whose frames Bob simply must
    /// not accept. Mallory seals a perfectly-valid ACP frame to Bob's real Nostr
    /// key, but never completes the hello → Bob drops it.
    @Test func unauthenticatedPeer_framesRejected() async throws {
        let hub = LocalLinkSimulator()
        let bobIdentity = try PQRCIdentity(seed: hexData(String(repeating: "b2", count: 32)))
        let aliceIdentity = try PQRCIdentity(seed: hexData(String(repeating: "a1", count: 32)))
        let bobNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 702))

        let bob = NearbyACPTransport(
            identity: bobIdentity, nostrKeypair: bobNostr,
            link: await hub.makeLink(name: "bob"), peerIdentityKey: aliceIdentity.publicKeyData,
            randomSource: SeededRandomSource(seed: 752), nonceSource: SeededRandomSource(seed: 762))
        let bobLines = ACPLineCollector()
        await bobLines.attach(bob.inboundLines())
        try await bob.start()

        // Mallory drives a raw link by hand. She does NOT answer Bob's hello;
        // she just sends a frame she sealed to Bob's Nostr key.
        let malloryNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 999))
        let sealed = try SealCipher.encrypt(
            Data(#"{"method":"session/prompt"}"#.utf8),
            privateKey: malloryNostr.privateKeyData, peerPublicKeyHex: bobNostr.publicKeyHex,
            nonceSource: SeededRandomSource(seed: 1001))
        let frame = ACPLinkPayload(kind: .frame, frame: sealed)
        await hub.inject(
            try WireJSON.encoder().encode(frame),
            from: NearbyPeerID("mallory"), to: NearbyPeerID("bob"))

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await bobLines.all().isEmpty, "frame from an unproven peer must be dropped")
        #expect(await bob.droppedFrameCount > 0)
        #expect(!(await bob.isPeerProven()))
    }

    /// A forged hello proof — Mallory claims Alice's identity but can only sign
    /// with her own key — must NOT pair, so no ACP frame is ever accepted.
    @Test func forgedHelloProof_cannotImpersonatePairedPeer() async throws {
        let hub = LocalLinkSimulator()
        let bobIdentity = try PQRCIdentity(seed: hexData(String(repeating: "b2", count: 32)))
        let aliceIdentity = try PQRCIdentity(seed: hexData(String(repeating: "a1", count: 32)))
        let bobNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 702))

        let bob = NearbyACPTransport(
            identity: bobIdentity, nostrKeypair: bobNostr,
            link: await hub.makeLink(name: "bob"), peerIdentityKey: aliceIdentity.publicKeyData,
            randomSource: SeededRandomSource(seed: 752), nonceSource: SeededRandomSource(seed: 762))
        let bobLines = ACPLineCollector()
        await bobLines.attach(bob.inboundLines())
        try await bob.start()

        // Mallory: answer Bob's hello claiming ALICE's identity + a sealing key
        // she controls, signed with her OWN (non-Alice) identity key.
        let malloryIdentity = try PQRCIdentity(seed: hexData(String(repeating: "33", count: 32)))
        let malloryNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 999))
        let malloryLink = await hub.makeLink(name: "mallory")
        let malloryEvents = await malloryLink.events()
        let pump = Task {
            for await event in malloryEvents {
                guard case .data(let data, let from) = event,
                    let payload = try? WireJSON.decoder().decode(ACPLinkPayload.self, from: data),
                    payload.kind == .hello, let challenge = payload.challenge
                else { continue }
                let forged = ACPLinkPayload(
                    kind: .helloProof,
                    identity: aliceIdentity.publicKeyData,  // the lie
                    nostrPubkey: Data(hexString: malloryNostr.publicKeyHex),
                    sig: try? malloryIdentity.sign(
                        ACPLinkPayload.helloProofMessage(
                            identity: aliceIdentity.publicKeyData,
                            nostrPubkey: Data(hexString: malloryNostr.publicKeyHex) ?? Data(),
                            challenge: challenge)))
                if let encoded = try? WireJSON.encoder().encode(forged) {
                    try? await malloryLink.send(encoded, to: from)
                }
            }
        }
        defer { pump.cancel() }
        try await malloryLink.start()

        try? await Task.sleep(for: .milliseconds(250))
        #expect(!(await bob.isPeerProven()), "a forged proof must never pair the peer")
        #expect(await bob.droppedFrameCount > 0)

        // Even if Mallory now seals a frame, Bob has no proven peer → rejected.
        let sealed = try SealCipher.encrypt(
            Data(#"{"method":"session/prompt"}"#.utf8),
            privateKey: malloryNostr.privateKeyData, peerPublicKeyHex: bobNostr.publicKeyHex,
            nonceSource: SeededRandomSource(seed: 1234))
        await hub.inject(
            try WireJSON.encoder().encode(ACPLinkPayload(kind: .frame, frame: sealed)),
            from: NearbyPeerID("mallory"), to: NearbyPeerID("bob"))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await bobLines.all().isEmpty)
    }

    /// A tampered frame (ciphertext bits flipped) fails the AEAD tag and is
    /// dropped; the channel survives — the next real line still arrives.
    @Test func tamperedFrame_isDropped_channelSurvives() async throws {
        let hub = LocalLinkSimulator()
        let (alice, bob) = try await Self.makePair(hub: hub)

        // Capture a real sealed frame Alice sent, corrupt its ciphertext, replay.
        alice.transport.send(#"{"method":"session/prompt","params":{"text":"first"}}"#)
        _ = await bob.lines.waitFor(1)

        let framePayload = try #require(
            await hub.payloads(from: alice.peerID, to: bob.peerID).first {
                (try? WireJSON.decoder().decode(ACPLinkPayload.self, from: $0))?.kind == .frame
            })
        var payload = try WireJSON.decoder().decode(ACPLinkPayload.self, from: framePayload)
        // Flip the base64 sealed frame's body (keep version byte intact so it
        // reaches ChaChaPoly and fails the TAG, not the length guard).
        let original = try #require(payload.frame)
        payload.frame = String(original.reversed())
        await hub.inject(
            try WireJSON.encoder().encode(payload), from: alice.peerID, to: bob.peerID)
        try? await Task.sleep(for: .milliseconds(150))

        // The tampered frame produced no inbound line (only the genuine first one).
        #expect(await bob.lines.all().count == 1, "tampered frame must be dropped")
        #expect(await bob.transport.droppedFrameCount > 0)

        // Channel intact: the next genuine line still decrypts.
        alice.transport.send(#"{"method":"session/cancel"}"#)
        let after = await bob.lines.waitFor(2)
        #expect(after.last == #"{"method":"session/cancel"}"#)
    }

    /// Frames addressed to / sealed for a DIFFERENT peer than the one we paired
    /// with are rejected — a proven peer can't smuggle in frames sealed to a key
    /// we never authenticated (the seal key is bound to the proven identity).
    @Test func frameFromProvenPeerButWrongSealKey_isDropped() async throws {
        let hub = LocalLinkSimulator()
        let (alice, bob) = try await Self.makePair(hub: hub)
        _ = alice

        // A frame sealed by some OTHER key (not Alice's proven sealing key),
        // injected as if from Alice's proven handle. Bob unseals with Alice's
        // proven key → ChaChaPoly fails → dropped.
        let strangerNostr = try NostrKeypair(randomSource: SeededRandomSource(seed: 555))
        let bobNostrPub = try NostrKeypair(randomSource: SeededRandomSource(seed: 702)).publicKeyHex
        let sealed = try SealCipher.encrypt(
            Data(#"{"method":"session/prompt"}"#.utf8),
            privateKey: strangerNostr.privateKeyData, peerPublicKeyHex: bobNostrPub,
            nonceSource: SeededRandomSource(seed: 1357))
        let before = await bob.lines.all().count
        await hub.inject(
            try WireJSON.encoder().encode(ACPLinkPayload(kind: .frame, frame: sealed)),
            from: alice.peerID, to: bob.peerID)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await bob.lines.all().count == before, "frame under the wrong sealing key must drop")
        #expect(await bob.transport.droppedFrameCount > 0)
    }
}

// MARK: - Test helpers

/// Drains a transport's inbound ACP-line stream into an awaitable buffer.
actor ACPLineCollector {
    private var lines: [String] = []
    private var task: Task<Void, Never>?

    func attach(_ stream: AsyncStream<String>) {
        task = Task {
            for await line in stream { self.append(line) }
        }
    }

    private func append(_ line: String) { lines.append(line) }

    func all() -> [String] { lines }

    /// Polls until `count` lines arrived or the timeout elapses.
    func waitFor(_ count: Int, timeoutMillis: Int = 5_000) async -> [String] {
        var waited = 0
        while lines.count < count && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return lines
    }
}

extension Data {
    /// Byte-subsequence containment — the P-8 canary's "does the plaintext
    /// appear in these raw bytes" check.
    func contains(subsequence needle: Data) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        let selfBytes = [UInt8](self)
        let needleBytes = [UInt8](needle)
        let last = selfBytes.count - needleBytes.count
        var i = 0
        while i <= last {
            if Array(selfBytes[i..<(i + needleBytes.count)]) == needleBytes { return true }
            i += 1
        }
        return false
    }
}
