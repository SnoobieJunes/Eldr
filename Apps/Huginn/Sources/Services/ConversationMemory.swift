import Foundation
import PQRCCore

// MARK: - ConversationMemory
//
// Encrypted, on-disk transcript for the Huginn (Mac-Tethered-AI) node. It owns
// the master storage key, records each conversational turn as an
// envelope-encrypted record (via `EncryptedFileMessageStore`), and renders prior
// turns back as plain-text context for the tethered LLM (via
// `ConversationTranscriptRenderer`).
//
// Privacy is the contract (SPEC §0, CLAUDE.md invariant 12): nothing
// conversation-derived or key-derived is ever logged in plain text, and no
// payload bytes ever touch disk in the clear. Records are sealed by
// `EncryptedStore` (APP-SPEC §3, D9) under a 256-bit master key that is itself
// wrapped by the device's Secure Enclave (SPEC §3.4, invariant 10) and persisted
// — only in wrapped form — in the Keychain.

/// Actor that owns the encrypted conversation transcript: it bootstraps the
/// master key (Secure-Enclave-wrapped, Keychain-persisted), records turns
/// best-effort, and renders prior context on demand.
///
/// Two construction paths:
///  - Production `init(directory:keychain:wrapper:)` bootstraps an
///    `EncryptedStore` LAZILY from the Keychain-persisted wrapped master key, on
///    first use, inside the actor; the resulting store is cached.
///  - Test `init(directory:encryptedStore:)` injects the `EncryptedStore`
///    directly and NEVER touches the Keychain (so the suite runs on a headless
///    host with no usable Keychain).
///
/// All operations are forgiving by design: a turn must never throw or break
/// because storage was unavailable (e.g. a locked or absent Keychain), and a
/// failed bootstrap silently degrades to a no-op rather than crashing.
actor ConversationMemory {
    /// Keychain account holding the SE-wrapped master storage key. Deleting this
    /// item cryptographically shreds every transcript record — even files that
    /// linger on disk become unreadable, because they are sealed under a key that
    /// no longer exists anywhere (SPEC §3.4, invariant 10/12).
    static let masterKeyAccount = "transcript-master-key-wrapped"

    private let directory: URL
    /// nil for the test init (which never persists or shreds Keychain state).
    private let keychain: KeychainBox?
    /// The production master-key wrapper; nil for the test init (which injects the
    /// `EncryptedStore` directly and so needs no wrapper).
    private let wrapper: (any MasterKeyWrapper)?

    /// Cached message store. Set eagerly by the test init; bootstrapped lazily and
    /// cached by the production path on first use.
    private var store: EncryptedFileMessageStore?
    /// Once a production bootstrap has failed (e.g. Keychain unavailable on a
    /// headless host) we stop retrying and degrade to a no-op; cleared by `wipe()`
    /// so a fresh start is possible after the secrets are shredded.
    private var bootstrapFailed = false

    // MARK: Construction

    /// Production: lazily bootstraps an `EncryptedStore` from the Keychain-persisted
    /// wrapped master key. The default wrapper is the Secure Enclave wrapper
    /// (SPEC §3.4, D9); the master key never leaves memory unwrapped.
    init(
        directory: URL,
        keychain: KeychainBox = KeychainBox(),
        wrapper: (any MasterKeyWrapper)? = nil
    ) {
        self.directory = directory
        self.keychain = keychain
        self.wrapper = wrapper ?? MacSecureEnclaveKeyWrapper(keychain: keychain)
        self.store = nil
    }

    /// Tests: inject the `EncryptedStore` directly, bypassing the Keychain entirely
    /// (no wrapper, no persisted master key, nothing to shred).
    init(directory: URL, encryptedStore: EncryptedStore) {
        self.directory = directory
        self.keychain = nil
        self.wrapper = nil
        self.store = EncryptedFileMessageStore(directory: directory, store: encryptedStore)
    }

    // MARK: Public surface

    /// Records one conversational turn. BEST-EFFORT: it never throws and never
    /// breaks the turn it is recording. If the store can't be bootstrapped (e.g.
    /// the Keychain is unavailable in a headless test host) this silently no-ops —
    /// it does not crash and it logs no plaintext (invariant 12).
    func record(
        _ text: String,
        as type: ParticipantType,
        senderIdentity: String,
        sessionKey: String,
        threadID: String?,
        agentName: String?
    ) async {
        guard let store = ensureStore() else { return }
        let message = StoredMessage(
            id: UUID().uuidString,
            conversationID: sessionKey,
            senderIdentity: senderIdentity,
            participantType: type,
            text: text,
            sentAt: Int64(Date().timeIntervalSince1970 * 1000),
            threadID: threadID,
            agentName: agentName
        )
        // Best-effort: a sealing/IO failure must not surface as a thrown turn.
        try? await store.save(message)
    }

    /// Renders the prior turns of `sessionKey` as a single plain-text transcript,
    /// byte-capped to `maxBytes` for the model's context window. Returns nil when
    /// there is no prior context or the store is unavailable.
    func priorContext(sessionKey: String, maxBytes: Int) async -> String? {
        guard let store = ensureStore() else { return nil }
        guard let messages = try? await store.messages(conversationID: sessionKey),
            !messages.isEmpty
        else { return nil }
        let rendered = ConversationTranscriptRenderer.renderCapped(messages, maxBytes: maxBytes)
        return rendered.isEmpty ? nil : rendered
    }

    /// Wipes the transcript. Removes the encrypted record files AND deletes the
    /// Keychain secrets — the wrapped master key plus the SE wrapping key and the
    /// software-KEK fallback. Deleting the wrapped master key alone cryptographically
    /// shreds all transcripts even if record files linger on disk, because they are
    /// sealed under a key that no longer exists (SPEC §3.4, invariant 10/12); the
    /// file removal is belt-and-suspenders. The test init holds no Keychain, so the
    /// deletes are nil-guarded.
    ///
    /// We wipe via the CACHED store only (`store?`), never `ensureStore()`: a wipe
    /// must never *bootstrap* a fresh master key just to delete it. If the store was
    /// never opened this process, the files (if any) are left as inert ciphertext and
    /// the Keychain deletes below shred the key that could ever read them.
    func wipe() async {
        try? await store?.wipeAll()
        keychain?.delete(account: Self.masterKeyAccount)
        keychain?.delete(account: MacSecureEnclaveKeyWrapper.seKeyAccount)
        keychain?.delete(account: MacSecureEnclaveKeyWrapper.softwareKEKAccount)
        // Drop the cached store (its master key is now shredded) and allow a fresh
        // bootstrap on the next use.
        store = nil
        bootstrapFailed = false
    }

    // MARK: Lazy bootstrap

    /// Returns the cached store, bootstrapping it once for the production path.
    /// Synchronous and actor-isolated, so the two-init bootstrap stays race-free.
    /// On any failure it caches the failure and returns nil — never throws, never
    /// logs key/plaintext.
    private func ensureStore() -> EncryptedFileMessageStore? {
        if let store { return store }
        // Test init (no keychain/wrapper) sets `store` eagerly above; if we reach
        // here without them, there is nothing to bootstrap.
        guard let keychain, let wrapper, !bootstrapFailed else { return nil }
        do {
            let encryptedStore: EncryptedStore
            if let blob = keychain.load(account: Self.masterKeyAccount) {
                let masterKey = try wrapper.unwrap(wrapped: blob)
                encryptedStore = EncryptedStore(masterKey: masterKey, nonceSource: SystemNonceSource())
            } else {
                let fresh = EncryptedStore(
                    randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
                let blob = try fresh.wrappedMasterKey(using: wrapper)
                try keychain.save(blob, account: Self.masterKeyAccount)
                encryptedStore = fresh
            }
            let built = EncryptedFileMessageStore(directory: directory, store: encryptedStore)
            store = built
            return built
        } catch {
            // Bootstrap failed (e.g. Keychain unavailable in a headless test host).
            // Degrade to a silent no-op — never crash, never log key/plaintext bytes
            // (invariant 12). The error value itself carries no payload, but we drop
            // it rather than risk surfacing it through a logging seam.
            bootstrapFailed = true
            return nil
        }
    }
}
