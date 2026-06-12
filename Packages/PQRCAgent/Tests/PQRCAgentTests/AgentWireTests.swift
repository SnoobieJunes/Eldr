import Crypto
import Foundation
import Testing

@testable import PQRCAgent
@testable import PQRCCore
@testable import PQRCNostr

/// Wire-level agent authenticity (SPEC §8.2, §13.4): the participant gate over
/// real encrypted traffic between two messengers.
@Suite("Agent message authenticity on the wire", .tags(.agent))
struct AgentWireTests {
    struct Pair {
        let relay: LocalRelaySimulator
        let clock: FixedClock
        let alice: PQRCIdentity
        let bob: PQRCIdentity
        let aliceMessenger: PQRCMessenger
        let bobMessenger: PQRCMessenger
        let bobInbox: Inbox
    }

    actor Inbox {
        private(set) var messages: [ReceivedMessage] = []
        private(set) var violations: [String] = []
        private var task: Task<Void, Never>?

        func attach(_ stream: AsyncStream<MessengerEvent>) {
            task = Task {
                for await event in stream {
                    self.record(event)
                }
            }
        }

        private func record(_ event: MessengerEvent) {
            switch event {
            case .message(let message): messages.append(message)
            case .protocolViolation(_, let reason, _): violations.append(reason)
            default: break
            }
        }

        func wait(messages count: Int = 0, violations violationCount: Int = 0) async {
            var waited = 0
            while (messages.count < count || violations.count < violationCount) && waited < 5000 {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 10
            }
        }
    }

    static func makePair() async throws -> Pair {
        let relay = LocalRelaySimulator()
        let clock = FixedClock(now: 1_757_000_000)

        func makeMessenger(seedByte: String, seed: UInt64) async throws -> (
            PQRCIdentity, PQRCMessenger
        ) {
            let identity = try PQRCIdentity(seed: hexData(String(repeating: seedByte, count: 32)))
            let random = SeededRandomSource(seed: seed)
            let messenger = try PQRCMessenger(
                identity: identity,
                nostrKeypair: try NostrKeypair(randomSource: random),
                prekeyManager: try PrekeyManager(
                    identity: identity, randomSource: random, oneTimeCount: 4),
                identityDH: try Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: random.bytes(32)),
                transports: [await relay.connect()],
                clock: clock, randomSource: random,
                nonceSource: SeededRandomSource(seed: seed &+ 7),
                outboundRetryBaseMillis: 2)
            return (identity, messenger)
        }

        let (alice, aliceMessenger) = try await makeMessenger(seedByte: "1a", seed: 7001)
        let (bob, bobMessenger) = try await makeMessenger(seedByte: "2b", seed: 7002)

        func contact(_ identity: PQRCIdentity, _ messenger: PQRCMessenger) async throws -> VerifiedContact {
            let binding = try IdentityBinding.make(
                identity: identity,
                nostrPubkey: hexData(await messenger.nostrKeypair.publicKeyHex))
            return VerifiedContact(
                binding: try BindingVerifier.verify(binding, outerSignatureValid: true))
        }
        await aliceMessenger.addContact(try await contact(bob, bobMessenger))
        await bobMessenger.addContact(try await contact(alice, aliceMessenger))

        let bobInbox = Inbox()
        await bobInbox.attach(try await bobMessenger.start())

        try await aliceMessenger.establishSession(
            with: try await contact(bob, bobMessenger),
            bundle: try await bobMessenger.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "hello", sentAt: clock.now()))
        await bobInbox.wait(messages: 1)

        return Pair(
            relay: relay, clock: clock, alice: alice, bob: bob,
            aliceMessenger: aliceMessenger, bobMessenger: bobMessenger, bobInbox: bobInbox)
    }

    @Test func sendAsMyAI_isAgentSignedAndLabeled_andDraftEditIsHuman() async throws {
        let pair = try await Self.makePair()

        // "Send as my AI": agent-signed, agent-labeled, renders as AI-authored.
        try await pair.aliceMessenger.send(
            MessageBody(text: "I'm Alice's AI — Tuesday works.", sentAt: 0),
            to: pair.bob.publicKeyData.hexString, participantType: .agent)
        // "Edit & send as me": the human's own message, human-signed.
        try await pair.aliceMessenger.send(
            MessageBody(text: "(edited draft) Tuesday works!", sentAt: 0),
            to: pair.bob.publicKeyData.hexString, participantType: .human)

        await pair.bobInbox.wait(messages: 3)
        let messages = await pair.bobInbox.messages
        #expect(messages.count == 3)
        let agentMessage = try #require(messages.first { $0.participantType == .agent })
        #expect(agentMessage.body.text == "I'm Alice's AI — Tuesday works.")
        let humanMessage = try #require(
            messages.first { $0.body.text == "(edited draft) Tuesday works!" })
        #expect(humanMessage.participantType == .human)
        #expect(await pair.bobInbox.violations.isEmpty)
    }

    @Test func participantType_agentSignature_requiresAgentLabel() async throws {
        // The §13.4 forgery: an agent-signed payload labeled "human" must be
        // rejected as a protocol violation, never rendered as a human message.
        let alice = try PQRCIdentity(seed: hexData(String(repeating: "3c", count: 32)))
        let aliceAgent = try AgentKeyDeriver.deriveAgentKey(from: alice)
        let ciphertext = Data(repeating: 9, count: 280)
        let agentSig = try aliceAgent.signature(
            for: RumorContent.agentSignatureMessage(ciphertext: ciphertext))

        var forged = RumorContent(
            type: .message, participantType: .human, senderRole: .identity,
            header: RatchetHeader(dh: Data(repeating: 1, count: 32), pn: 0, n: 0, pq: nil),
            ciphertext: ciphertext)
        forged.agentSig = agentSig
        #expect(
            !PQRCMessenger.validateParticipantAuthenticity(
                forged, agentPubkey: aliceAgent.publicKey.rawRepresentation),
            "human label under an agent signature is a protocol violation")

        // Agent label without a signature: rejected.
        var unsigned = forged
        unsigned.participantType = .agent
        unsigned.senderRole = .agent
        unsigned.agentSig = nil
        #expect(
            !PQRCMessenger.validateParticipantAuthenticity(
                unsigned, agentPubkey: aliceAgent.publicKey.rawRepresentation))

        // Agent label with a signature from a DIFFERENT agent key: rejected.
        let mallory = try PQRCIdentity(seed: hexData(String(repeating: "4d", count: 32)))
        let malloryAgent = try AgentKeyDeriver.deriveAgentKey(from: mallory)
        var wrongKey = unsigned
        wrongKey.agentSig = try malloryAgent.signature(
            for: RumorContent.agentSignatureMessage(ciphertext: ciphertext))
        #expect(
            !PQRCMessenger.validateParticipantAuthenticity(
                wrongKey, agentPubkey: aliceAgent.publicKey.rawRepresentation))

        // The honest case verifies.
        var honest = unsigned
        honest.agentSig = agentSig
        #expect(
            PQRCMessenger.validateParticipantAuthenticity(
                honest, agentPubkey: aliceAgent.publicKey.rawRepresentation))
    }

    @Test func forgedLabel_overTheWire_emitsProtocolViolation() async throws {
        // Full pipeline: a hostile client sends an agent-signed payload with a
        // human label; Bob's messenger emits .protocolViolation (the UI renders
        // the red system row), never .message.
        let pair = try await Self.makePair()
        let aliceAgent = try AgentKeyDeriver.deriveAgentKey(from: pair.alice)

        // Reach into Alice's live session to craft the forged rumor with real
        // ratchet state (what a malicious fork of the client would do).
        let snapshot = try #require(
            await pair.aliceMessenger.sessionSnapshot(
                peerIdentityHex: pair.bob.publicKeyData.hexString))
        var ratchet = try DoubleRatchet(
            snapshot: snapshot, randomSource: SeededRandomSource(seed: 31))
        let fuzzed = pair.clock.now() - 100
        let body = MessageBody(text: "pretending to be human", sentAt: pair.clock.now())
        let padded = try Padding.pad(try WireJSON.encoder().encode(body))
        let (header, ciphertext) = try ratchet.encrypt(paddedPlaintext: padded) { header in
            AssociatedData.build(
                participantType: .human, n: header.n, fuzzedTimestamp: fuzzed)
        }
        var forged = RumorContent(
            type: .message, participantType: .human, senderRole: .identity,
            header: header, ciphertext: ciphertext)
        forged.agentSig = try aliceAgent.signature(
            for: RumorContent.agentSignatureMessage(ciphertext: ciphertext))

        let wrap = try GiftWrap.wrap(
            rumor: forged, sender: await pair.aliceMessenger.nostrKeypair,
            recipientNostrPubkey: await pair.bobMessenger.nostrKeypair.publicKeyHex,
            fuzzedTimestamp: fuzzed,
            randomSource: SeededRandomSource(seed: 32),
            nonceSource: SeededRandomSource(seed: 33))
        _ = try await (await pair.relay.connect()).publish(wrap)

        await pair.bobInbox.wait(messages: 1, violations: 1)
        let violations = await pair.bobInbox.violations
        #expect(violations.count == 1)
        #expect(violations.first?.contains("participant_type") == true)
        let messages = await pair.bobInbox.messages
        #expect(!messages.contains { $0.body.text == "pretending to be human" })
    }
}
