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

    public init(messenger: PQRCMessenger, clock: any Clock = SystemClock()) {
        self.messenger = messenger
        self.clock = clock
    }

    public func start() async throws -> AsyncStream<MessengerEvent> {
        try await messenger.start()
    }

    public func sendFramed(_ framed: String, to peerIdentityHex: String) async throws {
        try await messenger.send(
            MessageBody(text: framed, sentAt: clock.now()),
            to: peerIdentityHex,
            participantType: .human)
    }
}
