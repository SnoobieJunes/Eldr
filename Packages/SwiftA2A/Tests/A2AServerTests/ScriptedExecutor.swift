import A2ACore
import A2AServer
import Foundation

// A controllable `AgentExecutor` for driving `A2AServer` through specific
// interleavings deterministically (no `sleep`-based races). Every gate is an actor-
// isolated `CheckedContinuation`, resumed exactly once, so tests can pin down
// "the executor has reached point X" before proceeding.

actor ScriptedExecutor: AgentExecutor {
    private(set) var cancelCalls: [String] = []

    /// If true, `execute` suspends immediately (before emitting anything) until the
    /// test calls `proceed()`.
    var blockAtStart = false
    /// If true, after emitting WORKING + two artifact chunks, `execute` suspends
    /// until `cancel(taskId:)` is called (simulating a task the test cancels
    /// mid-flight).
    var waitForCancel = false

    private var startGateOpen = false
    private var startGateContinuation: CheckedContinuation<Void, Never>?
    private var isBlockedAtStart = false
    private var blockedAtStartWaiters: [CheckedContinuation<Void, Never>] = []

    private var cancelGateOpen = false
    private var cancelGateContinuation: CheckedContinuation<Void, Never>?
    private var isBlockedOnCancelGate = false
    private var blockedOnCancelWaiters: [CheckedContinuation<Void, Never>] = []

    func configure(blockAtStart: Bool = false, waitForCancel: Bool = false) {
        self.blockAtStart = blockAtStart
        self.waitForCancel = waitForCancel
    }

    /// Release a `blockAtStart` executor. Safe to call before or after `execute`
    /// reaches the gate (no race — nothing is emitted until this is called either
    /// way).
    func proceed() {
        startGateOpen = true
        startGateContinuation?.resume()
        startGateContinuation = nil
    }

    /// Suspends until a `blockAtStart` executor's `execute` has been entered and is
    /// now parked at the start gate — i.e. before it has emitted anything itself.
    /// Note this is strictly *after* `A2AServer`'s own automatic SUBMITTED->WORKING
    /// transition (which happens before `execute` is ever called), so a caller that
    /// waits on this before subscribing is guaranteed to have missed that one
    /// automatic transition, deterministically, regardless of scheduling.
    func waitUntilBlockedAtStart() async {
        if isBlockedAtStart { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            blockedAtStartWaiters.append(continuation)
        }
    }

    /// Suspends until `execute` has emitted both artifacts and is now blocked
    /// awaiting cancellation. Deterministic: safe to await from a test regardless
    /// of scheduling, whether `execute` got there first or this call did.
    func waitUntilBlockedOnCancel() async {
        if isBlockedOnCancelGate { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            blockedOnCancelWaiters.append(continuation)
        }
    }

    func execute(
        task: A2ATask, request: A2ASendMessageRequest, events: any TaskEventSink
    ) async throws -> A2ATaskStatus {
        if blockAtStart, !startGateOpen {
            isBlockedAtStart = true
            let waiters = blockedAtStartWaiters
            blockedAtStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.startGateContinuation = continuation
            }
        }

        // No `events.status(.working)` call here: `A2AServer` already transitions
        // the task to WORKING (via the sink) before ever calling `execute` — a
        // well-behaved executor only reports *further* progress, it doesn't need to
        // re-announce the state the server already set.
        await events.artifact(
            A2AArtifact(artifactId: "a1", name: "out", parts: [.text("chunk one")]),
            append: false, lastChunk: false)
        await events.artifact(
            A2AArtifact(artifactId: "a1", name: "out", parts: [.text(" chunk two")]),
            append: true, lastChunk: true)

        guard waitForCancel else {
            return A2ATaskStatus(state: .completed)
        }

        isBlockedOnCancelGate = true
        let waiters = blockedOnCancelWaiters
        blockedOnCancelWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        if !cancelGateOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.cancelGateContinuation = continuation
            }
        }
        // The server itself force-transitions to CANCELED via `CancelTask`; this
        // return value only matters if nothing canceled us (it won't be reached in
        // the cancellation tests, since the gate only opens from `cancel`).
        return A2ATaskStatus(state: .completed)
    }

    func cancel(taskId: String) async {
        cancelCalls.append(taskId)
        cancelGateOpen = true
        cancelGateContinuation?.resume()
        cancelGateContinuation = nil
    }
}

/// An `AgentExecutor` that always throws, for exercising the FAILED-on-throw path.
actor ThrowingExecutor: AgentExecutor {
    struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    func execute(
        task: A2ATask, request: A2ASendMessageRequest, events: any TaskEventSink
    ) async throws -> A2ATaskStatus {
        throw Boom()
    }

    func cancel(taskId: String) async {}
}
