// SPDX-License-Identifier: Apache-2.0
import Foundation

/// PQ rekey header (SPEC §6.2, NIP-XX §6): present only on the message that
/// carries a rekey.
public struct PQRekeyHeader: Codable, Equatable, Sendable {
    /// ML-KEM-768 ciphertext encapsulated to the receiver's current KEM pubkey.
    public let ct: Data
    /// Sender's fresh ML-KEM-768 pubkey, replacing their previous one (PQ3 inline rotation).
    public let pk: Data
    /// Monotonic rekey counter for HKDF domain separation.
    public let ctr: Int
    /// SHA-256 of the receiver KEM pubkey this rekey targeted. Rekeys cross in
    /// flight under concurrency; the receiver selects the matching private key
    /// from its retained history instead of guessing generations.
    public let tgt: Data

    public init(ct: Data, pk: Data, ctr: Int, tgt: Data) {
        self.ct = ct
        self.pk = pk
        self.ctr = ctr
        self.tgt = tgt
    }
}

/// Double Ratchet message header. Wire names match the NIP exactly:
/// `dh` (sender ratchet pubkey), `pn` (previous chain length), `n` (message
/// number), `pq` (optional rekey).
public struct RatchetHeader: Codable, Equatable, Sendable {
    public let dh: Data
    public let pn: Int
    public let n: Int
    public let pq: PQRekeyHeader?

    public init(dh: Data, pn: Int, n: Int, pq: PQRekeyHeader?) {
        self.dh = dh
        self.pn = pn
        self.n = n
        self.pq = pq
    }
}
