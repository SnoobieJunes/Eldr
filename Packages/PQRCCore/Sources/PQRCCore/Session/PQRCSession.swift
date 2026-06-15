import Crypto
import Foundation

/// Builds the AES-256-GCM associated data (SPEC §8.3, CLAUDE.md invariant 5):
/// AD = pqrc_version || participant_type || n || created_at_fuzzed.
/// The one legitimate place a timestamp appears — as authenticated context,
/// NEVER as key-derivation input.
public enum AssociatedData {
    public static func build(participantType: ParticipantType, n: Int, fuzzedTimestamp: Int64) -> Data {
        var ad = Data(PQRCConstants.version.utf8)
        ad.append(Data(participantType.rawValue.utf8))
        ad.append(Data(uint32BE: UInt32(n)))
        ad.append(Data(int64BE: fuzzedTimestamp))
        return ad
    }
}

/// Chooses the fuzzed `created_at`: up to 2 days into the PAST, never the
/// future (SPEC §8.4). Chosen once per message, before encryption, and reused
/// for the AD, the seal, and the gift wrap (APP-SPEC §2).
public enum TimestampFuzzer {
    public static func fuzzedTimestamp(clock: any Clock, randomSource: any RandomSource) -> Int64 {
        let now = clock.now()
        let randomBytes = randomSource.bytes(8)
        var value: UInt64 = 0
        for byte in randomBytes {
            value = value << 8 | UInt64(byte)
        }
        let offset = Int64(value % UInt64(PQRCConstants.timestampFuzzWindowSeconds + 1))
        return now - offset
    }
}

/// One encrypted, padded PQRC message ready to be wrapped, plus everything the
/// envelope layer needs.
public struct OutgoingMessage: Sendable {
    public let rumor: RumorContent
    /// Reused on the seal and the gift wrap (fuzz_sameValueUsedInADandWrap).
    public let fuzzedTimestamp: Int64

    public init(rumor: RumorContent, fuzzedTimestamp: Int64) {
        self.rumor = rumor
        self.fuzzedTimestamp = fuzzedTimestamp
    }
}

/// A 1:1 PQRC session: owns the Double Ratchet state for one pairwise link
/// (actors own all mutable session state — CLAUDE.md conventions).
public actor PQRCSession {
    public let peerIdentityPubkey: Data
    public private(set) var usedLastResortPrekey: Bool
    private var ratchet: DoubleRatchet
    private let clock: any Clock
    private let randomSource: any RandomSource

    /// Initiator construction (after PQXDH.initiate).
    public init(
        initiation: PQXDH.InitiationResult,
        peerIdentityPubkey: Data,
        clock: any Clock,
        randomSource: any RandomSource
    ) throws {
        self.peerIdentityPubkey = peerIdentityPubkey
        self.ratchet = try DoubleRatchet(initiatorWith: initiation, randomSource: randomSource)
        self.clock = clock
        self.randomSource = randomSource
        self.usedLastResortPrekey = false
    }

    /// Responder construction (after PQXDH.respond).
    public init(
        response: PQXDH.ResponseResult,
        myKEMPrivate: MLKEM768.PrivateKey,
        peerIdentityPubkey: Data,
        clock: any Clock,
        randomSource: any RandomSource
    ) {
        self.peerIdentityPubkey = peerIdentityPubkey
        self.ratchet = DoubleRatchet(
            responderWith: response, myKEMPrivate: myKEMPrivate, randomSource: randomSource
        )
        self.clock = clock
        self.randomSource = randomSource
        self.usedLastResortPrekey = response.usedLastResort
    }

    /// Restore from an encrypted-at-rest snapshot.
    public init(
        snapshot: RatchetSnapshot,
        peerIdentityPubkey: Data,
        usedLastResortPrekey: Bool,
        clock: any Clock,
        randomSource: any RandomSource
    ) throws {
        self.peerIdentityPubkey = peerIdentityPubkey
        self.ratchet = try DoubleRatchet(snapshot: snapshot, randomSource: randomSource)
        self.clock = clock
        self.randomSource = randomSource
        self.usedLastResortPrekey = usedLastResortPrekey
    }

    // MARK: - Send

    /// Pads, encrypts and packages a message body into a rumor.
    /// `inlinePayload` must be ≤ 64 KB; larger content goes through the
    /// `ContentPointer` path with only the (small) pointer body inlined.
    public func encrypt(
        body: MessageBody,
        type: RumorType = .message,
        participantType: ParticipantType,
        contentPointer: ContentPointer? = nil,
        aiWindow: AIWindowAnnouncement? = nil,
        handshake: HandshakeMessage? = nil
    ) throws -> OutgoingMessage {
        let plaintext = try WireJSON.encoder().encode(body)
        let padded = try Padding.pad(plaintext)
        let fuzzed = TimestampFuzzer.fuzzedTimestamp(clock: clock, randomSource: randomSource)
        let (header, ciphertext) = try ratchet.encrypt(paddedPlaintext: padded) { header in
            AssociatedData.build(participantType: participantType, n: header.n, fuzzedTimestamp: fuzzed)
        }
        let rumor = RumorContent(
            type: type,
            participantType: participantType,
            senderRole: participantType == .agent ? .agent : .identity,
            header: header,
            ciphertext: ciphertext,
            contentPointer: contentPointer,
            aiWindow: aiWindow,
            handshake: handshake
        )
        return OutgoingMessage(rumor: rumor, fuzzedTimestamp: fuzzed)
    }

    // MARK: - Receive

    /// Decrypts a rumor. Works on a copy of the ratchet and commits only on
    /// success, so failures (tamper, out-of-order beyond a pending rekey)
    /// leave the session intact for a later retry.
    public func decrypt(rumor: RumorContent, fuzzedTimestamp: Int64) throws -> MessageBody {
        guard let header = rumor.header, let ciphertext = rumor.ciphertext else {
            throw PQRCError.malformedRumor
        }
        // Reject out-of-range counters from the wire BEFORE building the AD: the
        // AD serializes `n` as UInt32, and `UInt32(Int)` TRAPS (it does not
        // truncate) on a negative or >2^32 value. A crafted header (`"n": -1`)
        // from an accepted contact would otherwise crash the app — and re-crash
        // on relaunch if the relay replays it. Garbage in known fields is never
        // fatal (SPEC §12, invariant 12).
        let maxCounter = Int(UInt32.max)
        guard (0...maxCounter).contains(header.n), (0...maxCounter).contains(header.pn) else {
            throw PQRCError.malformedRumor
        }
        let ad = AssociatedData.build(
            participantType: rumor.participantType, n: header.n, fuzzedTimestamp: fuzzedTimestamp
        )
        var working = ratchet
        let padded = try working.decrypt(header: header, ciphertext: ciphertext, associatedData: ad)
        let plaintext = try Padding.unpad(padded)
        let body = try WireJSON.decoder().decode(MessageBody.self, from: plaintext)
        ratchet = working
        return body
    }

    // MARK: - Persistence

    public func snapshot() -> RatchetSnapshot {
        ratchet.makeSnapshot()
    }

    public func skippedKeyCount() -> Int {
        ratchet.skippedKeyCount
    }
}
