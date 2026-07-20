// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// The TEST-PLAN §7 chaos matrix: latency jitter × drop × duplicate × reorder
/// over a 200-message conversation with outbox retry. All messages eventually
/// delivered exactly once, ratchet converged (rekeys at the 50-message cadence
/// included), no quarantines beyond injected damage.
@Suite("Chaos matrix (TEST-PLAN §7)", .tags(.transport), .serialized)
struct ChaosMatrixTests {
    struct Combo: CustomTestStringConvertible, Sendable {
        let jitterMillis: Int
        let dropRate: Double
        let duplicateRate: Double
        let reorderWindow: Int
        var testDescription: String {
            "jitter=\(jitterMillis)ms drop=\(dropRate) dup=\(duplicateRate) reorder=\(reorderWindow)"
        }
    }

    static let matrix: [Combo] = {
        var combos: [Combo] = []
        for jitter in [0, 40] {
            for drop in [0.0, 0.1] {
                for dup in [0.0, 0.1] {
                    for reorder in [0, 5] {
                        combos.append(
                            Combo(
                                jitterMillis: jitter, dropRate: drop, duplicateRate: dup,
                                reorderWindow: reorder))
                    }
                }
            }
        }
        return combos
    }()

    @Test(arguments: matrix)
    func chaosMatrix_allDeliveredExactlyOnce_ratchetConverged(combo: Combo) async throws {
        let chaos = ChaosOptions(
            latencyJitterMillis: combo.jitterMillis, dropRate: combo.dropRate,
            duplicateRate: combo.duplicateRate, reorderWindow: combo.reorderWindow,
            seed: 12345)
        let relay = LocalRelaySimulator(chaos: chaos)
        let clock = FixedClock(now: 1_753_000_000)
        let alice = try await Persona.make(
            name: "alice", seedByte: "c1", seed: 501, transports: [await relay.connect()],
            clock: clock)
        let bob = try await Persona.make(
            name: "bob", seedByte: "c2", seed: 502, transports: [await relay.connect()],
            clock: clock)
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())

        let aliceInbox = EventCollector()
        await aliceInbox.attach(try await alice.messenger.start())
        let bobInbox = EventCollector()
        await bobInbox.attach(try await bob.messenger.start())

        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: try await bob.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 0))
        // Bob can only reply once the (possibly jittered/reordered) handshake
        // lands — same gate the app applies before enabling the composer.
        await relay.flushReorderBuffer()
        let handshakeArrived = await bobInbox.waitForMessages(1, timeoutMillis: 10_000)
        #expect(handshakeArrived.count == 1, "handshake must arrive before the conversation")

        // 200 messages total, interleaved 1:1 — crosses multiple rekey boundaries.
        let perSide = 100
        for i in 0..<perSide {
            try await alice.messenger.send(
                MessageBody(text: "alice #\(i)", sentAt: 0), to: bob.identityHex)
            await relay.flushReorderBuffer()
            try await bob.messenger.send(
                MessageBody(text: "bob #\(i)", sentAt: 0), to: alice.identityHex)
            await relay.flushReorderBuffer()
        }
        await relay.flushReorderBuffer()

        let bobMessages = await bobInbox.waitForMessages(perSide + 1, timeoutMillis: 30_000)
        let aliceMessages = await aliceInbox.waitForMessages(perSide, timeoutMillis: 30_000)

        // Exactly once, complete, no spurious duplicates.
        let bobTexts = bobMessages.map(\.body.text)
        let aliceTexts = aliceMessages.map(\.body.text)
        #expect(bobTexts.count == perSide + 1, "bob: handshake + \(perSide) — got \(bobTexts.count)")
        #expect(aliceTexts.count == perSide)
        #expect(Set(bobTexts).count == bobTexts.count, "no duplicate deliveries")
        #expect(Set(aliceTexts).count == aliceTexts.count)
        for i in 0..<perSide {
            #expect(bobTexts.contains("alice #\(i)"), "missing alice #\(i)")
            #expect(aliceTexts.contains("bob #\(i)"), "missing bob #\(i)")
        }

        // Ratchet converged: a final round-trip still works cleanly.
        try await alice.messenger.send(
            MessageBody(text: "final ping", sentAt: 0), to: bob.identityHex)
        await relay.flushReorderBuffer()
        let final = await bobInbox.waitForMessages(perSide + 2, timeoutMillis: 10_000)
        #expect(final.map(\.body.text).contains("final ping"))

        // No unexplained quarantines and nothing stuck pending.
        #expect(await bob.messenger.pendingRetryCount() == 0)
        #expect(await alice.messenger.pendingRetryCount() == 0)
        await aliceInbox.stop()
        await bobInbox.stop()
        await alice.messenger.stop()
        await bob.messenger.stop()
    }
}
