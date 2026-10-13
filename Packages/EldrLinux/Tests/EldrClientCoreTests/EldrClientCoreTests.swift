// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrClientCore
import EldrKeystore
@testable import PQRCCore
@testable import PQRCNostr

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-chat-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func makeStore(_ dir: URL, key: SymmetricKey) -> FileIdentityStore {
    FileIdentityStore(directory: dir, masterKey: key, profile: .eldrChat)
}

/// Collects client events for assertions.
private actor Collector {
    var events: [ClientEvent] = []
    func attach(_ s: AsyncStream<ClientEvent>) { Task { for await e in s { self.add(e) } } }
    func add(_ e: ClientEvent) { events.append(e) }
    var texts: [String] {
        events.compactMap { if case .message(_, let m) = $0 { return m.body.text } else { return nil } }
    }
    var requests: [(String, Bool)] {
        events.compactMap { if case .request(let n, let a) = $0 { return (n, a) } else { return nil } }
    }
    func waitTexts(_ n: Int, timeout: Double = 10) async -> [String] {
        let end = Date().addingTimeInterval(timeout)
        while texts.count < n && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return texts
    }
    func waitRequests(_ n: Int, timeout: Double = 10) async -> [(String, Bool)] {
        let end = Date().addingTimeInterval(timeout)
        while requests.count < n && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return requests
    }
}

private struct Peer {
    let dir: URL
    let key: SymmetricKey
    var store: FileIdentityStore { makeStore(dir, key: key) }
    static func make(_ relay: LocalRelaySimulator) async throws -> (Peer, EldrClient) {
        let p = Peer(dir: tempDir(), key: SymmetricKey(size: .bits256))
        try EldrClient.initialize(store: p.store, relays: ["local://relay"])
        let c = try await p.open(relay)
        try await c.announce(maxAttempts: 2)
        return (p, c)
    }
    func open(_ relay: LocalRelaySimulator) async throws -> EldrClient {
        try await EldrClient(store: store, transport: { await relay.connect() })
    }
}

@Suite("Encrypted state store")
struct StoreTests {
    @Test func roundTrip_andWrongKeyFails_andNoPlaintextOnDisk() throws {
        let dir = tempDir()
        let key = SymmetricKey(size: .bits256)
        let canary = "CANARY-\(UUID().uuidString)"
        try makeStore(dir, key: key).save(Data(canary.utf8), account: "state")
        #expect(makeStore(dir, key: key).load(account: "state") == Data(canary.utf8))
        #expect(makeStore(dir, key: SymmetricKey(size: .bits256)).load(account: "state") == nil)
        let raw = try Data(contentsOf: dir.appendingPathComponent("state.enc"))
        #expect(raw.range(of: Data(canary.utf8)) == nil)
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("state.enc").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func passphraseLadder_wrapsMasterKey_andRejectsWrongPassphrase() throws {
        let dir = tempDir()
        let env = ["ELDR_CHAT_PASSPHRASE": "correct horse"]
        let (s1, posture) = try makeClientKeystore(directory: dir, environment: env, tpmPresent: { false })
        #expect(posture == .passphraseOnDisk)
        try s1.save(Data("x".utf8), account: "a")
        let (s2, _) = try makeClientKeystore(directory: dir, environment: env, tpmPresent: { false })
        #expect(s2.load(account: "a") == Data("x".utf8))
        #expect(throws: (any Error).self) {
            _ = try makeClientKeystore(directory: dir, environment: ["ELDR_CHAT_PASSPHRASE": "wrong"], tpmPresent: { false })
        }
        #expect(throws: (any Error).self) {
            _ = try makeClientKeystore(directory: tempDir(), environment: env, tpmPresent: { true })
        }
    }
}

@Suite("Pairing links")
struct PairingLinkTests {
    let hex = "98e37e8bec8402aa7f0e1bf0fe720a2112ede3b68aca038190493d5c6b60fd0f"
    @Test func roundTrip_andForms() throws {
        let l = PairingLink(nostrPubkeyHex: hex, relay: "wss://relay.lerants.com")
        #expect(l.uri.hasPrefix("pqrc:add?npub=npub1"))
        #expect(PairingLink.parse(l.uri) == l)
        #expect(PairingLink.parse(l.npub)?.nostrPubkeyHex == hex)
        #expect(PairingLink.parse(hex.uppercased())?.nostrPubkeyHex == hex)
        #expect(PairingLink.parse("pqrc:add?npub=\(l.npub)&type=coding_agent")?.type == "coding_agent")
    }
    @Test func rejectsGarbage() {
        #expect(PairingLink.parse("npub1notvalid") == nil)
        #expect(PairingLink.parse("https://example.com/?npub=x") == nil)
        #expect(PairingLink.parse("abc") == nil)
    }
}

@Suite("Client end-to-end over LocalRelaySimulator")
struct ClientE2ETests {
    @Test func addSend_requestAccept_reply_restart_continue() async throws {
        let relay = LocalRelaySimulator()
        let (_, alice) = try await Peer.make(relay)
        let (bobP, bob) = try await Peer.make(relay)

        let bobEv = Collector()
        await bobEv.attach(try await bob.start())
        try await alice.addContact(bob.pairingLink.uri, name: "bob")
        try await alice.send("hello 1", to: "bob")

        // Non-contact ⇒ a request, NOT a message.
        let reqs = await bobEv.waitRequests(1)
        #expect(reqs.first?.0 == alice.nostrPubkeyHex)
        #expect(await bobEv.texts.isEmpty)
        #expect(await bob.requests.count == 1)

        try await bob.accept(String(alice.nostrPubkeyHex.prefix(10)), name: "alice")
        #expect(await bobEv.waitTexts(1) == ["hello 1"])
        #expect(await bob.requests.isEmpty)

        let aliceEv = Collector()
        await aliceEv.attach(try await alice.start())
        try await bob.send("hi 2", to: "alice")
        #expect(await aliceEv.waitTexts(1) == ["hi 2"])

        // Restart Bob from disk: contacts re-verified offline, session restored.
        await bob.stop()
        let bob2 = try await bobP.open(relay)
        #expect(await bob2.contacts.map(\.name) == ["alice"])
        #expect(await bob2.contacts.first?.session != nil)
        let bob2Ev = Collector()
        await bob2Ev.attach(try await bob2.start())
        try await alice.send("after restart 3", to: "bob")
        let t = await bob2Ev.waitTexts(1)
        #expect(t == ["after restart 3"], "already-delivered messages must not replay")
        try await bob2.send("still here 4", to: "alice")
        #expect(await aliceEv.waitTexts(2) == ["hi 2", "still here 4"])
    }

    @Test func autoAccept_onlyTheOwner_othersStayRequests() async throws {
        let relay = LocalRelaySimulator()
        let (_, owner) = try await Peer.make(relay)
        let (_, stranger) = try await Peer.make(relay)
        let (_, node) = try await Peer.make(relay)
        await node.setAutoAccept(nostrPubkeyHex: owner.nostrPubkeyHex, identityHex: owner.identityHex)
        let ev = Collector()
        await ev.attach(try await node.start())

        try await stranger.addContact(node.pairingLink.uri, name: "node")
        try await stranger.send("let me in", to: "node")
        try await owner.addContact(node.pairingLink.uri, name: "node")
        try await owner.send("it's me", to: "node")

        #expect(await ev.waitTexts(1) == ["it's me"])
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await ev.texts == ["it's me"], "stranger's message must never surface")
        let contacts = await node.contacts
        #expect(contacts.map(\.identityHex) == [owner.identityHex])
        #expect(await node.requests.map(\.nostrPubkeyHex) == [stranger.nostrPubkeyHex])
    }

    @Test func autoAccept_pinnedIdentityMismatch_isRefused() async throws {
        let relay = LocalRelaySimulator()
        let (_, owner) = try await Peer.make(relay)
        let (_, node) = try await Peer.make(relay)
        await node.setAutoAccept(
            nostrPubkeyHex: owner.nostrPubkeyHex, identityHex: String(repeating: "cd", count: 32))
        let ev = Collector()
        await ev.attach(try await node.start())
        try await owner.addContact(node.pairingLink.uri, name: "node")
        try await owner.send("spoofed?", to: "node")
        let r = await ev.waitRequests(1)
        #expect(r.first?.1 == false)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await ev.texts.isEmpty)
        #expect(await node.contacts.isEmpty)
    }

    @Test func unreadableState_failsClosed_andIsNotOverwritten() async throws {
        let relay = LocalRelaySimulator()
        let (p, c) = try await Peer.make(relay)
        await c.stop()
        let url = p.dir.appendingPathComponent("state.enc")
        try Data("garbage".utf8).write(to: url)
        await #expect(throws: EldrClientError.self) { _ = try await p.open(relay) }
        #expect(try Data(contentsOf: url) == Data("garbage".utf8))
    }

    @Test func secondProcessOnSameState_isLockedOut() async throws {
        let relay = LocalRelaySimulator()
        let (p, c) = try await Peer.make(relay)
        await #expect(throws: EldrClientError.self) { _ = try await p.open(relay) }
        _ = c
    }

    @Test func tamperedStoredContact_isDroppedOnRestore() async throws {
        let relay = LocalRelaySimulator()
        let (_, bob) = try await Peer.make(relay)
        let (aP, alice) = try await Peer.make(relay)
        try await alice.addContact(bob.pairingLink.uri, name: "bob")
        await alice.stop()
        // Corrupt the stored identity hex (as if the file were edited) — must not be trusted.
        var st = try JSONDecoder().decode(ClientState.self, from: try #require(aP.store.load(account: "state")))
        st.contacts[0].identityHex = String(repeating: "ab", count: 32)
        try aP.store.save(JSONEncoder().encode(st), account: "state")
        _ = alice
        let alice2 = try await aP.open(relay)
        #expect(await alice2.contacts.isEmpty)
    }
}

@Suite("Client binding refresh")
struct ClientBindingRefreshTests {
    @Test func identitySwapOnRelay_isFlagged_andOldContactKept() async throws {
        let relay = LocalRelaySimulator()
        let (_, bob) = try await Peer.make(relay)
        let (_, alice) = try await Peer.make(relay)
        try await alice.addContact(bob.pairingLink.uri, name: "bob")
        #expect(await alice.refreshBindings(timeout: .seconds(2)).isEmpty)

        // Someone holding bob's Nostr key republishes a binding for ANOTHER identity.
        let bobKeys = try JSONDecoder().decode(
            ClientKeys.self, from: try #require(bob.store.load(account: "keys")))
        let kp = try NostrKeypair(privateKey: bobKeys.nostrPrivateKey)
        let other = try PQRCIdentity(seed: Data(repeating: 0x42, count: 32))
        let swapped = try PQRCEvents.bindingEvent(
            binding: IdentityBinding.make(identity: other, nostrPubkey: Data(hexString: kp.publicKeyHex)!),
            signer: kp, createdAt: Int64(Date().timeIntervalSince1970) + 60,
            randomSource: SystemRandomSource())
        _ = try await relay.connect().publish(swapped)

        let evs = await alice.refreshBindings(timeout: .seconds(2))
        guard case .bindingIdentityChanged(let c, let newHex)? = evs.first else {
            Issue.record("expected identity-change warning, got \(evs)"); return
        }
        #expect(c.identityHex == bob.identityHex)
        #expect(newHex == other.publicKeyData.hexString)
        #expect(await alice.contacts.first?.identityHex == bob.identityHex)
        #expect(try await alice.contact(matching: "bob").bindingEvent.id != swapped.id)
    }
}

@Suite("Peer lost its state (AC165)")
struct ReHandshakeTests {
    /// Bob reinstalls: same identity keys, no sessions/prekeys. His new handshake must
    /// replace Alice's stale session (it used to be silently dropped, cutting the
    /// contact off in both directions), and both directions work afterwards.
    @Test func peerWithLostState_reHandshakes_andBothDirectionsRecover() async throws {
        let relay = LocalRelaySimulator()
        let (_, alice) = try await Peer.make(relay)
        let (bobP, bob) = try await Peer.make(relay)
        let aEv = Collector(), bEv = Collector()
        await aEv.attach(try await alice.start())
        await bEv.attach(try await bob.start())
        try await alice.addContact(bob.pairingLink.uri, name: "bob")
        try await alice.send("one", to: "bob")
        for _ in 0..<200 where await bob.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await bob.accept(String(alice.nostrPubkeyHex.prefix(10)), name: "alice")
        #expect(await bEv.waitTexts(1) == ["one"])
        try await bob.send("two", to: "alice")
        #expect(await aEv.waitTexts(1) == ["two"])
        await bob.stop()

        // Reinstall: copy ONLY the keys into a fresh directory.
        let fresh = Peer(dir: FileManager.default.temporaryDirectory.appendingPathComponent("eldr-reinstall-\(UUID().uuidString)"), key: bobP.key)
        try FileManager.default.createDirectory(at: fresh.dir, withIntermediateDirectories: true)
        try fresh.store.save(bobP.store.load(account: "keys")!, account: "keys")
        let bob2 = try await fresh.open(relay)
        #expect(bob2.identityHex == bob.identityHex)
        #expect(await bob2.contacts.isEmpty)
        try await bob2.announce(maxAttempts: 2)
        let b2Ev = Collector()
        await b2Ev.attach(try await bob2.start())
        try await bob2.addContact(alice.pairingLink.uri, name: "alice")
        try await bob2.send("I reinstalled", to: "alice")
        try await bob2.send("and again", to: "alice")
        #expect(await aEv.waitTexts(3) == ["two", "I reinstalled", "and again"])
        try await alice.send("welcome back", to: "bob")
        #expect(await b2Ev.waitTexts(1) == ["welcome back"])
    }

    /// AC167: a consumed one-time prekey must leave the PUBLISHED bundle. Otherwise a
    /// contact that reinstalls can draw the spent OTP and is refused as a replay.
    @Test func consumedOTP_isRepublishedAway() async throws {
        let relay = LocalRelaySimulator()
        let (_, alice) = try await Peer.make(relay)
        let (_, bob) = try await Peer.make(relay)
        let aEv = Collector()
        await aEv.attach(try await alice.start())
        _ = try await bob.start()
        try await bob.addContact(alice.pairingLink.uri, name: "alice")
        try await bob.send("hi", to: "alice")  // spends one of alice's OTPs
        for _ in 0..<200 where await alice.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await alice.accept(String(bob.nostrPubkeyHex.prefix(10)), name: "bob")
        #expect(await aEv.waitTexts(1) == ["hi"])
        let held = Set(try await alice.prekeyManager.publicBundle().otp)
        var published: Set<Data> = []
        for _ in 0..<100 {
            published = Set(try await bob.messenger.fetchVerifiedPeer(nostrPubkeyHex: alice.nostrPubkeyHex).bundle.otp)
            if published == held { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(published == held)
        #expect(held.count == EldrClient.otpTarget)
        #expect(await alice.state.publishedBundleStale == false)
    }
}

@Suite("Reconnect approval (AC166)")
struct ReconnectApprovalTests {
    @Test func approveBeforeArrival_isRemembered_andDeclineClearsIt() async throws {
        let relay = LocalRelaySimulator()
        let (_, alice) = try await Peer.make(relay)
        let (_, bob) = try await Peer.make(relay)
        try await alice.addContact(bob.pairingLink.uri, name: "bob")
        #expect(try await alice.approveReconnect("bob") == false)
        #expect(await alice.state.approvedReconnects == [bob.identityHex])
        try await alice.declineReconnect("bob")
        #expect(await alice.state.approvedReconnects == [])
        await #expect(throws: EldrClientError.self) { try await alice.approveReconnect("nobody") }
    }
}

/// Invariant 12 canary on Linux: a full add / request / accept / reply / restart cycle
/// writes the message plaintext neither to stderr (the Linux log sink) nor to any
/// file in either state directory.
@Suite("Linux log + at-rest canary", .serialized)
struct LinuxCanaryTests {
    @Test func plaintextNeverReachesStderrOrDisk() async throws {
        let canary = "CANARY-\(UUID().uuidString)"
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-stderr-\(UUID().uuidString)")
        let fd = open(capture.path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        try #require(fd >= 0)
        let saved = dup(2)
        dup2(fd, 2)
        let relay = LocalRelaySimulator()
        let (aliceP, alice) = try await Peer.make(relay)
        let (bobP, bob) = try await Peer.make(relay)
        let bobEv = Collector(), aliceEv = Collector()
        await bobEv.attach(try await bob.start())
        await aliceEv.attach(try await alice.start())
        try await alice.addContact(bob.pairingLink.uri, name: "bob")
        try await alice.send("\(canary) one", to: "bob")
        for _ in 0..<200 where await bob.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await bob.accept(String(alice.nostrPubkeyHex.prefix(10)), name: "alice")
        _ = await bobEv.waitTexts(1)
        try await bob.send("\(canary) two", to: "alice")
        _ = await aliceEv.waitTexts(1)
        await alice.stop(); await bob.stop()
        dup2(saved, 2); close(saved); close(fd)
        #expect(await bobEv.texts.first?.contains(canary) == true, "the canary must actually have flowed")
        let logged = (try? Data(contentsOf: capture)) ?? Data()
        #expect(!String(decoding: logged, as: UTF8.self).contains(canary), "plaintext reached stderr")
        for dir in [aliceP.dir, bobP.dir] {
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            #expect(!files.isEmpty)
            for f in files {
                if let d = try? Data(contentsOf: f) { #expect(d.range(of: Data(canary.utf8)) == nil, "plaintext at rest in \(f.lastPathComponent)") }
            }
        }
    }
}
