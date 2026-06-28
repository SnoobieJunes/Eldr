import Crypto
import Foundation
import Testing

@testable import PQRCCore

/// `EncryptedStore.deriveKey` underpins the eldr-acp metadata-file encryption (Phase 3):
/// a separate process must derive the SAME key from the SAME master key, while different
/// labels stay isolated and different masters never collide.
@Suite("EncryptedStore.deriveKey")
struct EncryptedStoreDeriveKeyTests {

    private func store(_ seed: UInt8) -> EncryptedStore {
        EncryptedStore(masterKey: Data(repeating: seed, count: 32), nonceSource: SystemNonceSource())
    }

    @Test func deterministicForSameMasterAndLabel() {
        let a = store(0x42)
        let b = store(0x42)  // same master key, reopened (the cross-process case)
        #expect(a.deriveKey(label: "acp-metadata-v1") == b.deriveKey(label: "acp-metadata-v1"))
        #expect(a.deriveKey(label: "acp-metadata-v1").count == 32)
    }

    @Test func differentLabelsAreIndependent() {
        let s = store(0x42)
        #expect(s.deriveKey(label: "acp-metadata-v1") != s.deriveKey(label: "other-channel"))
    }

    @Test func differentMastersNeverCollide() {
        #expect(store(0x01).deriveKey(label: "acp-metadata-v1")
            != store(0x02).deriveKey(label: "acp-metadata-v1"))
    }

    @Test func honorsByteCount() {
        #expect(store(0x42).deriveKey(label: "x", byteCount: 16).count == 16)
    }
}
