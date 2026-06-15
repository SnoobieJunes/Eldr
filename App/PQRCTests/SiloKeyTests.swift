import CryptoKit
import Foundation
import Testing

@testable import EldrChat

/// The deniable multi-account cryptographic foundation: a passphrase
/// deterministically yields an opaque silo namespace + key, different
/// passphrases never collide, and a silo's secrets open only with its own key.
@Suite("Silo key derivation")
struct SiloKeyTests {
    @Test func deterministic_samePassphraseSameSilo() {
        let a = SiloKey.derive(passphrase: "correct horse battery staple")
        let b = SiloKey.derive(passphrase: "correct horse battery staple")
        #expect(a.siloID == b.siloID)
        #expect(a.kek == b.kek)
        #expect(a.siloID.count == 32, "16 bytes hex")
    }

    @Test func differentPassphrase_differentSiloAndKey() {
        let a = SiloKey.derive(passphrase: "alpha-passphrase")
        let b = SiloKey.derive(passphrase: "beta-passphrase")
        #expect(a.siloID != b.siloID, "a wrong passphrase points at a different, non-existent silo")
        #expect(a.kek != b.kek)
    }

    @Test func sealOpen_roundTrips_onlyWithTheRightKey() throws {
        let a = SiloKey.derive(passphrase: "alpha-passphrase")
        let b = SiloKey.derive(passphrase: "beta-passphrase")
        let secret = Data("identity-seed-and-master-key".utf8)
        let blob = try SiloKey.seal(secret, kek: a.kek)
        #expect(try SiloKey.open(blob, kek: a.kek) == secret)
        #expect(throws: (any Error).self) {
            _ = try SiloKey.open(blob, kek: b.kek)
        }
    }
}
