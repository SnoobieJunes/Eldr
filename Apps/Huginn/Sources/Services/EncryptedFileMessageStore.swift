import Crypto
import Foundation
import PQRCCore

/// Append-only, encrypted-at-rest `MessageStore` for the Huginn macOS app.
///
/// Each conversation is one JSONL file under `directory`; each line is one
/// `StoredMessage`, envelope-encrypted via `EncryptedStore` before it touches
/// disk (APP-SPEC §3, SPEC §3.4, D9). `EncryptedStore`'s master key is itself
/// wrapped by the device secure element (Secure Enclave on Apple platforms,
/// invariant 10) — that key handling lives in `EncryptedStore`/the key wrapper;
/// this type only seals/opens record blobs.
///
/// Privacy (cardinal rule SPEC §0, invariant 12): NOTHING conversation- or
/// key-derived reaches disk in cleartext, and this type logs nothing.
///   - Filenames are `SHA256hex(conversationID).jsonl`, so the conversationID
///     (already an opaque, salted session key in production) never appears in a
///     path. The hash is one-way and filesystem-safe; it is NOT reversible, which
///     shapes the scan design below.
///   - Line bodies are AES-256-GCM blobs from `EncryptedStore.seal`; base64 is
///     only a transport-safe text wrapper around already-encrypted bytes.
///
/// Reversibility / scan model: because the filename is a hash, this store cannot
/// recover a conversationID from a file on disk — and `EncryptedStore.open`
/// needs the conversationID as the record key. So the conversation-scoped read
/// (`messages(conversationID:)`) — the only hot path, and the only one
/// `ConversationMemory` uses — always works, because the caller supplies the
/// conversationID. The cross-conversation scans (`messages(threadID:)`,
/// `message(id:)`, and the mutators) iterate a `known` map of conversationIDs
/// learned this process from `save`/`messages(conversationID:)`/
/// `deleteConversation`. After a cold start that map is empty, so a scan that
/// references a conversation never touched this process returns `[]` / not-found
/// until something re-supplies its id. `wipeAll` is exempt: it enumerates the
/// directory and so clears files for conversations it never learned.
actor EncryptedFileMessageStore: MessageStore {
    private let directory: URL
    private let store: EncryptedStore

    /// hashedFilename → conversationID, learned lazily this process (see scan
    /// model above). The key is the on-disk filename so lookups and removals are
    /// O(1) against a path; the value is the only thing that can open it.
    private var known: [String: String] = [:]

    init(directory: URL, store: EncryptedStore) {
        self.directory = directory
        self.store = store
    }

    // MARK: MessageStore

    func save(_ message: StoredMessage) async throws {
        remember(message.conversationID)
        try ensureDirectoryExists()
        let url = fileURL(for: message.conversationID)
        let line = try encodeLine(message)
        try append(line, to: url)
        trimIfNeeded(conversationID: message.conversationID, url: url)
    }

    // MARK: Bounding (B3)

    /// When a transcript file grows past `maxFileBytes`, re-seal only the newest messages that fit
    /// in `keepBytes`. Bounds BOTH the file size and the per-turn `priorContext` read cost (which
    /// decrypts the whole file), so a long-lived conversation no longer grows without limit or adds
    /// ever-increasing latency that reads as a slow AI. `keepBytes < maxFileBytes` so the trimmed
    /// file lands below the trigger and the next save can't immediately re-trim (no thrash) — even
    /// for large messages, since the budget is measured in real sealed line bytes, not record count.
    /// The injected context is byte-capped far below this (`transcriptContextMaxBytes` ~16 KB), so
    /// trimming older turns removes nothing the model would have been given.
    private static let maxFileBytes = 2_000_000
    private static let keepBytes = 1_000_000

    /// Best-effort — never throws into `save`; a trim failure just leaves the file untrimmed.
    private func trimIfNeeded(conversationID: String, url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > Self.maxFileBytes
        else { return }
        let msgs = readMessages(at: url, conversationID: conversationID)
        // Keep the newest messages that fit in `keepBytes` (always ≥1), measured by real sealed
        // line size so the retained file lands under `keepBytes`.
        var kept: [StoredMessage] = []
        var bytes = 0
        for message in msgs.reversed() {
            let lineSize = (try? encodeLine(message).count) ?? 0
            if !kept.isEmpty, bytes + lineSize > Self.keepBytes { break }
            kept.append(message)
            bytes += lineSize
        }
        guard kept.count < msgs.count else { return }  // nothing to drop
        try? rewrite(kept.reversed(), conversationID: conversationID, to: url)
    }

    func messages(conversationID: String) async throws -> [StoredMessage] {
        // Hot path: id is supplied, so this is correct even on a cold start.
        // Learn it for later cross-conversation scans.
        remember(conversationID)
        return readMessages(at: fileURL(for: conversationID), conversationID: conversationID)
    }

    func messages(threadID: String) async throws -> [StoredMessage] {
        // Scan of learned conversations only (see scan model). Cross-conversation
        // ordering is unspecified; within a file, save order is preserved.
        var result: [StoredMessage] = []
        for conversationID in known.values {
            let msgs = readMessages(at: fileURL(for: conversationID), conversationID: conversationID)
            result.append(contentsOf: msgs.filter { $0.threadID == threadID })
        }
        return result
    }

    func message(id: String) async throws -> StoredMessage? {
        for conversationID in known.values {
            let msgs = readMessages(at: fileURL(for: conversationID), conversationID: conversationID)
            if let found = msgs.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    func updateStatus(messageID: String, status: String) async throws {
        try mutate(messageID: messageID) { $0.localStatus = status }
    }

    func setAIContext(messageID: String, value: Bool) async throws {
        try mutate(messageID: messageID) { $0.aiContext = value }
    }

    func setAIMarks(messageID: String, aiIDs: [String]) async throws {
        try mutate(messageID: messageID) { $0.aiMarks = aiIDs }
    }

    func deleteMessage(messageID: String) async throws {
        // Deliberately idempotent, matching `InMemoryMessageStore.deleteMessage`
        // (which does not throw on a missing id) rather than the recordNotFound
        // path of the mutators above. The documented caller — "Not sent"
        // tap-to-retry, which drops the failed copy before resending — relies on
        // delete-of-absent being a no-op, and a drop-in for InMemoryMessageStore
        // must share that contract.
        for conversationID in known.values {
            let url = fileURL(for: conversationID)
            var msgs = readMessages(at: url, conversationID: conversationID)
            guard let index = msgs.firstIndex(where: { $0.id == messageID }) else { continue }
            msgs.remove(at: index)
            try rewrite(msgs, conversationID: conversationID, to: url)
            return
        }
    }

    func deleteConversation(_ conversationID: String) async throws {
        let name = Self.hashedName(conversationID)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        known[name] = nil
    }

    func wipeAll() async throws {
        let fileManager = FileManager.default
        if let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            for entry in entries where entry.pathExtension == "jsonl" {
                try? fileManager.removeItem(at: entry)
            }
        }
        known.removeAll()
    }

    // MARK: File mapping

    /// `SHA256hex(conversationID).jsonl`. One-way and filesystem-safe; the
    /// conversationID never lands in a path (invariant 12).
    private static func hashedName(_ conversationID: String) -> String {
        let digest = SHA256.hash(data: Data(conversationID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".jsonl"
    }

    private func fileURL(for conversationID: String) -> URL {
        directory.appendingPathComponent(Self.hashedName(conversationID))
    }

    private func remember(_ conversationID: String) {
        known[Self.hashedName(conversationID)] = conversationID
    }

    private func ensureDirectoryExists() throws {
        // B4: owner-only (0700) so a local user can't even enumerate the transcript files. The
        // bodies are ciphertext, but the directory listing would otherwise leak metadata (which
        // conversations exist, their line counts, sizes, mtimes) — below the at-rest bar the rest
        // of the app holds (cf. the env file's 0600). Only applied when WE create the directory.
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// B4: restrict a just-written transcript file to owner read/write (0600). Called after every
    /// atomic write (which creates a fresh inode with umask-default perms); the append-to-existing
    /// path preserves the 0600 set when the file was first created.
    private static func restrict(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Line codec

    /// Seal one message into a base64 line terminated by `\n`. The record key is
    /// `message.conversationID` (NOT `message.id`) so a reader can decrypt every
    /// line of a file knowing only the conversationID it asked for — without
    /// first learning each message id. Reusing one record-key across all of a
    /// file's lines is GCM-safe: `EncryptedStore.seal` draws a FRESH nonce from
    /// its injected `NonceSource` on every call, so no (key, nonce) pair repeats.
    private func encodeLine(_ message: StoredMessage) throws -> Data {
        let plaintext = try JSONEncoder().encode(message)
        let blob = try store.seal(plaintext, recordID: message.conversationID)
        var line = Data(blob.base64EncodedString().utf8)
        line.append(0x0A)  // "\n"
        return line
    }

    /// Decode a whole file's bytes into messages in file (save) order. A line
    /// that fails base64, decryption, or JSON decode is SKIPPED, never fatal —
    /// forward-compat tolerance (SPEC §12) for records a future build may write
    /// in a shape this one can't read, and resilience against a single corrupt
    /// line taking out an entire conversation.
    private func decodeLines(_ data: Data, conversationID: String) -> [StoredMessage] {
        let decoder = JSONDecoder()
        var result: [StoredMessage] = []
        for rawLine in data.split(separator: 0x0A) {  // omits empty subsequences
            let lineString = String(decoding: rawLine, as: UTF8.self)
            guard let blob = Data(base64Encoded: lineString),
                let plaintext = try? store.open(blob, recordID: conversationID),
                let message = try? decoder.decode(StoredMessage.self, from: plaintext)
            else { continue }
            result.append(message)
        }
        return result
    }

    /// Read + decode a conversation file. Returns `[]` for a missing or
    /// unreadable file (never crashes); the hot path treats "no file" as "no
    /// messages".
    private func readMessages(at url: URL, conversationID: String) -> [StoredMessage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decodeLines(data, conversationID: conversationID)
    }

    // MARK: Mutation

    /// Find the message by id across learned conversations, apply `transform`,
    /// and atomically rewrite that one file. Throws `recordNotFound` if no
    /// learned conversation holds the id (matching `InMemoryMessageStore`).
    private func mutate(
        messageID: String, _ transform: (inout StoredMessage) -> Void
    ) throws {
        for conversationID in known.values {
            let url = fileURL(for: conversationID)
            var msgs = readMessages(at: url, conversationID: conversationID)
            guard let index = msgs.firstIndex(where: { $0.id == messageID }) else { continue }
            transform(&msgs[index])
            try rewrite(msgs, conversationID: conversationID, to: url)
            return
        }
        throw PQRCError.recordNotFound
    }

    /// Re-seal every message and replace the file atomically. Each message is
    /// sealed afresh (new nonce per line via `encodeLine`), so a rewrite never
    /// reuses a (key, nonce) pair.
    private func rewrite(
        _ messages: [StoredMessage], conversationID: String, to url: URL
    ) throws {
        try ensureDirectoryExists()
        var data = Data()
        for message in messages {
            data.append(try encodeLine(message))
        }
        try data.write(to: url, options: .atomic)
        Self.restrict(url)  // B4: the atomic write made a new inode — re-restrict to 0600.
    }

    // MARK: Append

    /// Append one sealed line, creating the file on first write. Existing files
    /// are opened for writing and seeked to the end; this keeps the JSONL strictly
    /// append-only on the common path (rewrites happen only for edits/deletes).
    private func append(_ line: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            // `forUpdating` (O_RDWR), not `forWritingTo` (O_WRONLY): the B5 torn-write check below
            // must READ the last byte, which a write-only handle rejects.
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            // B5: if a crash tore the PREVIOUS append mid-write, the file ends without a trailing
            // "\n". Concatenating this record straight onto that partial would merge two records into
            // one line → base64 decode fails → BOTH silently vanish (cascading corruption). Detect the
            // torn write (last byte != "\n") and emit a separating "\n" first, so the partial becomes
            // its OWN line that `decodeLines` harmlessly skips and this record stays intact. Best-effort
            // and cheap: seek back one byte, read it, seek back to end. Empty file (end == 0) needs none.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let last = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if last != Data([0x0A]) { try handle.write(contentsOf: Data([0x0A])) }
            }
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
            Self.restrict(url)  // B4: first write of this conversation's file — set 0600.
        }
    }
}