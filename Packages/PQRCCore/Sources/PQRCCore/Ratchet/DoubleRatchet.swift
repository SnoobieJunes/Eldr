import Crypto
import Foundation

/// The Signal Double Ratchet (SPEC §5), unmodified in its core algorithm, plus
/// the PQ3-pattern periodic ML-KEM-768 rekey (SPEC §6).
///
/// Key rotation here is message-driven only. This type deliberately has no
/// access to any `Clock` — enforced by TEST-PLAN §4
/// `noTimers_keyScheduleHasNoClockDependency`.
///
/// Value semantics are load-bearing: `decrypt` works on a copy and callers
/// commit the new state only on success, so a failed or out-of-order decrypt
/// never corrupts the live session.
public struct DoubleRatchet: Sendable {
    // MARK: Ratchet state (Signal DR spec names)

    var rootKey: SymmetricKey
    var dhs: Curve25519.KeyAgreement.PrivateKey
    var dhr: Data?
    var cks: SymmetricKey?
    var ckr: SymmetricKey?
    var ns = 0
    var nr = 0
    var pn = 0

    // MARK: PQ rekey state (SPEC §6)

    var messagesSinceRekey = 0
    var rekeyCounter = 0
    /// Our recent KEM private keys, oldest→newest (current = last). Peers'
    /// rekeys name their target by hash (`pq.tgt`); a bounded history absorbs
    /// rekeys that crossed several of our own rotations in flight.
    struct KEMKey: Sendable {
        let pubkeyHash: Data
        let key: MLKEM768.PrivateKey
    }
    var myKEMs: [KEMKey]
    static let maxKEMHistory = 8
    var peerKEM: Data
    /// Highest peer rekey counter applied — guards against out-of-order peer
    /// rekeys regressing `peerKEM`.
    var peerRekeyCounter = 0
    /// Deferred root folds (NIP-XX §6): a rekey refreshes the ACTIVE chain
    /// immediately, but its secret folds into the root only at the next DH
    /// ratchet boundary, where both parties apply it at the SAME root-chain
    /// position (ours: before our send-half; peer's: before their chain's
    /// recv-half). Folding eagerly would desynchronize the root in
    /// bidirectional conversations.
    var pendingOutboundRootFolds: [Data] = []
    var pendingInboundRootFolds: [Data] = []

    // MARK: Skipped message keys (SPEC §5.3)

    struct SkippedKey: Sendable {
        let chain: Data
        let n: Int
        let messageKey: SymmetricKey
    }
    var skipped: [SkippedKey] = []

    let randomSource: any RandomSource

    // MARK: - Init

    /// Initiator: peer's signed prekey doubles as their initial ratchet pubkey.
    public init(initiatorWith handshake: PQXDH.InitiationResult, randomSource: any RandomSource) throws {
        self.randomSource = randomSource
        self.dhs = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
        self.dhr = handshake.peerRatchetPubkey
        let peerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: handshake.peerRatchetPubkey)
        let dhOut = try dhs.sharedSecretFromKeyAgreement(with: peerPub)
        let (newRoot, chainKey) = Self.kdfRootKey(handshake.sharedSecret, dhOut)
        self.rootKey = newRoot
        self.cks = chainKey
        self.ckr = nil
        self.myKEMs = [
            KEMKey(
                pubkeyHash: sha256(handshake.myKEMPrivate.publicKey.rawRepresentation),
                key: handshake.myKEMPrivate)
        ]
        self.peerKEM = handshake.peerKEMPubkey
    }

    /// Responder: our signed prekey private half is our initial ratchet keypair.
    public init(
        responderWith response: PQXDH.ResponseResult,
        myKEMPrivate: MLKEM768.PrivateKey,
        randomSource: any RandomSource
    ) {
        self.randomSource = randomSource
        self.rootKey = response.sharedSecret
        self.dhs = response.myRatchetPrivate
        self.dhr = nil
        self.cks = nil
        self.ckr = nil
        self.myKEMs = [
            KEMKey(
                pubkeyHash: sha256(myKEMPrivate.publicKey.rawRepresentation), key: myKEMPrivate)
        ]
        self.peerKEM = response.peerKEMPubkey
    }

    public var currentRekeyCounter: Int { rekeyCounter }
    public var skippedKeyCount: Int { skipped.count }

    // MARK: - Encrypt

    /// Encrypts one already-padded plaintext. `associatedData` receives the
    /// final header (the caller binds version/participant_type/n/fuzzed
    /// timestamp per SPEC §8.3).
    public mutating func encrypt(
        paddedPlaintext: Data,
        associatedData: (RatchetHeader) throws -> Data
    ) throws -> (header: RatchetHeader, ciphertext: Data) {
        guard cks != nil else { throw PQRCError.sessionNotEstablished }

        // PQ rekey trigger: message-count-driven, exactly every 50 (SPEC §6.1).
        messagesSinceRekey += 1
        var pqHeader: PQRekeyHeader?
        if messagesSinceRekey >= PQRCConstants.pqRekeyInterval {
            pqHeader = try performOutboundRekey()
            messagesSinceRekey = 0
        }

        guard let chainKey = cks else { throw PQRCError.sessionNotEstablished }
        let (messageKey, nextChainKey) = Self.kdfChainKey(chainKey)
        cks = nextChainKey

        let header = RatchetHeader(
            dh: dhs.publicKey.rawRepresentation, pn: pn, n: ns, pq: pqHeader
        )
        ns += 1

        let ad = try associatedData(header)
        let ciphertext = try Self.aeadSeal(messageKey: messageKey, plaintext: paddedPlaintext, ad: ad)
        return (header, ciphertext)
    }

    // MARK: - Decrypt

    /// Attempts to decrypt. On ANY failure the receiver's live state must stay
    /// untouched — call as `var copy = ratchet; try copy.decrypt(...); ratchet = copy`.
    /// `PQRCSession` does exactly this.
    public mutating func decrypt(
        header: RatchetHeader,
        ciphertext: Data,
        associatedData: Data
    ) throws -> Data {
        // 1. Skipped-key cache hit (out-of-order arrival within MAX_SKIP).
        if let cached = takeSkippedKey(chain: header.dh, n: header.n) {
            return try Self.aeadOpen(messageKey: cached, ciphertext: ciphertext, ad: associatedData)
        }

        // 2. DH ratchet step on a new remote ratchet key (round-trip → PCS).
        if header.dh != dhr {
            try skipReceivingChain(until: header.pn)
            try dhRatchetStep(newRemoteKey: header.dh)
        }

        // 3. Replay of an already-consumed message number.
        if header.n < nr {
            throw PQRCError.duplicateMessage(chain: header.dh, n: header.n)
        }

        // 4. Skip ahead on the current chain (old-chain keys derived BEFORE any
        //    rekey in this header is applied — those messages predate it).
        try skipReceivingChain(until: header.n)

        // 5. Inbound PQ rekey, bound to exactly this (chain, n) position.
        if let pq = header.pq {
            try applyInboundRekey(pq)
            messagesSinceRekey = 0
        } else {
            messagesSinceRekey += 1
        }

        guard let chainKey = ckr else { throw PQRCError.sessionNotEstablished }
        let (messageKey, nextChainKey) = Self.kdfChainKey(chainKey)
        let plaintext = try Self.aeadOpen(messageKey: messageKey, ciphertext: ciphertext, ad: associatedData)
        // Commit chain advance only after successful authentication.
        ckr = nextChainKey
        nr += 1
        return plaintext
    }

    // MARK: - DH ratchet

    private mutating func dhRatchetStep(newRemoteKey: Data) throws {
        pn = ns
        ns = 0
        nr = 0
        dhr = newRemoteKey
        let remotePub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: newRemoteKey)

        // Peer rekeys fold before the recv-half of the peer's new chain —
        // the peer applied the same folds before their send-half (NIP-XX §6).
        var inboundFolds = pendingInboundRootFolds
        pendingInboundRootFolds = []
        applyFolds(inboundFolds)
        // The folds (KEM shared secrets) are now consumed into the root; wipe
        // the drained copies. `applyFolds` took them by value, so this changes
        // no derivation.
        for i in inboundFolds.indices { inboundFolds[i].zeroize() }
        let recvOut = try dhs.sharedSecretFromKeyAgreement(with: remotePub)
        let (rootAfterRecv, recvChain) = Self.kdfRootKey(rootKey, recvOut)
        rootKey = rootAfterRecv
        ckr = recvChain

        // Our own rekeys fold before our send-half — the peer applies them
        // before the recv-half of this new chain of ours.
        var outboundFolds = pendingOutboundRootFolds
        pendingOutboundRootFolds = []
        applyFolds(outboundFolds)
        for i in outboundFolds.indices { outboundFolds[i].zeroize() }
        dhs = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
        let sendOut = try dhs.sharedSecretFromKeyAgreement(with: remotePub)
        let (rootAfterSend, sendChain) = Self.kdfRootKey(rootKey, sendOut)
        rootKey = rootAfterSend
        cks = sendChain
    }

    /// SPEC §6.2 root fold, applied in order at a synchronized position.
    private mutating func applyFolds(_ folds: [Data]) {
        for ss in folds {
            var ikm = rootKey.rawData
            ikm.append(ss)
            rootKey = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: ikm),
                salt: Data(PQRCConstants.rekeyHKDFSalt.utf8),
                info: Data("\(PQRCConstants.rekeyHKDFInfoPrefix)-root".utf8),
                outputByteCount: 32
            )
            // `deriveKey` has copied the IKM into its own (CryptoKit-zeroed)
            // key; wipe our transient old-root||ss copy now that `rootKey`
            // holds the independently derived successor.
            ikm.zeroize()
        }
    }

    // MARK: - PQ rekey (SPEC §6.2)

    private mutating func performOutboundRekey() throws -> PQRekeyHeader {
        let target = try MLKEM768.PublicKey(rawRepresentation: peerKEM)
        let encapsulation = try target.encapsulate()
        rekeyCounter += 1
        refreshChain(sending: true, ss: encapsulation.sharedSecret, counter: rekeyCounter)
        pendingOutboundRootFolds.append(encapsulation.sharedSecret.rawData)

        let fresh = try MLKEM768.PrivateKey(seedRepresentation: randomSource.bytes(64), publicKey: nil)
        myKEMs.append(
            KEMKey(pubkeyHash: sha256(fresh.publicKey.rawRepresentation), key: fresh))
        if myKEMs.count > Self.maxKEMHistory {
            myKEMs.removeFirst(myKEMs.count - Self.maxKEMHistory)
        }
        return PQRekeyHeader(
            ct: encapsulation.encapsulated,
            pk: fresh.publicKey.rawRepresentation,
            ctr: rekeyCounter,
            tgt: sha256(peerKEM)
        )
    }

    private mutating func applyInboundRekey(_ pq: PQRekeyHeader) throws {
        // The header names its target key; select it from our retained history
        // (rekeys may cross several of our own rotations in flight).
        guard let match = myKEMs.first(where: { $0.pubkeyHash == pq.tgt }),
            let sharedSecret = try? match.key.decapsulate(pq.ct)
        else {
            throw PQRCError.decryptionFailed
        }
        // pq.ctr is the SENDER's counter stream; it only domain-separates the
        // chain refresh. Our own outbound rekeyCounter is independent.
        refreshChain(sending: false, ss: sharedSecret, counter: pq.ctr)
        pendingInboundRootFolds.append(sharedSecret.rawData)
        // Never let an out-of-order older rekey regress the peer's current key.
        if pq.ctr >= peerRekeyCounter {
            peerRekeyCounter = pq.ctr
            peerKEM = pq.pk
        }
    }

    /// Immediate healing: the fresh ML-KEM secret refreshes the active chain,
    /// so every post-rekey message key on this chain requires the KEM secret.
    /// The root fold itself is deferred to the next DH boundary (see
    /// `dhRatchetStep`) to stay position-synchronized between the parties.
    private mutating func refreshChain(sending: Bool, ss: SymmetricKey, counter: Int) {
        var chainInfo = Data("\(PQRCConstants.rekeyHKDFInfoPrefix)-chain".utf8)
        chainInfo.append(Data(uint32BE: UInt32(counter)))
        func refreshed(_ chain: SymmetricKey) -> SymmetricKey {
            var chainIKM = chain.rawData
            var ssBytes = ss.rawData
            chainIKM.append(ssBytes)
            let next = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: chainIKM),
                salt: Data(PQRCConstants.rekeyHKDFSalt.utf8),
                info: chainInfo,
                outputByteCount: 32
            )
            // Bytes copied into `deriveKey`'s own zeroed key; wipe our transient
            // old-chain||ss copies (the returned chain is derived, unaffected).
            chainIKM.zeroize()
            ssBytes.zeroize()
            return next
        }
        if sending {
            if let chain = cks { cks = refreshed(chain) }
        } else {
            if let chain = ckr { ckr = refreshed(chain) }
        }
    }

    // MARK: - Skipped keys (SPEC §5.3)

    private mutating func skipReceivingChain(until n: Int) throws {
        guard nr < n else { return }
        guard let chain = dhr else { return }
        guard n - nr <= PQRCConstants.maxSkip else {
            throw PQRCError.skippedTooFar(requested: n - nr, max: PQRCConstants.maxSkip)
        }
        guard var chainKey = ckr else {
            // First message on a not-yet-started receiving chain can't be skipped past.
            if n > 0 { throw PQRCError.messageKeyUnavailable }
            return
        }
        while nr < n {
            let (messageKey, next) = Self.kdfChainKey(chainKey)
            skipped.append(SkippedKey(chain: chain, n: nr, messageKey: messageKey))
            chainKey = next
            nr += 1
        }
        ckr = chainKey
        // Bounded cache: evict oldest beyond MAX_SKIP (SPEC §5.3).
        if skipped.count > PQRCConstants.maxSkip {
            skipped.removeFirst(skipped.count - PQRCConstants.maxSkip)
        }
    }

    /// Returns and DELETES the cached key — message keys are used once (invariant 2).
    private mutating func takeSkippedKey(chain: Data, n: Int) -> SymmetricKey? {
        guard let index = skipped.firstIndex(where: { $0.chain == chain && $0.n == n }) else {
            return nil
        }
        let key = skipped[index].messageKey
        skipped.remove(at: index)
        return key
    }

    // MARK: - KDFs (Signal DR spec constructions; SPEC §2 vetted primitives only)

    /// KDF_RK: HKDF-SHA256(salt=rk, ikm=dh_out) → (root', chain).
    static func kdfRootKey(_ rootKey: SymmetricKey, _ dhOut: SharedSecret) -> (SymmetricKey, SymmetricKey) {
        var ikm = Data()
        dhOut.withUnsafeBytes { ikm.append(contentsOf: $0) }
        var salt = rootKey.rawData
        var okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data("pqrc-v1-ratchet-root".utf8),
            outputByteCount: 64
        ).rawData
        // `SymmetricKey(data:)` copies each half into its own zeroed storage;
        // build the results, then wipe the transient dh_out IKM, the root-key
        // salt copy, and the 64-byte OKM. Identical bytes, just not left behind.
        let result = (SymmetricKey(data: okm.prefix(32)), SymmetricKey(data: okm.suffix(32)))
        ikm.zeroize()
        salt.zeroize()
        okm.zeroize()
        return result
    }

    /// KDF_CK: message key = HMAC(ck, 0x01); next chain key = HMAC(ck, 0x02).
    static func kdfChainKey(_ chainKey: SymmetricKey) -> (messageKey: SymmetricKey, nextChainKey: SymmetricKey) {
        let mk = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: chainKey)
        let ck = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: chainKey)
        // `Data(mac)` materializes the raw key bytes; capture so we can wipe the
        // transient copies after `SymmetricKey(data:)` has copied them in. The
        // HMAC tags themselves (CryptoKit `HashedAuthenticationCode`) carry no
        // exposed mutable buffer, so the `Data` copies are the only ones we own.
        var mkBytes = Data(mk)
        var ckBytes = Data(ck)
        let result = (SymmetricKey(data: mkBytes), SymmetricKey(data: ckBytes))
        mkBytes.zeroize()
        ckBytes.zeroize()
        return result
    }

    /// Message key → AES-256-GCM key + deterministic 12-byte nonce. The nonce
    /// is derived (Signal pattern), never transmitted: each message key is used
    /// exactly once, so key/nonce reuse is structurally impossible.
    static func messageKeyMaterial(_ messageKey: SymmetricKey) -> (key: SymmetricKey, nonce: Data) {
        var okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: messageKey,
            salt: Data("pqrc-v1-msg".utf8),
            info: Data("pqrc-msgkeys".utf8),
            outputByteCount: 44
        ).rawData
        // `SymmetricKey(data:)` copies the AES key into its own zeroed storage.
        // The nonce is built via `Array(...)` to force an eager, independent
        // allocation — a plain `Data(slice)` can retain `okm`'s 44-byte backing
        // store, which would both alias the wipe and leave the key half of that
        // buffer un-zeroed. Same bytes out; only the lingering copy differs.
        let key = SymmetricKey(data: okm.prefix(32))
        let nonce = Data(Array(okm.suffix(12)))
        okm.zeroize()
        return (key, nonce)
    }

    static func aeadSeal(messageKey: SymmetricKey, plaintext: Data, ad: Data) throws -> Data {
        let (key, nonce) = messageKeyMaterial(messageKey)
        let sealed = try AES.GCM.seal(
            plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: ad
        )
        return sealed.ciphertext + sealed.tag
    }

    static func aeadOpen(messageKey: SymmetricKey, ciphertext: Data, ad: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw PQRCError.decryptionFailed }
        let (key, nonce) = messageKeyMaterial(messageKey)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16)
        )
        do {
            return try AES.GCM.open(box, using: key, authenticating: ad)
        } catch {
            throw PQRCError.decryptionFailed
        }
    }
}
