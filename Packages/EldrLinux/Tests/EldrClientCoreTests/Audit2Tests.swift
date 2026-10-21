// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import EldrClientCore

@Suite("Audit 2")
struct Audit2Tests {
    /// L1: 100 "human"-labelled peer-bot messages in a minute yield at most 20 autonomous turns.
    @Test func autoTurnCapIgnoresLabels() {
        var l = AutoTurnLimiter()
        var allowed = 0
        for i in 0..<100 where l.allow(scope: "conv", now: 1_000 + Int64(i / 2)) { allowed += 1 }
        #expect(allowed == 20)
        let other = l.allow(scope: "other", now: 1_050)
        #expect(other)  // per scope
        let later = l.allow(scope: "conv", now: 1_000 + 601)
        #expect(later)  // window slides
    }
}

import Crypto
import EldrKeystore
import Foundation
@testable import PQRCNostr

@Suite("Audit 2: relay flood")
struct Audit2FloodTests {
    /// R1: 2,000 message requests from distinct strangers keep at most 32 request records
    /// (bounded persisted state), and the newest stranger is still listed.
    @Test func requestFloodIsBounded() async throws {
        let relay = LocalRelaySimulator()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-flood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileIdentityStore(directory: dir, masterKey: SymmetricKey(size: .bits256), profile: .eldrChat)
        try EldrClient.initialize(store: store, relays: ["local://relay"])
        let c = try await EldrClient(store: store, transport: { await relay.connect() })
        var last = ""
        for i in 0..<2_000 {
            last = String(format: "%064x", i + 1)
            _ = await c.handle(.messageRequest(senderNostrPubkeyHex: last, wrapEventID: "w\(i)"))
        }
        let reqs = await c.requests
        #expect(reqs.count == 32)
        #expect(reqs.contains { $0.nostrPubkeyHex == last })
    }
}
