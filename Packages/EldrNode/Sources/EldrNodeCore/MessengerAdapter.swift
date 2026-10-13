// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr

// Conforms the production `PQRCMessenger` to `EldrNodeCore`'s `NodeMessenger` seam, so
// the executable can hand its live messenger straight to `serve(...)` while the tests
// hand a `LocalRelaySimulator`-backed double (or a `PQRCMessenger` wrapped the same
// way). The adapter is a thin shell — it adds nothing but the two protocol methods.

/// Adapts a `PQRCMessenger` to `NodeMessenger`. `sendFramed` publishes the frame as an
/// ordinary ratcheted message; `participantType` is `.human` because an ACP frame is the
/// node↔owner CONTROL CHANNEL (transport), not an agent-authored CHAT message — invariant
/// 8 governs chat authorship, and the proven e2e (`RelayCarriedACPE2ETests`) carries the
/// node's outbound frames exactly this way (a plaintext fed through the existing ratchet,
/// addressed pairwise to the owner). `sentAt` is the wall clock only to make each frame a
/// distinct ratchet message number; it never enters key derivation (invariant 5).
public struct PQRCNodeMessenger: NodeMessenger {
    public let messenger: PQRCMessenger
    private let clock: any Clock
    /// When set, conversation state is saved after every send / receive / accept so a
    /// restart keeps the owner's session (nil keeps the old in-memory-only behaviour).
    public let sessionStore: NodeSessionStore?

    public init(
        messenger: PQRCMessenger, clock: any Clock = SystemClock(),
        sessionStore: NodeSessionStore? = nil
    ) {
        self.messenger = messenger
        self.clock = clock
        self.sessionStore = sessionStore
    }

    public func start() async throws -> AsyncStream<MessengerEvent> {
        let raw = try await messenger.start()
        guard let store = sessionStore else { return raw }
        // Save AFTER the messenger decrypted (ratchet advanced) and BEFORE serve acts on it.
        let (out, cont) = AsyncStream.makeStream(of: MessengerEvent.self)
        Task {
            for await event in raw {
                if case .message(let m) = event {
                    await store.recordDelivered(wrapID: m.wrapEventID)
                    await store.persist()
                }
                cont.yield(event)
            }
            cont.finish()
        }
        return out
    }

    public func sendFramed(_ framed: String, to peerIdentityHex: String) async throws {
        try await messenger.send(
            MessageBody(text: framed, sentAt: clock.now()),
            to: peerIdentityHex,
            participantType: .human)
        await sessionStore?.persist()
    }

    /// Accept a pending message-request and return the resolved IDENTITY hex.
    /// `PQRCMessenger.acceptRequest` fetches + fully verifies the sender's 10420/10421
    /// binding (both directions — invariant 7), adds the verified contact, and replays the
    /// held opening handshake so a responder session is built; the returned
    /// `VerifiedContact.identityHex` is the identity `serve` compares to the pinned owner.
    public func acceptRequest(senderNostrPubkeyHex: String) async throws -> String {
        let contact = try await messenger.acceptRequest(senderNostrPubkeyHex: senderNostrPubkeyHex)
        await sessionStore?.track(nostrPubkeyHex: contact.nostrPubkeyHex)
        return contact.identityHex
    }

    /// Decline a pending message-request: `PQRCMessenger.declineRequest` drops the
    /// sender's held envelopes without establishing a session (and does not block them).
    public func acceptReconnect(peerIdentityHex: String) async -> Bool {
        let ok = await messenger.acceptReconnect(peerIdentityHex: peerIdentityHex)
        if ok { await sessionStore?.persist() }
        return ok
    }

    public func declineRequest(senderNostrPubkeyHex: String) async {
        await messenger.declineRequest(senderNostrPubkeyHex: senderNostrPubkeyHex)
    }
}
