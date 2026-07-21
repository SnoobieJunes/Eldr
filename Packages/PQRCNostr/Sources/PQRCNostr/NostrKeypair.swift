// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import P256K
import PQRCCore

public enum NostrError: Error, Equatable, Sendable {
    case invalidKey
    case invalidSignature
    case invalidEvent
    case sealDecryptFailed
    case wrapMalformed
    case senderMismatch
    case notAuthenticated
    /// The relay closed a subscription demanding NIP-42 AUTH (e.g. khatru
    /// gating kind-1059 reads). The caller should authenticate with the
    /// challenge the relay just sent, then re-subscribe.
    case authRequired
    case publishDropped
    case blobNotFound
    case blobIntegrityFailure
}

/// secp256k1 Schnorr keypair for Nostr event signing (BIP-340).
/// Auxiliary randomness is injected via `RandomSource` so tests and frozen
/// vectors are deterministic.
public struct NostrKeypair: Sendable {
    public let privateKeyData: Data
    public let publicKeyHex: String

    public init(privateKey: Data) throws {
        guard privateKey.count == 32,
            let key = try? P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        else { throw NostrError.invalidKey }
        self.privateKeyData = privateKey
        self.publicKeyHex = Data(key.xonly.bytes).hexString
    }

    public init(randomSource: any RandomSource) throws {
        // Rejection-sample until the scalar is valid for the curve (overwhelmingly first try).
        while true {
            let candidate = randomSource.bytes(32)
            if let key = try? P256K.Schnorr.PrivateKey(dataRepresentation: candidate) {
                self.privateKeyData = candidate
                self.publicKeyHex = Data(key.xonly.bytes).hexString
                return
            }
        }
    }

    public var npub: String { Bech32.npub(publicKeyHex) }

    /// Signs an event (fills `id` + `sig`). The event's `pubkey` must be ours.
    public func sign(_ event: NostrEvent, randomSource: any RandomSource) throws -> NostrEvent {
        guard event.pubkey == publicKeyHex else { throw NostrError.invalidKey }
        var signed = event
        signed.id = event.computedID()
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKeyData)
        // BIP-340 signs the 32-byte event id (= SHA-256 of the canonical form).
        guard let idData = Data(hexString: signed.id) else { throw NostrError.invalidEvent }
        var message = [UInt8](idData)
        var aux = [UInt8](randomSource.bytes(32))
        let signature = try aux.withUnsafeMutableBytes { auxPtr in
            try key.signature(message: &message, auxiliaryRand: auxPtr.baseAddress, strict: true)
        }
        signed.sig = signature.dataRepresentation.hexString
        return signed
    }

    public static func verify(_ event: NostrEvent) -> Bool {
        guard event.hasValidID(),
            let sigData = Data(hexString: event.sig), sigData.count == 64,
            let pubData = Data(hexString: event.pubkey), pubData.count == 32,
            let idData = Data(hexString: event.id), idData.count == 32,
            let signature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: sigData)
        else { return false }
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: pubData)
        var message = [UInt8](idData)
        return xonly.isValid(signature, for: &message)
    }
}
