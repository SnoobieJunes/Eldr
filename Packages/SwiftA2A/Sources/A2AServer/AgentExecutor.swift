import A2ACore

// The business-logic seam a server-side A2A implementation plugs into. `A2AServer`
// (transport-agnostic core) drives one `AgentExecutor` call per task and handles all
// protocol bookkeeping (state machine legality, persistence, subscriber fan-out)
// around it — the executor only needs to know how to do the work.

/// Sink the executor uses to report task progress. Every update is persisted to the
/// `TaskStore` and fanned out to live subscribers by the server.
public protocol TaskEventSink: Sendable {
    /// Report an intermediate status change (e.g. a `WORKING` progress update).
    /// Illegal transitions (per `TaskStateMachine`) are silently dropped by the
    /// server — the terminal/interrupted status returned from `execute` (or the
    /// `FAILED` status synthesized on a thrown error) is always what wins.
    func status(_ status: A2ATaskStatus) async
    /// Report a generated or updated artifact. `append` merges this artifact's parts
    /// onto a previously reported artifact with the same `artifactId`; `lastChunk`
    /// marks the final piece of a chunked artifact.
    func artifact(_ artifact: A2AArtifact, append: Bool, lastChunk: Bool) async
}

/// The business logic behind a served agent: executes one task per call.
public protocol AgentExecutor: Sendable {
    /// Run the task to completion. Return the terminal (or interrupted) status.
    /// Throwing the call is treated as a `FAILED` terminal status, with the
    /// server-synthesized status message carrying `error.localizedDescription`.
    func execute(
        task: A2ATask, request: A2ASendMessageRequest, events: any TaskEventSink
    ) async throws -> A2ATaskStatus

    /// Best-effort cancellation of a running task. The server calls this before it
    /// force-transitions the task to `CANCELED` on `CancelTask`; implementations
    /// should make `execute` return/throw promptly afterward, but the server does
    /// not wait on that — cancellation always succeeds from the client's view.
    func cancel(taskId: String) async
}
