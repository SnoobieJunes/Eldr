// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr

/// Persists the node's conversation state so a restart does not break the owner's chat.
///
/// Before this, eldr-node kept ratchet sessions only in memory and saved prekey state once
/// at startup: after any restart the owner's existing session could no longer decrypt
/// (see DEVIATIONS "eldr-node session persistence"). This store follows the Linux client's
/// approach (`EldrClientCore`): the contact is kept as its signed kind-10420 binding EVENT
/// and re-verified OFFLINE at launch (never a cached "verified" flag); the ratchet
/// snapshot, prekey state and delivered-wrap IDs are saved after every send / receive /
/// accept. Storage is injected (the executable passes its encrypted `IdentityStore`), so
/// this type is platform-agnostic and unit-tested over `LocalRelaySimulator`.
public actor NodeSessionStore {
    struct Saved: Codable {
        var contacts: [SavedContact] = []
        var seenWrapIDs: [String] = []
    }
    struct SavedContact: Codable {
        var bindingEvent: NostrEvent
        var session: RatchetSnapshot?
    }

    public static let maxSeen = 5000
    private let messenger: PQRCMessenger
    private let prekeyManager: PrekeyManager
    private let load: @Sendable () -> Data?
    private let save: @Sendable (Data) throws -> Void
    private let savePrekeys: @Sendable (Data) throws -> Void
    private var saved = Saved()
    public private(set) var lastSaveError: String?
    private var readOnly = false

    /// Only this identity is ever persisted as a contact (the node serves its owner only).
    private let ownerIdentityHex: String
    /// AC167: after a handshake spends a one-time prekey, refill and republish so the
    /// relay never advertises a spent OTP (a reinstalled owner drawing one is refused as
    /// a replay). Empty = never republish (tests / offline).
    private let republishRelayURLs: [String]
    private let oneTimePrekeyTarget: Int
    private var republishing = false

    private func refillIfConsumed() async -> Bool {
        guard !republishRelayURLs.isEmpty,
            await prekeyManager.oneTimePrekeyCount < oneTimePrekeyTarget
        else { return false }
        return (try? await prekeyManager.replenish(to: oneTimePrekeyTarget)) == true
    }

    private func republish() {
        guard !republishing else { return }
        republishing = true
        let m = messenger, urls = republishRelayURLs
        Task { [weak self] in
            try? await m.announce(relayURLs: urls, maxAttempts: 3)
            await self?.republishDone()
        }
    }
    private func republishDone() { republishing = false }

    public init(
        messenger: PQRCMessenger, prekeyManager: PrekeyManager, ownerIdentityHex: String,
        load: @escaping @Sendable () -> Data?,
        save: @escaping @Sendable (Data) throws -> Void,
        savePrekeys: @escaping @Sendable (Data) throws -> Void,
        republishRelayURLs: [String] = [], oneTimePrekeyTarget: Int = 16
    ) {
        self.republishRelayURLs = republishRelayURLs
        self.oneTimePrekeyTarget = oneTimePrekeyTarget
        self.messenger = messenger
        self.prekeyManager = prekeyManager
        self.ownerIdentityHex = ownerIdentityHex.lowercased()
        self.load = load
        self.save = save
        self.savePrekeys = savePrekeys
    }

    /// Re-verifies each stored contact offline and restores its session; seeds dedupe.
    /// A contact whose binding no longer verifies is dropped (fail-closed). Returns the
    /// identity hexes restored.
    @discardableResult
    public func restore() async -> [String] {
        guard let data = load() else { return [] }
        guard let s = try? JSONDecoder().decode(Saved.self, from: data) else {
            // Unreadable (corrupt or from an incompatible build): keep the old blob and stop
            // saving rather than overwrite it with an empty state (fail closed, recoverable).
            readOnly = true
            lastSaveError = "saved session state unreadable; not overwriting it"
            FileHandle.standardError.write(Data("eldr-node: \(lastSaveError!)\n".utf8))
            return []
        }
        var kept: [SavedContact] = []
        var restored: [String] = []
        for c in s.contacts {
            guard let vc = try? VerifiedContact(storedBindingEvent: c.bindingEvent),
                vc.identityHex == ownerIdentityHex
            else { continue }
            await messenger.addContact(vc)
            if let snap = c.session { try? await messenger.restoreSession(with: vc, snapshot: snap) }
            kept.append(c)
            restored.append(vc.identityHex)
        }
        saved = Saved(contacts: kept, seenWrapIDs: s.seenWrapIDs)
        await messenger.seedProcessedWrapIDs(Set(s.seenWrapIDs))
        return restored
    }

    /// Records a newly verified contact (after `acceptRequest`/`fetchVerifiedPeer`).
    public func track(nostrPubkeyHex: String) async {
        guard let event = await messenger.verifiedBindingEvent(nostrPubkeyHex: nostrPubkeyHex),
            let vc = try? VerifiedContact(storedBindingEvent: event),
            vc.identityHex == ownerIdentityHex
        else { return }
        if let i = saved.contacts.firstIndex(where: { $0.bindingEvent.pubkey == nostrPubkeyHex }) {
            saved.contacts[i].bindingEvent = event
        } else {
            saved.contacts.append(SavedContact(bindingEvent: event, session: nil))
        }
        await persist()
    }

    public func recordDelivered(wrapID: String) {
        saved.seenWrapIDs.append(wrapID)
        if saved.seenWrapIDs.count > Self.maxSeen {
            saved.seenWrapIDs.removeFirst(saved.seenWrapIDs.count - Self.maxSeen)
        }
    }

    /// Background relay re-check of each stored binding: adopt only a newer, valid,
    /// SAME-identity binding; report an identity change (never adopted).
    public func refreshBindings(timeout: Duration = .seconds(8)) async -> [PQRCMessenger.BindingRefresh] {
        var results: [PQRCMessenger.BindingRefresh] = []
        for i in saved.contacts.indices {
            let r = await messenger.refreshContactBinding(stored: saved.contacts[i].bindingEvent, timeout: timeout)
            if case .updated(let e) = r { saved.contacts[i].bindingEvent = e }
            results.append(r)
        }
        await persist()
        return results
    }

    /// Saves ratchet snapshots, prekey state and seen IDs (encrypted by the injected store).
    public func persist() async {
        guard !readOnly else { return }
        // Refill BEFORE the save so the new OTPs are on disk before they are published.
        let refilled = await refillIfConsumed()
        do {
            for i in saved.contacts.indices {
                guard let vc = try? VerifiedContact(storedBindingEvent: saved.contacts[i].bindingEvent)
                else { continue }
                if let snap = await messenger.sessionSnapshot(peerIdentityHex: vc.identityHex) {
                    saved.contacts[i].session = snap
                }
            }
            var pk = await prekeyManager.snapshot()
            defer { pk.zeroize() }
            try savePrekeys(JSONEncoder().encode(pk))
            try save(JSONEncoder().encode(saved))
            lastSaveError = nil
            if refilled { republish() }
        } catch {
            // Never log the bytes; the error type is enough to diagnose.
            if lastSaveError == nil {
                FileHandle.standardError.write(Data("eldr-node: session state save failed (\(type(of: error)))\n".utf8))
            }
            lastSaveError = "\(type(of: error))"
        }
    }
}
