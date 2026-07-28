// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCAgent
import PQRCCore
import PQRCNostr
import Testing

@testable import EldrChat

/// WS-G4 → the Phase-2 UI gate (invariant 9): the phone-side standing-grant surface.
/// Model-layer proofs for what the SwiftUI leans on — mint/status/revoke through the
/// runtime, the banner matcher that keeps the grant VISIBLE for its lifetime, and the
/// export JSON being exactly what the node's `town-grants.json` consumes (decodes,
/// verifies, names the peer). Headless: seeded randomness, in-memory store, no clock.
@Suite("Standing town grants — phone UI model layer", .serialized)
struct TownGrantUITests {
    private func makeRuntime(_ name: String, seed: UInt64) async -> PersonaRuntime {
        await PersonaRuntime(
            displayName: name, transports: [LocalRelaySimulator().connect()],
            blobStore: LocalBlossomSimulator(),
            ais: [TetheredAI(id: "\(name)-ai", name: "\(name)-ai", provider: DemoAgentProvider())],
            randomSource: SeededRandomSource(seed: seed),
            nonceSource: SeededRandomSource(seed: seed &+ 1),
            keychainService: "chat.pqrc.test-towngrant-\(name)-\(UUID().uuidString)")
    }

    @Test func mint_visible_export_revoke_lifecycle() async throws {
        let runtime = await makeRuntime("Granter", seed: 4_100)
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let myHex = await runtime.identityHex
        let peer = String(repeating: "ab", count: 32)

        // Mint: wall + delegate, 7 days.
        let (statuses, exportJSON) = try await runtime.startTownGrant(
            peerIdentityHex: peer, planes: [.wall, .delegate],
            budget: AppModel.defaultTownGrantBudget, durationSeconds: 7 * 86_400)
        #expect(statuses.contains { $0.peerIdentityHex == peer && $0.plane == .wall })
        #expect(statuses.contains { $0.peerIdentityHex == peer && $0.plane == .delegate })

        // The invariant-9 surface: the banner matcher shows this grant for the peer's
        // 1:1 conversation (whose id IS the peer hex) while live — and not after expiry.
        let now = Int64(Date().timeIntervalSince1970)
        let banner = AppModel.townGrantBanner(grants: statuses, conversationID: peer, now: now)
        #expect(banner != nil, "a live grant MUST surface a banner (invariant 9)")
        #expect(banner?.planes == "delegate + wall")
        #expect(
            AppModel.townGrantBanner(
                grants: statuses, conversationID: peer, now: now + 8 * 86_400) == nil,
            "an expired grant surfaces nothing")
        #expect(
            AppModel.townGrantBanner(
                grants: statuses, conversationID: String(repeating: "cd", count: 32), now: now)
                == nil,
            "another peer's conversation shows no banner")

        // The export is EXACTLY a `town-grants.json` element: it decodes as a
        // StandingGrant, its signature verifies, and it names the peer + planes.
        let decoded = try JSONDecoder().decode(
            StandingGrant.self, from: Data(exportJSON.utf8))
        #expect(decoded.peer == peer)
        #expect(decoded.hasValidSignature(), "the export must carry the HUMAN signature")
        #expect(decoded.enabledBy.hexString == myHex, "signed by the minting owner")
        #expect(decoded.covers(.wall) && decoded.covers(.delegate))

        // Revoke: the engine-side authorization dies immediately.
        guard let grantID = statuses.first(where: { $0.peerIdentityHex == peer })?.grantID
        else {
            Issue.record("no grantID")
            return
        }
        let after = try await runtime.revokeTownGrant(grantID: grantID)
        #expect(!after.contains { $0.grantID == grantID }, "revocation removes the grant")
        #expect(
            AppModel.townGrantBanner(grants: after, conversationID: peer, now: now) == nil,
            "the banner falls with the grant")
    }
}
