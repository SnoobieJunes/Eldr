import Foundation
import Testing

@testable import EldrChat

/// Phase 3 item 3 — the interactive per-tool permission queue. These prove the
/// continuation mechanics the runtime's `async` permission handler depends on: a request
/// PARKS until the UI resolves it, the choice is returned faithfully, and a teardown
/// (`cancelAll`) DENIES every pending request for a node without ever orphaning a
/// continuation (a stranded `await` would wedge the node's turn + leak).
@MainActor
@Suite("ACP permission coordinator (Phase 3 item 3)")
struct ACPPermissionCoordinatorTests {

    /// Poll until `condition` holds (deterministic readiness instead of a fixed sleep).
    private func waitUntil(_ condition: () -> Bool, timeoutMillis: Int = 2_000) async {
        var waited = 0
        while !condition() && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
    }

    @Test func request_parksUntilResolved_thenReturnsTheChoice() async {
        let coord = ACPPermissionCoordinator()
        async let decision = coord.request(
            PermissionRequest(id: "1", nodeHex: "node", title: "Run: ls -la", kind: "execute"))

        await waitUntil { !coord.pending.isEmpty }
        #expect(coord.pending.count == 1, "the request must be queued (parked), not resolved")
        #expect(coord.pending.first?.title == "Run: ls -la")

        coord.resolve(id: "1", .allowOnce)
        #expect(await decision == .allowOnce, "the parked handler resumes with the UI's choice")
        #expect(coord.pending.isEmpty, "a resolved request leaves the queue")
    }

    @Test func cancelAll_deniesOnlyThatNodesPending_neverOrphans() async {
        let coord = ACPPermissionCoordinator()
        async let d1 = coord.request(
            PermissionRequest(id: "a", nodeHex: "n1", title: "Write A.swift", kind: "edit"))
        async let d2 = coord.request(
            PermissionRequest(id: "b", nodeHex: "n2", title: "Write B.swift", kind: "edit"))

        await waitUntil { coord.pending.count == 2 }
        #expect(coord.pending.count == 2)

        // Tear down node n1 → its pending request is DENIED (fail-closed); n2 untouched.
        coord.cancelAll(nodeHex: "n1")
        #expect(await d1 == .deny, "a torn-down node's pending prompt resolves to deny")
        #expect(coord.pending.map(\.nodeHex) == ["n2"], "only n1 was cancelled")

        coord.resolve(id: "b", .allowAlways)
        #expect(await d2 == .allowAlways)
        #expect(coord.pending.isEmpty)
    }

    @Test func resolve_unknownId_isANoOp() async {
        let coord = ACPPermissionCoordinator()
        coord.resolve(id: "nope", .allowOnce)  // nothing queued → must not crash
        #expect(coord.pending.isEmpty)
    }
}
