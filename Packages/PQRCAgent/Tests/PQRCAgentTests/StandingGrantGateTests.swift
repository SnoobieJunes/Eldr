// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCAgent
@testable import PQRCCore

/// The town gate (GOOSEWORLD §5, DEVIATIONS AC126). These prove the standing
/// grant is a THIRD axis that fails closed on its own terms and — the load-bearing
/// one — that holding one authorizes nothing under SPEC §13's gate.
@Suite("Standing town grants", .tags(.agent))
struct StandingGrantGateTests {
    static let day = PQRCConstants.secondsPerDay

    static func fixture() throws -> (
        engine: AgentEngine, clock: FixedClock, alice: PQRCIdentity, bob: PQRCIdentity
    ) {
        // A clock deliberately NOT on a day boundary, so rollover tests exercise a
        // real mid-day → next-day transition.
        let clock = FixedClock(now: 1_756_000_000)
        let alice = try PQRCIdentity(seed: hexData(String(repeating: "a7", count: 32)))
        let bob = try PQRCIdentity(seed: hexData(String(repeating: "b7", count: 32)))
        let engine = AgentEngine(myIdentity: alice, clock: clock, sink: SpySink())
        return (engine, clock, alice, bob)
    }

    static func budget(
        messages: Int = 3, bytes: Int = 1000, tasks: Int = 2, tools: [String]? = nil
    ) -> StandingGrant.Budget {
        StandingGrant.Budget(
            messagesPerDay: messages, bytesPerDay: bytes, maxConcurrentTasks: tasks,
            toolCeiling: tools)
    }

    /// Alice grants HER agent autonomy toward Bob's town.
    @discardableResult
    static func grantToBob(
        _ fx: (engine: AgentEngine, clock: FixedClock, alice: PQRCIdentity, bob: PQRCIdentity),
        grantID: String = "g1", planes: [StandingGrant.Plane] = [.wall],
        budget: StandingGrant.Budget = budget(), days: Int64 = 7
    ) async throws -> StandingGrant {
        try await fx.engine.startMyStandingGrant(
            grantID: grantID, peerIdentityHex: fx.bob.publicKeyData.hexString,
            planes: planes, budget: budget, durationSeconds: days * day)
    }

    // MARK: - Requirement 6: the §13 gate is NOT widened

    /// The whole workstream in one test. A live standing grant covering both
    /// planes must leave `authorizeAutonomousSend` exactly as closed as it was.
    @Test func standingGrantDoesNotWidenTheAutonomousSendGate() async throws {
        let fx = try Self.fixture()
        try await Self.grantToBob(fx, planes: [.wall, .delegate])
        // The town gate is open…
        try await fx.engine.authorizeTownSend(
            peerIdentityHex: fx.bob.publicKeyData.hexString, plane: .wall, bytes: 10)
        // …and §13's is untouched, for conversations AND threads.
        await #expect(throws: AgentEngineError.autonomousSendNotAuthorized) {
            try await fx.engine.authorizeAutonomousSend(threadID: nil)
        }
        await #expect(throws: AgentEngineError.autonomousSendNotAuthorized) {
            try await fx.engine.authorizeAutonomousSend(threadID: "t1")
        }
        #expect(await fx.engine.activeWindow(for: fx.alice.publicKeyData.hexString) == nil)
        #expect(
            await fx.engine.activeInvite(
                threadID: "t1", identityHex: fx.alice.publicKeyData.hexString) == nil)
    }

    /// And the converse: an ai_window does not open the town gate. Two gates,
    /// neither substitutes for the other.
    @Test func windowDoesNotOpenTheTownGate() async throws {
        let fx = try Self.fixture()
        _ = try await fx.engine.startMyWindow(durationSeconds: 3600)
        try await fx.engine.authorizeAutonomousSend(threadID: nil)
        await #expect(throws: AgentEngineError.townSendNotAuthorized) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: fx.bob.publicKeyData.hexString, plane: .wall, bytes: 1)
        }
    }

    // MARK: - Scope: peer + plane

    @Test func grantIsScopedToOnePeerAndOnePlane() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, planes: [.wall])

        try await fx.engine.authorizeTownSend(
            peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        // Wrong plane.
        await #expect(throws: AgentEngineError.townSendNotAuthorized) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .delegate, bytes: 1)
        }
        // Wrong peer.
        let carolHex = String(repeating: "c9", count: 32)
        await #expect(throws: AgentEngineError.townSendNotAuthorized) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: carolHex, plane: .wall, bytes: 1)
        }
    }

    /// The reflection attack, the other way round: a grant BOB signed — even one
    /// naming Alice as its peer — must never open ALICE's gate. Only a grant whose
    /// granter is me authorizes my agent. If this ever passed, any town could
    /// authorize any other town's agent by mailing it a grant.
    @Test func aPeersGrantDoesNotAuthorizeMyAgent() async throws {
        let fx = try Self.fixture()
        let aliceHex = fx.alice.publicKeyData.hexString
        let bobHex = fx.bob.publicKeyData.hexString

        let bobGrant = try StandingGrant.make(
            grantID: "bob-1", peer: aliceHex, planes: [.wall, .delegate],
            budget: Self.budget(), activeUntil: fx.clock.now() + 7 * Self.day,
            identity: fx.bob)
        try await fx.engine.receiveStandingGrant(bobGrant, fromSenderIdentityHex: bobHex)
        // It is visible (that is the point of the indicator)…
        #expect(
            await fx.engine.activeStandingGrant(
                peerIdentityHex: aliceHex, plane: .wall, granterIdentityHex: bobHex) != nil)
        // …and it authorizes Alice's agent to do exactly nothing, toward Bob or
        // toward herself, on either plane.
        for peer in [bobHex, aliceHex] {
            for plane in StandingGrant.Plane.allCases {
                await #expect(throws: AgentEngineError.townSendNotAuthorized) {
                    try await fx.engine.authorizeTownSend(
                        peerIdentityHex: peer, plane: plane, bytes: 1)
                }
            }
            await #expect(throws: AgentEngineError.townSendNotAuthorized) {
                try await fx.engine.beginTownTask(peerIdentityHex: peer, taskID: "t1")
            }
            #expect(
                await fx.engine.toolAuthorizedForTown(peerIdentityHex: peer, tool: "read")
                    == false)
        }
    }

    /// Revoking a grant id this device does not hold is a safe no-op that still
    /// produces a publishable revocation (so a client can broadcast a withdrawal
    /// it only learned about from another device). An unusable grant id throws
    /// before signing — and the `defer` still runs, clearing nothing.
    @Test func revokingAnUnknownGrantIsSafe() async throws {
        let fx = try Self.fixture()
        try await Self.grantToBob(fx, grantID: "g1")
        let stray = try await fx.engine.revokeMyStandingGrant(grantID: "nope")
        #expect(stray.hasValidSignature() == true)
        #expect(await fx.engine.activeStandingGrants().count == 1)  // g1 survives

        await #expect(throws: AgentEngineError.standingGrantMalformed(.malformedGrantID)) {
            _ = try await fx.engine.revokeMyStandingGrant(grantID: "")
        }
        #expect(await fx.engine.activeStandingGrants().count == 1)
    }

    // MARK: - Requirement 3: bounded in days

    @Test func onlyAllowedDurationsMayBeIssued() async throws {
        let fx = try Self.fixture()
        // An hour is a window, not a standing grant.
        await #expect(throws: AgentEngineError.standingGrantDurationUnbounded) {
            _ = try await Self.grantToBob(fx, days: 0)
        }
        for days: Int64 in [1, 3, 7, 14, 30] {
            _ = try await Self.grantToBob(fx, grantID: "g\(days)", days: days)
        }
        await #expect(throws: AgentEngineError.standingGrantDurationUnbounded) {
            _ = try await fx.engine.startMyStandingGrant(
                grantID: "g", peerIdentityHex: fx.bob.publicKeyData.hexString,
                planes: [.wall], budget: Self.budget(),
                durationSeconds: PQRCConstants.maxStandingGrantDuration + 1)
        }
    }

    /// Received grants: exactly at the cap is fine; ONE SECOND over is refused.
    @Test func receivedGrantDurationCapIsExact() async throws {
        let fx = try Self.fixture()
        let aliceHex = fx.alice.publicKeyData.hexString
        let bobHex = fx.bob.publicKeyData.hexString

        let atCap = try StandingGrant.make(
            grantID: "g-cap", peer: aliceHex, planes: [.wall], budget: Self.budget(),
            activeUntil: fx.clock.now() + PQRCConstants.maxStandingGrantDuration,
            identity: fx.bob)
        try await fx.engine.receiveStandingGrant(atCap, fromSenderIdentityHex: bobHex)
        #expect(
            await fx.engine.activeStandingGrant(
                peerIdentityHex: aliceHex, plane: .wall, granterIdentityHex: bobHex) != nil)

        let oneOver = try StandingGrant.make(
            grantID: "g-over", peer: aliceHex, planes: [.wall], budget: Self.budget(),
            activeUntil: fx.clock.now() + PQRCConstants.maxStandingGrantDuration + 1,
            identity: fx.bob)
        await #expect(throws: AgentEngineError.standingGrantDurationUnbounded) {
            try await fx.engine.receiveStandingGrant(oneOver, fromSenderIdentityHex: bobHex)
        }
    }

    @Test func expiredGrantFailsClosed() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        let grant = try await Self.grantToBob(fx, days: 1)
        try await fx.engine.authorizeTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 1)

        // No timer — expiry is evaluated on access from the injected clock.
        fx.clock.set(grant.activeUntil)  // boundary: `now < activeUntil` is false
        await #expect(throws: AgentEngineError.townSendNotAuthorized) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }
        #expect(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .wall) == nil)
        #expect(await fx.engine.activeStandingGrants().isEmpty)
    }

    // MARK: - Requirement 5 + 9: only the human identity key, and it must be the sender's

    @Test func onlyHumanIdentitySignatureAccepted() async throws {
        let fx = try Self.fixture()
        let aliceHex = fx.alice.publicKeyData.hexString
        let bobHex = fx.bob.publicKeyData.hexString
        let until = fx.clock.now() + 7 * Self.day

        // Agent-derived key over the right bytes: an agent cannot self-grant.
        let bobAgent = try AgentKeyDeriver.deriveAgentKey(from: fx.bob)
        let template = StandingGrant(
            grantID: "g1", peer: aliceHex, planes: ["wall"], budget: Self.budget(),
            activeUntil: until, enabledBy: fx.bob.publicKeyData, sig: Data())
        let agentForged = StandingGrant(
            grantID: template.grantID, peer: template.peer, planes: template.planes,
            budget: template.budget, activeUntil: until, enabledBy: fx.bob.publicKeyData,
            sig: try bobAgent.signature(
                for: StandingGrant.signatureMessage(
                    scopeTag: template.scopeTag, activeUntil: until,
                    enabledBy: fx.bob.publicKeyData)))
        await #expect(throws: AgentEngineError.standingGrantSignatureInvalid) {
            try await fx.engine.receiveStandingGrant(
                agentForged, fromSenderIdentityHex: bobHex)
        }

        // `enabled_by` disagrees with the claimed sender: rejected before crypto.
        let misattributed = try StandingGrant.make(
            grantID: "g2", peer: aliceHex, planes: [.wall], budget: Self.budget(),
            activeUntil: until, identity: fx.alice)
        await #expect(throws: AgentEngineError.standingGrantNotFromHumanIdentity) {
            try await fx.engine.receiveStandingGrant(
                misattributed, fromSenderIdentityHex: bobHex)
        }

        // Garbage signature.
        let genuine = try StandingGrant.make(
            grantID: "g3", peer: aliceHex, planes: [.wall], budget: Self.budget(),
            activeUntil: until, identity: fx.bob)
        let tampered = StandingGrant(
            grantID: genuine.grantID, peer: genuine.peer, planes: genuine.planes,
            budget: genuine.budget, activeUntil: genuine.activeUntil,
            enabledBy: genuine.enabledBy, sig: Data(repeating: 0x00, count: 64))
        await #expect(throws: AgentEngineError.standingGrantSignatureInvalid) {
            try await fx.engine.receiveStandingGrant(tampered, fromSenderIdentityHex: bobHex)
        }

        // A window signature replayed into a standing grant.
        let windowSig = try fx.bob.sign(
            AIWindowAnnouncement.signatureMessage(
                activeUntil: until, enabledBy: fx.bob.publicKeyData, threadID: nil))
        let replayed = StandingGrant(
            grantID: genuine.grantID, peer: genuine.peer, planes: genuine.planes,
            budget: genuine.budget, activeUntil: until, enabledBy: fx.bob.publicKeyData,
            sig: windowSig)
        await #expect(throws: AgentEngineError.standingGrantSignatureInvalid) {
            try await fx.engine.receiveStandingGrant(replayed, fromSenderIdentityHex: bobHex)
        }

        // Nothing above left any state behind.
        #expect(await fx.engine.activeStandingGrants().isEmpty)
    }

    /// A structurally broken grant is refused with a precise reason — and before
    /// the signature check, so a malformed peer can never become a dictionary key.
    @Test func malformedGrantIsRefused() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        let badPeer = StandingGrant(
            grantID: "g1", peer: "NOT-HEX", planes: ["wall"], budget: Self.budget(),
            activeUntil: fx.clock.now() + Self.day, enabledBy: fx.bob.publicKeyData,
            sig: Data(repeating: 0x01, count: 64))
        await #expect(throws: AgentEngineError.standingGrantMalformed(.malformedPeer)) {
            try await fx.engine.receiveStandingGrant(badPeer, fromSenderIdentityHex: bobHex)
        }
        await #expect(throws: AgentEngineError.standingGrantMalformed(.malformedBudget)) {
            _ = try await fx.engine.startMyStandingGrant(
                grantID: "g", peerIdentityHex: bobHex, planes: [.wall],
                budget: Self.budget(messages: -1), durationSeconds: Self.day)
        }
        #expect(await fx.engine.activeStandingGrants().isEmpty)
    }

    // MARK: - Requirement 7: message-driven budgets

    @Test func messageBudgetIsExactAtTheLimit() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, budget: Self.budget(messages: 3, bytes: 10_000))

        for _ in 0..<3 {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
            await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }
        // The third send was allowed; the fourth is not.
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }
        let status = try #require(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .wall))
        #expect(status.messagesRemaining == 0)
    }

    @Test func byteBudgetIsExactAtTheLimit() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, budget: Self.budget(messages: 100, bytes: 1000))

        // Exactly at the limit is allowed…
        try await fx.engine.authorizeTownSend(
            peerIdentityHex: bobHex, plane: .wall, bytes: 1000)
        // …one over is not.
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1001)
        }

        await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 999)
        try await fx.engine.authorizeTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 2)
        }
        let status = try #require(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .wall))
        #expect(status.bytesRemaining == 1)
        #expect(status.messagesRemaining == 99)
    }

    /// A zero budget is a grant that authorizes nothing — the fail-closed reading
    /// of "0", and the reason "unlimited" is not expressible.
    @Test func zeroBudgetAuthorizesNothing() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, budget: Self.budget(messages: 0, bytes: 0, tasks: 0))
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 0)
        }
    }

    /// Budgets roll over by comparing UTC day indices at call time. No timer is
    /// involved; advancing the injected clock is the entire mechanism.
    @Test func budgetRollsOverOnTheUTCDayBoundary() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, budget: Self.budget(messages: 2, bytes: 100), days: 7)

        for _ in 0..<2 {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 10)
            await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 10)
        }
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }

        // Still the same UTC day an hour later: still exhausted.
        fx.clock.advance(by: 3600)
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }

        // Cross into the next UTC day: the allowance is fresh, and the status the
        // UI renders agrees.
        let now = fx.clock.now()
        let nextDayStart = (now / Self.day + 1) * Self.day
        fx.clock.set(nextDayStart)
        try await fx.engine.authorizeTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        let status = try #require(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .wall))
        #expect(status.messagesRemaining == 2)
        #expect(status.bytesRemaining == 100)

        // One second BEFORE the boundary it was still yesterday.
        fx.clock.set(nextDayStart - 1)
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }
    }

    @Test func negativeByteCountIsRefused() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx)
        await #expect(throws: AgentEngineError.standingGrantMalformed(.malformedBudget)) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: -1)
        }
    }

    /// Regression: `used + bytes <= cap` traps on overflow for a large enough
    /// `bytes`, turning a bad argument into a crashed actor. Both the gate and the
    /// accounting call must survive `Int.max` — and must not silently let it
    /// through either.
    @Test func absurdByteCountsSaturateRatherThanTrap() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, budget: Self.budget(messages: 100, bytes: 1000))
        await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 50)

        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: .max)
        }
        // Recording an absurd amount saturates at the cap; it does not wrap
        // around into a fresh allowance.
        await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: .max)
        let status = try #require(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .wall))
        #expect(status.bytesRemaining == 0)
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }
    }

    /// A clock moved BACKWARDS must not hand the budget back. Rollover is
    /// monotone: the only direction it can be wrong in is stingy.
    @Test func clockMovingBackwardsDoesNotRefillTheBudget() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, budget: Self.budget(messages: 1, bytes: 100), days: 30)
        await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 100)
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }

        // Back three days: still spent.
        fx.clock.advance(by: -3 * Self.day)
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }
        #expect(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .wall)?
                .messagesRemaining == 0)
    }

    /// Re-delivering the SAME grant must not refill the budget — otherwise a
    /// replay of a legitimately-signed grant IS the budget bypass.
    @Test func replayingAGrantDoesNotResetTheBudget() async throws {
        let fx = try Self.fixture()
        let aliceHex = fx.alice.publicKeyData.hexString
        let bobHex = fx.bob.publicKeyData.hexString
        let grant = try await Self.grantToBob(
            fx, grantID: "g1", budget: Self.budget(messages: 1, bytes: 100))
        await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 50)
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }

        // Alice's own signed grant, replayed back at her by a relay/peer.
        try await fx.engine.receiveStandingGrant(grant, fromSenderIdentityHex: aliceHex)
        await #expect(throws: AgentEngineError.townBudgetExhausted) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }
        let status = try #require(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .wall))
        #expect(status.bytesRemaining == 50)
    }

    // MARK: - Task concurrency + tool ceiling

    @Test func concurrentTaskCeilingIsEnforced() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, planes: [.delegate], budget: Self.budget(tasks: 2))

        try await fx.engine.beginTownTask(peerIdentityHex: bobHex, taskID: "t1")
        try await fx.engine.beginTownTask(peerIdentityHex: bobHex, taskID: "t2")
        // Re-begin of an in-flight id is idempotent, not a third slot.
        try await fx.engine.beginTownTask(peerIdentityHex: bobHex, taskID: "t2")
        await #expect(throws: AgentEngineError.townTaskLimitReached) {
            try await fx.engine.beginTownTask(peerIdentityHex: bobHex, taskID: "t3")
        }
        #expect(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .delegate)?
                .tasksInFlight == 2)

        await fx.engine.endTownTask(peerIdentityHex: bobHex, taskID: "t1")
        try await fx.engine.beginTownTask(peerIdentityHex: bobHex, taskID: "t3")
        // Ending an unknown id is a no-op, not a double-decrement.
        await fx.engine.endTownTask(peerIdentityHex: bobHex, taskID: "never-started")
        #expect(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .delegate)?
                .tasksInFlight == 2)
    }

    @Test func tasksRequireADelegateGrant() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        // Only the wall plane is granted.
        try await Self.grantToBob(fx, planes: [.wall])
        await #expect(throws: AgentEngineError.townSendNotAuthorized) {
            try await fx.engine.beginTownTask(peerIdentityHex: bobHex, taskID: "t1")
        }
        #expect(
            await fx.engine.toolAuthorizedForTown(peerIdentityHex: bobHex, tool: "read") == false)
    }

    @Test func toolCeilingNarrowsButNeverWidens() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString

        // No grant at all ⇒ nothing is authorized.
        #expect(
            await fx.engine.toolAuthorizedForTown(peerIdentityHex: bobHex, tool: "read") == false)

        try await Self.grantToBob(
            fx, planes: [.delegate], budget: Self.budget(tools: ["read_file"]))
        #expect(
            await fx.engine.toolAuthorizedForTown(peerIdentityHex: bobHex, tool: "read_file")
                == true)
        #expect(
            await fx.engine.toolAuthorizedForTown(peerIdentityHex: bobHex, tool: "shell")
                == false)

        // A grant with no ceiling adds no narrowing (the ACP permission gate and
        // path jail still run — this is not a widening).
        try await Self.grantToBob(
            fx, grantID: "g2", planes: [.delegate], budget: Self.budget(tools: nil))
        #expect(
            await fx.engine.toolAuthorizedForTown(peerIdentityHex: bobHex, tool: "shell")
                == true)
    }

    // MARK: - Requirement 4: revocation

    @Test func revocationIsEffectiveImmediately() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, grantID: "g1", planes: [.wall, .delegate])
        try await fx.engine.authorizeTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 1)

        let revocation = try await fx.engine.revokeMyStandingGrant(grantID: "g1")
        #expect(revocation.hasValidSignature() == true)
        #expect(revocation.grantID == "g1")
        // BOTH planes of that grant are gone, locally, at once.
        await #expect(throws: AgentEngineError.townSendNotAuthorized) {
            try await fx.engine.authorizeTownSend(
                peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        }
        await #expect(throws: AgentEngineError.townSendNotAuthorized) {
            try await fx.engine.beginTownTask(peerIdentityHex: bobHex, taskID: "t1")
        }
        #expect(await fx.engine.activeStandingGrants().isEmpty)
    }

    @Test func peerRevocationClearsThePeerGrantOnly() async throws {
        let fx = try Self.fixture()
        let aliceHex = fx.alice.publicKeyData.hexString
        let bobHex = fx.bob.publicKeyData.hexString

        // Bob grants his town autonomy toward Alice; Alice grants hers toward Bob.
        let bobGrant = try StandingGrant.make(
            grantID: "bob-1", peer: aliceHex, planes: [.wall], budget: Self.budget(),
            activeUntil: fx.clock.now() + 7 * Self.day, identity: fx.bob)
        try await fx.engine.receiveStandingGrant(bobGrant, fromSenderIdentityHex: bobHex)
        try await Self.grantToBob(fx, grantID: "alice-1")
        #expect(await fx.engine.activeStandingGrants().count == 2)

        let bobRevokes = try StandingGrantRevocation.make(
            grantID: "bob-1", revokedAt: fx.clock.now(), identity: fx.bob)
        try await fx.engine.receiveStandingGrantRevocation(
            bobRevokes, fromSenderIdentityHex: bobHex)

        #expect(
            await fx.engine.activeStandingGrant(
                peerIdentityHex: aliceHex, plane: .wall, granterIdentityHex: bobHex) == nil)
        // Alice's own grant is untouched, and her gate still opens.
        try await fx.engine.authorizeTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        #expect(await fx.engine.activeStandingGrants().count == 1)
    }

    /// A third party cannot revoke someone else's grant, and cannot learn whether
    /// it exists: unknown targets are silent no-ops.
    @Test func thirdPartyAndUnknownRevocationsAreSafeNoOps() async throws {
        let fx = try Self.fixture()
        let aliceHex = fx.alice.publicKeyData.hexString
        let bobHex = fx.bob.publicKeyData.hexString
        let carol = try PQRCIdentity(seed: hexData(String(repeating: "c9", count: 32)))
        let carolHex = carol.publicKeyData.hexString

        let bobGrant = try StandingGrant.make(
            grantID: "bob-1", peer: aliceHex, planes: [.wall], budget: Self.budget(),
            activeUntil: fx.clock.now() + 7 * Self.day, identity: fx.bob)
        try await fx.engine.receiveStandingGrant(bobGrant, fromSenderIdentityHex: bobHex)
        try await Self.grantToBob(fx, grantID: "alice-1")

        // Carol signs a perfectly valid revocation naming Bob's grant id.
        let carolRevokesBob = try StandingGrantRevocation.make(
            grantID: "bob-1", revokedAt: fx.clock.now(), identity: carol)
        try await fx.engine.receiveStandingGrantRevocation(
            carolRevokesBob, fromSenderIdentityHex: carolHex)
        // …and revokes nothing.
        #expect(await fx.engine.activeStandingGrants().count == 2)

        // Same for a grant id nobody has ever issued — no throw, no state change.
        let ghost = try StandingGrantRevocation.make(
            grantID: "never-existed", revokedAt: fx.clock.now(), identity: fx.bob)
        try await fx.engine.receiveStandingGrantRevocation(ghost, fromSenderIdentityHex: bobHex)
        #expect(await fx.engine.activeStandingGrants().count == 2)

        // A replayed revocation stays idempotent.
        let bobRevokes = try StandingGrantRevocation.make(
            grantID: "bob-1", revokedAt: fx.clock.now(), identity: fx.bob)
        try await fx.engine.receiveStandingGrantRevocation(
            bobRevokes, fromSenderIdentityHex: bobHex)
        try await fx.engine.receiveStandingGrantRevocation(
            bobRevokes, fromSenderIdentityHex: bobHex)
        #expect(await fx.engine.activeStandingGrants().count == 1)
    }

    @Test func forgedRevocationIsRejected() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, grantID: "g1")

        // Signature by Bob's AGENT key: agents cannot revoke either.
        let bobAgent = try AgentKeyDeriver.deriveAgentKey(from: fx.bob)
        let agentForged = StandingGrantRevocation(
            grantID: "g1", revokedAt: fx.clock.now(), enabledBy: fx.bob.publicKeyData,
            sig: try bobAgent.signature(
                for: StandingGrantRevocation.signatureMessage(
                    grantID: "g1", revokedAt: fx.clock.now(),
                    enabledBy: fx.bob.publicKeyData)))
        await #expect(throws: AgentEngineError.standingGrantSignatureInvalid) {
            try await fx.engine.receiveStandingGrantRevocation(
                agentForged, fromSenderIdentityHex: bobHex)
        }

        // `enabled_by` disagreeing with the sender.
        let misattributed = try StandingGrantRevocation.make(
            grantID: "g1", revokedAt: fx.clock.now(), identity: fx.alice)
        await #expect(throws: AgentEngineError.standingGrantNotFromHumanIdentity) {
            try await fx.engine.receiveStandingGrantRevocation(
                misattributed, fromSenderIdentityHex: bobHex)
        }
    }

    /// Issuing a NEW grant id after revoking is how a human deliberately restarts;
    /// budgets start fresh, which is correct because it took a signature to do it.
    @Test func newGrantIDAfterRevocationStartsFresh() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        try await Self.grantToBob(fx, grantID: "g1", budget: Self.budget(messages: 1))
        await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 1)
        _ = try await fx.engine.revokeMyStandingGrant(grantID: "g1")

        try await Self.grantToBob(fx, grantID: "g2", budget: Self.budget(messages: 1))
        try await fx.engine.authorizeTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 1)
    }

    // MARK: - Requirement 5: visibility

    @Test func statusExposesExpiryAndRemainingBudget() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        let grant = try await Self.grantToBob(
            fx, grantID: "g1", planes: [.wall, .delegate],
            budget: Self.budget(messages: 10, bytes: 500, tasks: 3, tools: ["read_file"]),
            days: 7)

        await fx.engine.recordTownSend(peerIdentityHex: bobHex, plane: .wall, bytes: 120)
        let wall = try #require(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .wall))
        #expect(wall.grantID == "g1")
        #expect(wall.granterIdentityHex == fx.alice.publicKeyData.hexString)
        #expect(wall.peerIdentityHex == bobHex)
        #expect(wall.plane == .wall)
        #expect(wall.activeUntil == grant.activeUntil)
        #expect(wall.activeUntil == fx.clock.now() + 7 * Self.day)
        #expect(wall.messagesRemaining == 9)
        #expect(wall.bytesRemaining == 380)
        #expect(wall.maxConcurrentTasks == 3)
        #expect(wall.toolCeiling == ["read_file"])

        // The delegate plane is a separate record with its own counters.
        let delegate = try #require(
            await fx.engine.activeStandingGrant(peerIdentityHex: bobHex, plane: .delegate))
        #expect(delegate.messagesRemaining == 10)
        #expect(delegate.bytesRemaining == 500)

        // The panel listing is stable and covers both planes.
        let all = await fx.engine.activeStandingGrants()
        #expect(all.count == 2)
        #expect(all.map(\.plane) == [.delegate, .wall])  // sorted by (peer, plane)
        #expect(await fx.engine.activeStandingGrants() == all)
    }

    /// An unknown plane on the wire stays bound in the signature (so the grant
    /// verifies) but materializes no gate — forward-compatible and fail-closed.
    @Test func unknownPlaneAuthorizesNothing() async throws {
        let fx = try Self.fixture()
        let aliceHex = fx.alice.publicKeyData.hexString
        let bobHex = fx.bob.publicKeyData.hexString
        let until = fx.clock.now() + 7 * Self.day
        let template = StandingGrant(
            grantID: "g1", peer: aliceHex, planes: ["teleport"], budget: Self.budget(),
            activeUntil: until, enabledBy: fx.bob.publicKeyData, sig: Data())
        let signed = StandingGrant(
            grantID: "g1", peer: aliceHex, planes: ["teleport"], budget: Self.budget(),
            activeUntil: until, enabledBy: fx.bob.publicKeyData,
            sig: try fx.bob.sign(
                StandingGrant.signatureMessage(
                    scopeTag: template.scopeTag, activeUntil: until,
                    enabledBy: fx.bob.publicKeyData)))
        // Accepted (it verifies), but it opens nothing.
        try await fx.engine.receiveStandingGrant(signed, fromSenderIdentityHex: bobHex)
        #expect(await fx.engine.activeStandingGrants().isEmpty)
        #expect(
            await fx.engine.activeStandingGrant(
                peerIdentityHex: aliceHex, plane: .wall, granterIdentityHex: bobHex) == nil)
    }

    /// Sanity: the UTC day index is a floor, not a truncation.
    @Test func utcDayIndexFloors() {
        #expect(AgentEngine.utcDayIndex(0) == 0)
        #expect(AgentEngine.utcDayIndex(Self.day - 1) == 0)
        #expect(AgentEngine.utcDayIndex(Self.day) == 1)
        #expect(AgentEngine.utcDayIndex(-1) == -1)
        #expect(AgentEngine.utcDayIndex(-Self.day) == -1)
        #expect(AgentEngine.utcDayIndex(-Self.day - 1) == -2)
    }

    // MARK: - AC135: the grant STORE is bounded (a verified-peer memory DoS)

    // `receiveStandingGrant` admits a grant from any VERIFIED contact, but
    // "verified" is invite-based — it is not "trusted with this node's memory".
    // A paired-but-hostile peer can sign an unbounded number of grants naming
    // distinct `peer` hexes, each a fresh dictionary key, so without a cap the
    // store is a memory-exhaustion primitive driven from someone else's machine.
    // These pin the bound AC135 added. They were missing when AC135 was written —
    // the fix shipped with the claim of coverage but none of the tests.

    /// A distinct, structurally valid town identity per index: 32 bytes of
    /// lowercase hex, exactly what `validateStructure` pins `peer` to.
    static func townHex(_ i: Int) -> String { String(format: "%064x", i) }

    /// Fill Bob's quota to exactly `maxStandingGrantsPerGranter` live grants, each
    /// naming a different town. Returns Bob's hex for the caller's assertions.
    @discardableResult
    static func fillBobToCap(
        _ fx: (engine: AgentEngine, clock: FixedClock, alice: PQRCIdentity, bob: PQRCIdentity),
        days: Int64 = 7
    ) async throws -> String {
        let bobHex = fx.bob.publicKeyData.hexString
        for i in 0..<PQRCConstants.maxStandingGrantsPerGranter {
            let grant = try StandingGrant.make(
                grantID: "cap-\(i)", peer: Self.townHex(i), planes: [.wall],
                budget: Self.budget(), activeUntil: fx.clock.now() + days * Self.day,
                identity: fx.bob)
            try await fx.engine.receiveStandingGrant(grant, fromSenderIdentityHex: bobHex)
        }
        return bobHex
    }

    /// The bound itself: at the cap a NEW grant id is refused, with the typed
    /// error — never a silent drop — and nothing partial is left behind.
    @Test func grantStoreIsBoundedPerGranter_newIDPastTheCapIsRefused() async throws {
        let fx = try Self.fixture()
        let bobHex = try await Self.fillBobToCap(fx)
        // Non-vacuity: the cap-th grant really did land, so the cap is where the
        // refusal starts rather than the loop having failed early.
        #expect(
            await fx.engine.activeStandingGrant(
                peerIdentityHex: Self.townHex(PQRCConstants.maxStandingGrantsPerGranter - 1),
                plane: .wall, granterIdentityHex: bobHex) != nil)

        let overflow = try StandingGrant.make(
            grantID: "overflow", peer: Self.townHex(9_999), planes: [.wall],
            budget: Self.budget(), activeUntil: fx.clock.now() + 7 * Self.day,
            identity: fx.bob)
        await #expect(throws: AgentEngineError.standingGrantLimitReached) {
            try await fx.engine.receiveStandingGrant(overflow, fromSenderIdentityHex: bobHex)
        }
        // Fail CLOSED: refusing can only ever withhold authorization, never widen it.
        #expect(
            await fx.engine.activeStandingGrant(
                peerIdentityHex: Self.townHex(9_999), plane: .wall,
                granterIdentityHex: bobHex) == nil)
    }

    /// A re-issue (top-up) of an id already on file is always honored, even at the
    /// cap: it adds no key, so it cannot grow the store. Refusing it would break
    /// the legitimate renewal path in precisely the case where renewal matters.
    @Test func reIssueOfAnExistingGrantIDIsHonoredAtTheCap() async throws {
        let fx = try Self.fixture()
        let bobHex = try await Self.fillBobToCap(fx)
        let renewedUntil = fx.clock.now() + 21 * Self.day
        let renewed = try StandingGrant.make(
            grantID: "cap-0", peer: Self.townHex(0), planes: [.wall],
            budget: Self.budget(), activeUntil: renewedUntil, identity: fx.bob)
        try await fx.engine.receiveStandingGrant(renewed, fromSenderIdentityHex: bobHex)

        let status = await fx.engine.activeStandingGrant(
            peerIdentityHex: Self.townHex(0), plane: .wall, granterIdentityHex: bobHex)
        #expect(status?.grantID == "cap-0")
        #expect(status?.activeUntil == renewedUntil)
    }

    /// `pruneExpiredGrants` is what stops the cap becoming a permanent lockout. An
    /// expired record already authorizes nothing (every gate and query requires
    /// `now < activeUntil`), so dropping it is behavior-preserving — and it frees
    /// the quota it was occupying. Message-driven, never a timer (invariant 1):
    /// nothing prunes until the next receive reads the clock.
    @Test func expiredGrantsArePrunedAndFreeTheGranterQuota() async throws {
        let fx = try Self.fixture()
        let bobHex = try await Self.fillBobToCap(fx, days: 1)
        let fresh = try StandingGrant.make(
            grantID: "after-expiry", peer: Self.townHex(9_999), planes: [.wall],
            budget: Self.budget(), activeUntil: fx.clock.now() + 30 * Self.day,
            identity: fx.bob)
        // Positive control: while the 64 are live, this exact grant is refused.
        await #expect(throws: AgentEngineError.standingGrantLimitReached) {
            try await fx.engine.receiveStandingGrant(fresh, fromSenderIdentityHex: bobHex)
        }
        // Once they lapse, the same grant is admitted.
        fx.clock.set(fx.clock.now() + Self.day)
        try await fx.engine.receiveStandingGrant(fresh, fromSenderIdentityHex: bobHex)
        #expect(
            await fx.engine.activeStandingGrant(
                peerIdentityHex: Self.townHex(9_999), plane: .wall,
                granterIdentityHex: bobHex) != nil)
    }

    /// The cap is keyed by GRANTER, so a hostile peer who fills their own quota
    /// cannot deny service to a legitimate one. The bound contains the attacker,
    /// not the node.
    @Test func theCapIsPerGranter_soOnePeerCannotLockOutAnother() async throws {
        let fx = try Self.fixture()
        let bobHex = try await Self.fillBobToCap(fx)
        let carol = try PQRCIdentity(seed: hexData(String(repeating: "c7", count: 32)))
        let carolHex = carol.publicKeyData.hexString

        let carolGrant = try StandingGrant.make(
            grantID: "carol-1", peer: Self.townHex(1), planes: [.wall],
            budget: Self.budget(), activeUntil: fx.clock.now() + 7 * Self.day,
            identity: carol)
        try await fx.engine.receiveStandingGrant(carolGrant, fromSenderIdentityHex: carolHex)
        #expect(
            await fx.engine.activeStandingGrant(
                peerIdentityHex: Self.townHex(1), plane: .wall,
                granterIdentityHex: carolHex) != nil)

        // And Carol's arrival neither raised nor consumed Bob's quota.
        let bobOverflow = try StandingGrant.make(
            grantID: "bob-overflow", peer: Self.townHex(9_999), planes: [.wall],
            budget: Self.budget(), activeUntil: fx.clock.now() + 7 * Self.day,
            identity: fx.bob)
        await #expect(throws: AgentEngineError.standingGrantLimitReached) {
            try await fx.engine.receiveStandingGrant(
                bobOverflow, fromSenderIdentityHex: bobHex)
        }
    }

    /// The cap counts distinct grant IDs, not materialized records: a both-planes
    /// grant produces two records but consumes one unit of quota. Counting records
    /// would silently halve the bound for anyone using the delegate plane.
    @Test func theCapCountsGrantIDsNotPlaneRecords() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        for i in 0..<PQRCConstants.maxStandingGrantsPerGranter {
            let grant = try StandingGrant.make(
                grantID: "both-\(i)", peer: Self.townHex(i), planes: [.wall, .delegate],
                budget: Self.budget(), activeUntil: fx.clock.now() + 7 * Self.day,
                identity: fx.bob)
            try await fx.engine.receiveStandingGrant(grant, fromSenderIdentityHex: bobHex)
        }
        // 64 ids accepted, both planes on file for each — i.e. 128 records live…
        for plane in [StandingGrant.Plane.wall, .delegate] {
            #expect(
                await fx.engine.activeStandingGrant(
                    peerIdentityHex: Self.townHex(0), plane: plane,
                    granterIdentityHex: bobHex) != nil)
        }
        // …and it is still the 65th ID, not the 65th record, that trips the bound.
        let overflow = try StandingGrant.make(
            grantID: "both-overflow", peer: Self.townHex(9_999), planes: [.wall, .delegate],
            budget: Self.budget(), activeUntil: fx.clock.now() + 7 * Self.day,
            identity: fx.bob)
        await #expect(throws: AgentEngineError.standingGrantLimitReached) {
            try await fx.engine.receiveStandingGrant(overflow, fromSenderIdentityHex: bobHex)
        }
    }
}
