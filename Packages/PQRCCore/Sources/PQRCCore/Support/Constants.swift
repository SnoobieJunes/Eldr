import Foundation

/// Protocol constants (SPEC §14). Values are normative; tests assert them.
public enum PQRCConstants {
    /// Protocol version string carried in every rumor and event tag.
    public static let version = "1"

    /// ML-KEM rekey cadence in messages — exactly 50 (SPEC §6.1).
    /// Message-driven, never wall-clock-driven (SPEC §5.2).
    public static let pqRekeyInterval = 50

    /// Bounded skipped-message-key cache (SPEC §5.3).
    public static let maxSkip = 1000

    /// Fixed-size padding buckets in bytes (SPEC §7).
    public static let paddingBuckets = [256, 1024, 4096, 16384, 65536]

    /// Plaintext above this size is never inlined; Blossom pointer or chunking only (SPEC §11).
    public static let inlineSizeLimit = 65536

    /// Per-chunk raw UTF-8 text budget for relay chunking. Deliberately well
    /// under `inlineSizeLimit` so the JSON-encoded `MessageBody` (string-escaped
    /// text + metadata) always fits the top padding bucket, even with worst-case
    /// escape expansion. Text at or below this size sends in a single envelope.
    public static let maxChunkTextBytes = 24 * 1024

    /// Hard ceiling on parts per chunked message (≈ 6 MB of text). Beyond this,
    /// content belongs in a Blossom blob, not the relay.
    public static let maxChunksPerMessage = 256

    /// `created_at` fuzz window: up to 2 days into the PAST, never the future (SPEC §8.4).
    public static let timestampFuzzWindowSeconds: Int64 = 2 * 24 * 60 * 60

    /// HKDF salts and info strings (SPEC §3.2, §4.2, §6.2).
    public static let agentHKDFSalt = "pqrc-v1"
    public static let agentHKDFInfoPrefix = "pqrc-agent-v1"
    public static let handshakeHKDFSalt = "pqrc-v1-handshake"
    public static let handshakeHKDFInfoPrefix = "pqrc-root-key"
    public static let rekeyHKDFSalt = "pqrc-v1-rekey"
    public static let rekeyHKDFInfoPrefix = "pqrc-pq-rekey"

    /// Event kinds (SPEC §14).
    public static let bindingEventKind = 10420
    public static let prekeyBundleEventKind = 10421
    public static let dmRelayListEventKind = 10050
    public static let sealEventKind = 13
    public static let giftWrapEventKind = 1059
    /// Inner unsigned rumor kind (NIP-XX; APP-SPEC §2 send pipeline).
    public static let rumorEventKind = 1420

    /// Handshake suite identifier (APP-SPEC §18 D2): explicit PQXDH hybrid.
    public static let handshakeSuite = "hybrid-v1"

    /// Thread agent loop guard (APP-SPEC §18 D14): pause after this many
    /// consecutive agent messages with no human message.
    public static let agentLoopGuardLimit = 6
}
