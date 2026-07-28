// SPDX-License-Identifier: Apache-2.0
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

    /// Per-chunk budget, measured as JSON-ESCAPED text bytes, for relay
    /// chunking. Sized so the encoded `MessageBody` (escaped text + metadata)
    /// lands in the 16384 padding bucket — NOT the 65536 bucket. That matters
    /// because each layer of the gift wrap (rumor → seal → wrap) base64-expands
    /// the payload ~1.33×, so a 65536-bucket message becomes a ~156 KB event,
    /// while a 16384-bucket message stays ~40 KB — under the 65535-byte content
    /// limit common relays (e.g. khatru) enforce. Measuring ESCAPED size keeps
    /// escape-heavy content (code, quotes, newlines) from overflowing the bucket.
    /// Text at or below this size sends in a single envelope.
    public static let maxChunkTextBytes = 15_000

    /// Hard ceiling on parts per chunked message. Kept below `maxSkip` (1000)
    /// so that even fully-reordered chunk arrival (e.g. from parallel publish)
    /// can't overrun the ratchet's skipped-key cache. At the adaptive top chunk
    /// size this is many MB / millions of tokens of text — enough to share a
    /// frontier-LLM-sized context in one logical message.
    public static let maxChunksPerMessage = 512

    /// Largest per-chunk JSON-escaped text budget whose gift-wrapped event still
    /// fits `relayContentLimit` (a relay's NIP-11 `max_content_length`). Picks
    /// the biggest padding bucket whose wrapped size fits, then leaves headroom
    /// for `MessageBody` metadata. The wrap expands the padded plaintext ~2.4×
    /// (rumor → seal → wrap, each base64-encoded); 2.6× + fixed slack is the
    /// conservative bound. Falls back to `maxChunkTextBytes` (the 16384-bucket
    /// budget, safe on the strict 65535-limit relays common in the wild) when
    /// the relay's limit is unknown.
    public static func chunkTextBudget(relayContentLimit: Int?) -> Int {
        guard let limit = relayContentLimit else { return maxChunkTextBytes }
        for bucket in paddingBuckets.reversed() {  // 65536, 16384, …, 256
            let estimatedEvent = Int(Double(bucket) * 2.6) + 2048
            if estimatedEvent <= limit {
                return max(200, bucket - 1024)  // room for metadata within the bucket
            }
        }
        return 200  // even the smallest bucket doesn't fit — tiny chunks
    }

    /// `created_at` fuzz window: up to 2 days into the PAST, never the future (SPEC §8.4).
    public static let timestampFuzzWindowSeconds: Int64 = 2 * 24 * 60 * 60

    /// NIP-40 expiration window: gift-wraps carry an `expiration` tag this far
    /// past their (fuzzed) `created_at`, so a NIP-40 relay auto-deletes them.
    /// Anchored to the FUZZED timestamp, not real now, so the tag leaks no timing
    /// the public `created_at` doesn't already (expiration − window == created_at).
    /// Effective relay retention is therefore 5–7 days (the fuzz is up to 2 days
    /// into the past). Privacy + minimized server footprint (SPEC §0).
    public static let expirationWindowSeconds: Int64 = 7 * 24 * 60 * 60

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
    /// Ephemeral receiving key (SPEC §9.3 strong mitigation, NIP-XX §13). A
    /// replaceable event advertising a rotating X25519 sub-key used as the
    /// gift-wrap `p` tag so the long-term identity npub never appears on a relay.
    public static let ephemeralReceivingKeyEventKind = 10422
    public static let dmRelayListEventKind = 10050
    public static let sealEventKind = 13
    public static let giftWrapEventKind = 1059
    /// Inner unsigned rumor kind (NIP-XX; APP-SPEC §2 send pipeline).
    public static let rumorEventKind = 1420

    /// Handshake suite identifier (APP-SPEC §18 D2): explicit PQXDH hybrid.
    ///
    /// Bumped v1 → v2 when the handshake gained PQXDH's dh2 leg and the
    /// `ik_dh_sig` binding. Both change the wire format and the derived SK, and
    /// the suite string is exactly the mechanism that turns that into a legible
    /// `handshakeSuiteUnsupported` for a peer on the old build instead of a
    /// handshake that "succeeds" and then silently fails to decrypt anything.
    public static let handshakeSuite = "hybrid-v2"

    /// Thread agent loop guard (APP-SPEC §18 D14): pause after this many
    /// consecutive agent messages with no human message.
    public static let agentLoopGuardLimit = 6

    // MARK: - Standing town grants (GOOSEWORLD §5, DEVIATIONS AC126)

    /// Hard ceiling on a standing town grant's remaining life, in seconds.
    ///
    /// 30 days. The whole reason standing grants exist is that `ai_window`'s
    /// hours-scale cap (`AgentEngine.maxWindowDuration`, 24h) cannot span a
    /// multi-day two-town co-build. But "longer" must never become "unbounded":
    /// invariant 9 survives only because every authorization eventually lapses on
    /// its own, so a forgotten grant is self-healing. A month is long enough for
    /// any realistic build and short enough that a grant nobody remembers issuing
    /// dies before it can be inherited by a compromised town.
    ///
    /// Enforced on BOTH sides: the issuer may only pick from
    /// ``allowedStandingGrantDurations``; the receiver rejects anything claiming
    /// more life than this, so a hostile peer cannot mint itself a decade.
    public static let maxStandingGrantDuration: Int64 = 30 * 24 * 60 * 60

    /// The durations a human may actually choose when issuing a standing grant,
    /// in seconds: 1, 3, 7, 14, and 30 days.
    ///
    /// A closed set rather than a free-form number, for the same reason
    /// `AgentEngine.allowedWindowDurations` is one: a picker with five entries is
    /// a decision a human can audit at a glance, and it removes the "1 second
    /// under the cap" fiddling that turns a bound into a formality.
    public static let allowedStandingGrantDurations: [Int64] = [1, 3, 7, 14, 30].map {
        $0 * 24 * 60 * 60
    }

    /// Seconds per UTC day — the window standing-grant budgets are accounted in.
    ///
    /// Budgets roll over by comparing `floor(clock.now() / secondsPerDay)` at
    /// call time. That is deliberately NOT a timer: CLAUDE.md invariant 1 bans
    /// wall-clock-driven scheduling, and a `Timer`/`Task.sleep` reset would also
    /// mean a backgrounded phone's budget silently failed to roll. Evaluating the
    /// day index on access is exact, side-effect free, and testable by moving an
    /// injected clock. Unix time is UTC-anchored, so this needs no calendar and no
    /// timezone (which would otherwise be a per-device metadata leak).
    public static let secondsPerDay: Int64 = 24 * 60 * 60

    /// The most distinct LIVE standing grants a single granter may hold in the
    /// engine at once (each grant may expand to one record per plane).
    ///
    /// The receive path admits a grant only from a VERIFIED contact, but "verified"
    /// is invite-based, not "trusted with the node's memory": a paired-but-hostile
    /// peer can sign an unbounded number of grants naming distinct `peer` hexes
    /// (each a fresh dictionary key), and without a cap that is a memory-exhaustion
    /// primitive fed by another person's machine — the exact unbounded-append DoS
    /// the cross-town wall (AC129) is bounded against, so the grant store is bounded
    /// to match. A re-issue of an existing grant id (a top-up) is always honored and
    /// does not count against the cap; only NEW grant ids past the cap are refused,
    /// fail-closed. 64 is far above any real co-build (you pair with a handful of
    /// towns, not thousands) and small enough that the store can never blow up.
    public static let maxStandingGrantsPerGranter = 64
}
