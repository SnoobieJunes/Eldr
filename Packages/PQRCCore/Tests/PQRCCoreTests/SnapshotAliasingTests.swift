// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

/// Zeroizing a persisted snapshot must never wipe the LIVE keys it was taken from.
/// (Found on Linux: eldr-node zeroized its prekey snapshot after saving and every
/// subsequent handshake then failed to decrypt.)
@Suite("Snapshot zeroize does not alias live keys")
struct SnapshotAliasingTests {
    @Test func prekeySnapshotZeroize_leavesManagerIntact() async throws {
        let id = try PQRCIdentity(seed: Data(repeating: 7, count: 32))
        let pm = try PrekeyManager(identity: id, randomSource: SystemRandomSource(), oneTimeCount: 2)
        let snap0 = await pm.snapshot()
        // Independent byte copies (a Data could share storage with the live key).
        let b = (Array(snap0.ikDH), Array(snap0.spk), Array(snap0.pqpkSeed), Array(snap0.lrp),
                 snap0.otps.mapValues { Array($0) }, snap0.otpPQSeeds.mapValues { Array($0) })
        var wiped = await pm.snapshot()
        wiped.zeroize()
        let after = await pm.snapshot()
        #expect(Array(after.ikDH) == b.0, "ikDH")
        #expect(Array(after.spk) == b.1, "spk")
        #expect(Array(after.pqpkSeed) == b.2, "pqpkSeed")
        #expect(Array(after.lrp) == b.3, "lrp")
        #expect(after.otps.mapValues { Array($0) } == b.4, "otps")
        #expect(after.otpPQSeeds.mapValues { Array($0) } == b.5, "otpPQSeeds")
    }
}

@Suite("Ratchet snapshot zeroize does not alias live session")
struct RatchetSnapshotAliasingTests {
    @Test func detachedCopy_ownsFreshStorage() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let original = Array(key.rawRepresentation)
        var copy = key.rawRepresentation.detachedCopy
        copy.zeroize()
        #expect(Array(key.rawRepresentation) == original)
    }
}
