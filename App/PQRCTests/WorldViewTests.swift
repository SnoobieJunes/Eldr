// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCAgent
import PQRCCore
import Testing

@testable import EldrChat

/// WS-D1a — the phone's World screen, model layer.
///
/// The property under test is a NEGATIVE one, and it is the reason this view exists in a
/// weaker form than Huginn's: the phone cannot observe whether a town is connected, so it
/// must never say so. `PhoneGrantStatus` has no `connected` case at all — these tests pin
/// the derivation that feeds it, including the per-plane collapse that would otherwise
/// render one town as two.
@Suite("World screen — phone authorization view")
struct WorldViewTests {

    private func status(
        peer: String, plane: StandingGrant.Plane, activeUntil: Int64
    ) -> AgentEngine.StandingGrantStatus {
        AgentEngine.StandingGrantStatus(
            grantID: "g-\(peer.prefix(4))-\(plane.rawValue)",
            granterIdentityHex: String(repeating: "11", count: 32),
            peerIdentityHex: peer, plane: plane, activeUntil: activeUntil,
            messagesRemaining: 100, bytesRemaining: 1024, tasksInFlight: 0,
            maxConcurrentTasks: 4, toolCeiling: nil)
    }

    // MARK: - The expiry ladder

    @Test func statusLadderRunsAuthorizedThenExpiringThenExpired() {
        let now: Int64 = 1_800_000_000
        let window = PhoneWorldDerivation.expiringWindowSeconds

        #expect(
            PhoneWorldDerivation.status(activeUntil: now + window * 3, now: now)
                == .authorized(until: now + window * 3))
        #expect(
            PhoneWorldDerivation.status(activeUntil: now + window / 2, now: now)
                == .expiringSoon(until: now + window / 2))
        // Exactly at the window edge is already "expiring soon" — warn early, not late.
        #expect(
            PhoneWorldDerivation.status(activeUntil: now + window, now: now)
                == .expiringSoon(until: now + window))
        #expect(PhoneWorldDerivation.status(activeUntil: now, now: now) == .expired)
        #expect(PhoneWorldDerivation.status(activeUntil: now - 1, now: now) == .expired)
    }

    // MARK: - One row per PEER, not per plane

    /// The engine reports a status per PLANE. A peer granted both wall and delegate must
    /// still be ONE town in the list — two rows would read as two towns — and the horizon
    /// shown is the LATEST expiry, matching the node's `grantExpiry` so the phone and the
    /// Mac never disagree about when authorization ends.
    @Test func perPlaneGrantsCollapseToOneRowWithTheLatestHorizon() {
        let now: Int64 = 1_800_000_000
        let peer = String(repeating: "ab", count: 32)
        let rows = PhoneWorldDerivation.townRows(
            [
                status(peer: peer, plane: .wall, activeUntil: now + 3 * 86_400),
                status(peer: peer, plane: .delegate, activeUntil: now + 9 * 86_400),
            ], now: now)

        #expect(rows.count == 1, "one peer is one town, however many planes it was granted")
        #expect(rows[0].subtitle.contains("wall"))
        #expect(rows[0].subtitle.contains("delegate"))
        #expect(
            rows[0].status == .authorized(until: now + 9 * 86_400),
            "the horizon is the LATEST expiry — the same rule the node's grantExpiry uses")
    }

    /// Two different peers stay two rows, and each carries its own status — so a lapsed
    /// grant on one town cannot visually contaminate another.
    @Test func distinctPeersStayDistinctRowsWithIndependentStatus() {
        let now: Int64 = 1_800_000_000
        let live = String(repeating: "ab", count: 32)
        let dead = String(repeating: "cd", count: 32)
        let rows = PhoneWorldDerivation.townRows(
            [
                status(peer: live, plane: .wall, activeUntil: now + 30 * 86_400),
                status(peer: dead, plane: .wall, activeUntil: now - 60),
            ], now: now)

        #expect(rows.count == 2)
        let liveRow = try? #require(rows.first { $0.id.contains(live) })
        let deadRow = try? #require(rows.first { $0.id.contains(dead) })
        #expect(liveRow?.status == .authorized(until: now + 30 * 86_400))
        #expect(deadRow?.status == .expired)
    }

    /// The row title is a SHORT prefix — a 64-char hex is not a readable identifier, and
    /// the full value is never something the human needs to read off a phone screen.
    @Test func rowTitleIsAShortPeerPrefixNotTheFullHex() {
        let now: Int64 = 1_800_000_000
        let peer = String(repeating: "ab", count: 32)
        let row = PhoneWorldDerivation.townRows(
            [status(peer: peer, plane: .wall, activeUntil: now + 86_400 * 5)], now: now
        ).first
        #expect(row?.title == String(peer.prefix(12)) + "…")
        #expect(!(row?.title.contains(peer) ?? true), "the full hex must not be the title")
    }

    /// No grants ⇒ no rows. An empty World is a legitimate state, not an error one.
    @Test func noGrantsYieldsNoRows() {
        #expect(PhoneWorldDerivation.townRows([], now: 1_800_000_000).isEmpty)
    }

    // MARK: - The route is not a conversation id

    /// `world:` must never parse as a Buzz route or be mistaken for a conversation id —
    /// the same separation `buzz:` already has, for the same reason.
    @Test func worldRouteIsDistinctFromConversationAndBuzzRoutes() {
        #expect(WorldRoute.isWorld(WorldRoute.id))
        #expect(!WorldRoute.isWorld("some-conversation-id"))
        #expect(BuzzRoute.parse(WorldRoute.id) == nil, "the World route is not a Buzz route")
    }
}
