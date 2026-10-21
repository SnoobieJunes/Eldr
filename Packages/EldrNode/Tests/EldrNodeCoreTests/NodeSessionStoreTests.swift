// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrNodeCore
import PQRCCore
import PQRCNostr

/// In-memory stand-in for the node's encrypted IdentityStore.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func load(_ k: String) -> Data? { lock.withLock { items[k] } }
    func save(_ d: Data, _ k: String) { lock.withLock { items[k] = d } }
}

private struct Keys {
    let identity: PQRCIdentity
    let kp: NostrKeypair
    let dh: Curve25519.KeyAgreement.PrivateKey
    static func random() throws -> Keys {
        let r = SystemRandomSource()
        return Keys(identity: try PQRCIdentity(randomSource: r), kp: try NostrKeypair(randomSource: r),
                    dh: try .init(rawRepresentation: r.bytes(32)))
    }
    func messenger(_ t: any RelayTransport, _ pm: PrekeyManager) throws -> PQRCMessenger {
        try PQRCMessenger(identity: identity, nostrKeypair: kp, prekeyManager: pm, identityDH: dh,
            transports: [t], clock: SystemClock(), randomSource: SystemRandomSource(),
            nonceSource: SystemNonceSource(), outboundRetryBaseMillis: 2)
    }
}

/// Drains an event stream into a collector so tests can wait with a timeout.
private actor Inbox {
    var texts: [String] = []
    var requests: [String] = []
    func attach(_ s: AsyncStream<MessengerEvent>) {
        Task { for await e in s { self.add(e) } }
    }
    func add(_ e: MessengerEvent) {
        switch e {
        case .message(let m): texts.append(m.body.text)
        case .messageRequest(let s, _): requests.append(s)
        default: break
        }
    }
    func wait(_ n: Int, requests r: Bool = false, timeout: Double = 5) async -> [String] {
        let end = Date().addingTimeInterval(timeout)
        while (r ? requests.count : texts.count) < n && Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return r ? requests : texts
    }
}

@Suite("eldr-node session persistence")
struct NodeSessionStoreTests {
    @Test func ownerSession_survivesNodeRestart_noReplay() async throws {
        let relay = LocalRelaySimulator()
        let box = Box()
        let nodeKeys = try Keys.random(), ownerKeys = try Keys.random()
        let ownerPM = try PrekeyManager(identity: ownerKeys.identity, randomSource: SystemRandomSource())
        let owner = try ownerKeys.messenger(await relay.connect(), ownerPM)
        try await owner.announce(relayURLs: ["local://relay"], maxAttempts: 2)

        func bootNode() async throws -> (PQRCNodeMessenger, NodeSessionStore, PQRCMessenger) {
            let pm = try box.load("prekeys").flatMap { try? JSONDecoder().decode(PrekeyState.self, from: $0) }
                .map { try PrekeyManager(identity: nodeKeys.identity, randomSource: SystemRandomSource(), state: $0) }
                ?? PrekeyManager(identity: nodeKeys.identity, randomSource: SystemRandomSource())
            let m = try nodeKeys.messenger(await relay.connect(), pm)
            let store = NodeSessionStore(
                messenger: m, prekeyManager: pm, ownerIdentityHex: ownerKeys.identity.publicKeyData.hexString,
                load: { box.load("session") }, save: { box.save($0, "session") },
                savePrekeys: { box.save($0, "prekeys") })
            await store.restore()
            await store.persist()
            return (PQRCNodeMessenger(messenger: m, sessionStore: store), store, m)
        }

        // Boot 1: owner opens a session; node accepts the request (owner gate) and replies.
        var (node, _, nodeM) = try await bootNode()
        try await nodeM.announce(relayURLs: ["local://relay"], maxAttempts: 2)
        let nodeIn = Inbox(), ownerIn = Inbox()
        await nodeIn.attach(try await node.start())
        await ownerIn.attach(try await owner.start())
        let (nc, bundle) = try await owner.fetchVerifiedPeer(nostrPubkeyHex: nodeKeys.kp.publicKeyHex)
        try await owner.establishSession(with: nc, bundle: bundle, firstMessage: MessageBody(text: "one", sentAt: Int64(Date().timeIntervalSince1970)))
        guard let sender = await nodeIn.wait(1, requests: true).first else {
            Issue.record("expected request"); return
        }
        #expect(try await node.acceptRequest(senderNostrPubkeyHex: sender) == ownerKeys.identity.publicKeyData.hexString)
        #expect(await nodeIn.wait(1) == ["one"])
        try await node.sendFramed("two", to: ownerKeys.identity.publicKeyData.hexString)
        #expect(await ownerIn.wait(1) == ["two"])

        // Restart the node from saved state only.
        await nodeM.stop()
        (node, _, nodeM) = try await bootNode()
        #expect(await nodeM.hasSession(peerIdentityHex: ownerKeys.identity.publicKeyData.hexString))
        let nodeIn2 = Inbox()
        await nodeIn2.attach(try await node.start())
        try await owner.send(MessageBody(text: "three", sentAt: Int64(Date().timeIntervalSince1970)), to: nodeKeys.identity.publicKeyData.hexString)
        #expect(await nodeIn2.wait(1) == ["three"], "old 'one' must not replay; 'three' must decrypt")
        try await node.sendFramed("four", to: ownerKeys.identity.publicKeyData.hexString)
        #expect(await ownerIn.wait(2) == ["two", "four"])
    }

    @Test func nonOwnerContact_isNeverPersisted() async throws {
        let relay = LocalRelaySimulator()
        let box = Box()
        let nodeKeys = try Keys.random(), stranger = try Keys.random()
        let spm = try PrekeyManager(identity: stranger.identity, randomSource: SystemRandomSource())
        let sm = try stranger.messenger(await relay.connect(), spm)
        try await sm.announce(relayURLs: ["local://relay"], maxAttempts: 2)
        let pm = try PrekeyManager(identity: nodeKeys.identity, randomSource: SystemRandomSource())
        let m = try nodeKeys.messenger(await relay.connect(), pm)
        let store = NodeSessionStore(messenger: m, prekeyManager: pm,
            ownerIdentityHex: String(repeating: "ab", count: 32),
            load: { box.load("session") }, save: { box.save($0, "session") }, savePrekeys: { box.save($0, "prekeys") })
        _ = try await m.fetchVerifiedPeer(nostrPubkeyHex: stranger.kp.publicKeyHex)
        await store.track(nostrPubkeyHex: stranger.kp.publicKeyHex)
        await store.persist()
        let saved = try #require(box.load("session"))
        #expect(String(decoding: saved, as: UTF8.self).contains(stranger.kp.publicKeyHex) == false)
    }

    /// AC167: once the owner's handshake spends a node OTP, the published bundle drops it.
    @Test func consumedOTP_isRepublishedAway() async throws {
        let relay = LocalRelaySimulator()
        let box = Box()
        let nodeKeys = try Keys.random(), ownerKeys = try Keys.random()
        let owner = try ownerKeys.messenger(await relay.connect(),
            try PrekeyManager(identity: ownerKeys.identity, randomSource: SystemRandomSource()))
        try await owner.announce(relayURLs: ["local://relay"], maxAttempts: 2)
        let pm = try PrekeyManager(identity: nodeKeys.identity, randomSource: SystemRandomSource())
        let m = try nodeKeys.messenger(await relay.connect(), pm)
        let store = NodeSessionStore(messenger: m, prekeyManager: pm,
            ownerIdentityHex: ownerKeys.identity.publicKeyData.hexString,
            load: { box.load("session") }, save: { box.save($0, "session") },
            savePrekeys: { box.save($0, "prekeys") },
            republishRelayURLs: ["local://relay"], oneTimePrekeyTarget: 10)
        try await m.announce(relayURLs: ["local://relay"], maxAttempts: 2)
        let node = PQRCNodeMessenger(messenger: m, sessionStore: store)
        let nodeIn = Inbox()
        await nodeIn.attach(try await node.start())
        _ = try await owner.start()
        let (nc, bundle) = try await owner.fetchVerifiedPeer(nostrPubkeyHex: nodeKeys.kp.publicKeyHex)
        try await owner.establishSession(with: nc, bundle: bundle, firstMessage: MessageBody(text: "one", sentAt: Int64(Date().timeIntervalSince1970)))
        let sender = try #require(await nodeIn.wait(1, requests: true).first)
        _ = try await node.acceptRequest(senderNostrPubkeyHex: sender)
        #expect(await nodeIn.wait(1) == ["one"])
        await store.persist()
        let held = Set(try await pm.publicBundle().otp)
        var published: Set<Data> = []
        for _ in 0..<100 {
            published = Set(try await owner.fetchVerifiedPeer(nostrPubkeyHex: nodeKeys.kp.publicKeyHex).bundle.otp)
            if published == held { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(published == held)
        #expect(!published.isSuperset(of: Set(bundle.otp)), "the spent OTP must be gone")
    }
}
