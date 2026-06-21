import CryptoKit
import Foundation
import Testing

@testable import EldrChat

/// The deniable multi-account namespace selector: a passphrase deterministically
/// yields an opaque silo namespace, different passphrases never collide, and the
/// optional passphrase factor (the KEK nested UNDER the Secure-Enclave wrap, AC31)
/// opens a sealed blob only with the right passphrase.
@Suite("Silo namespace + passphrase factor")
struct SiloKeyTests {
    @Test func deterministic_samePassphraseSameSilo() {
        let a = SiloKey.siloID(for: "correct horse battery staple")
        let b = SiloKey.siloID(for: "correct horse battery staple")
        #expect(a == b)
        #expect(a.count == 32, "16 bytes hex")
    }

    @Test func differentPassphrase_differentSilo() {
        let a = SiloKey.siloID(for: "alpha-passphrase")
        let b = SiloKey.siloID(for: "beta-passphrase")
        #expect(a != b, "a wrong passphrase points at a different, non-existent silo")
    }

    @Test func passphraseKEK_sealOpen_roundTrips_onlyWithTheRightPassphrase() throws {
        let a = SiloKey.passphraseKEK("alpha-passphrase")
        let b = SiloKey.passphraseKEK("beta-passphrase")
        #expect(a != b, "different passphrases derive different factors")
        let secret = Data("identity-seed-and-master-key".utf8)
        let blob = try SiloKey.seal(secret, kek: a)
        #expect(try SiloKey.open(blob, kek: a) == secret)
        #expect(throws: (any Error).self) {
            _ = try SiloKey.open(blob, kek: b)
        }
    }
}
