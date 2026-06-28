import CryptoKit
import Foundation

/// Shared AES-256-GCM codec for the eldr-acp at-rest METADATA files (`events.jsonl`,
/// `eldr.md`) — the redacted/summarized, conversation-derived sinks that the privacy pass
/// brings under encryption alongside the full conversation transcript (SPEC §0/§3.4, D9).
///
/// It lives in PQRCACP on purpose: the **agent process** (which writes `events.jsonl` and
/// reads `eldr.md`) and **Huginn's `ContextLearner`** (which reads `events.jsonl` and
/// writes `eldr.md`) are two different processes, and Huginn already imports PQRCACP — so
/// both sides call this ONE implementation and their framing can never drift.
///
/// Layout is byte-identical to `PQRCCore.EncryptedStore`: `nonce(12) || ciphertext ||
/// tag(16)` (exactly `AES.GCM.SealedBox.combined`, whose nonce is a fresh CryptoKit random
/// per seal — GCM-safe under a reused key). The 32-byte key is derived by Huginn from the
/// Secure-Enclave-wrapped master key (`EncryptedStore.deriveKey`) and handed to the agent
/// via its environment; this type never persists, derives, or logs it (invariant 12).
public enum ACPMetadataCrypto {

    /// Seal `plaintext` under `key`. Returns nil on any failure — callers fall back to a
    /// safe no-op (e.g. skip the log line) rather than writing cleartext.
    public static func seal(_ plaintext: Data, key: Data) -> Data? {
        guard key.count == 32,
            let sealed = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        else { return nil }
        return sealed.combined
    }

    /// Open a `nonce||ciphertext||tag` blob under `key`. Returns nil for a wrong key, a
    /// truncated/corrupt blob, or a plaintext (un-sealed) input — the caller decides what a
    /// failed open means (skip the line / treat as absent).
    public static func open(_ blob: Data, key: Data) -> Data? {
        guard key.count == 32, blob.count >= 28,
            let box = try? AES.GCM.SealedBox(combined: blob),
            let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key))
        else { return nil }
        return plaintext
    }

    // MARK: Convenience for the two on-disk shapes

    /// Seal one event-log line and return it as a base64 ASCII string (so `events.jsonl`
    /// stays a line-delimited text file, just with each line encrypted). nil on failure.
    public static func sealLine(_ line: String, key: Data) -> String? {
        seal(Data(line.utf8), key: key)?.base64EncodedString()
    }

    /// Open one base64 event-log line back to its plaintext string. nil if the line isn't a
    /// valid sealed line under `key` (e.g. a legacy plaintext line — caller can fall back).
    public static func openLine(_ base64Line: String, key: Data) -> String? {
        guard let blob = Data(base64Encoded: base64Line.trimmingCharacters(in: .whitespacesAndNewlines)),
            let plaintext = open(blob, key: key)
        else { return nil }
        return String(decoding: plaintext, as: UTF8.self)
    }
}
