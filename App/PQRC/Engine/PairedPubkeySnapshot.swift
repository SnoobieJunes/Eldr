// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import os

/// Thread-safe, synchronously-readable snapshot of the PAIRED peers' NOSTR
/// pubkeys (hex) — the `NearbyRelayHost`'s AUTH allowlist (C-5). The host's
/// `authorize` closure is `@Sendable (String) -> Bool` and must not await the
/// (actor) runtime, so the runtime republishes its verified-contact pubkeys here
/// whenever they change, and the host reads this snapshot synchronously.
///
/// Keyed by the secp256k1 NOSTR pubkey (what a kind-22242 AUTH event is signed
/// by) — NOT the PQRC identity key — because that is what the host compares
/// `authEvent.pubkey` against. Starts EMPTY so the host fails CLOSED until the
/// runtime has loaded and published its verified contacts.
final class PairedPubkeySnapshot: Sendable {
    private let store = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    func contains(_ nostrPubkeyHex: String) -> Bool { store.withLock { $0.contains(nostrPubkeyHex) } }
    func replace(with set: Set<String>) { store.withLock { $0 = set } }
}
