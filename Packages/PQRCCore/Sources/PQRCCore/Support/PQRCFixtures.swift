// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// Deterministic fixtures for benchmarks and host-app test targets that cannot
/// use @testable imports across packages. Never used by production code paths.
public enum PQRCFixtures {
    /// A live initiator-side ratchet over a synthetic shared secret, fully
    /// derived from `seed`. Suitable for measuring the send pipeline.
    public static func senderRatchet(seed: UInt64) throws -> DoubleRatchet {
        let material = SeededRandomSource(seed: seed)
        let peerRatchet = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: material.bytes(32))
        let myKEM = try MLKEM768.PrivateKey(seedRepresentation: material.bytes(64), publicKey: nil)
        let peerKEM = try MLKEM768.PrivateKey(seedRepresentation: material.bytes(64), publicKey: nil)
        let initiation = PQXDH.InitiationResult(
            sharedSecret: SymmetricKey(data: material.bytes(32)),
            message: HandshakeMessage(
                suite: PQRCConstants.handshakeSuite, ik: Data(), ikDH: Data(), ek: Data(),
                kemCT: Data(), kemPK: myKEM.publicKey.rawRepresentation,
                spkUsed: Data(), otpUsed: nil, otpPQUsed: nil, lrpUsed: false),
            myKEMPrivate: myKEM,
            peerRatchetPubkey: peerRatchet.publicKey.rawRepresentation,
            peerKEMPubkey: peerKEM.publicKey.rawRepresentation)
        return try DoubleRatchet(initiatorWith: initiation, randomSource: material)
    }
}
