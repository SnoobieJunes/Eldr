import Foundation

/// Where outbound JSON-RPC lines go. Production writes to stdout; tests capture to
/// a buffer. One line per message, newline-delimited (the ACP/MCP stdio framing).
public protocol OutputSink: Sendable {
    func write(line: String) async
}

/// An `OutputSink` over a `FileHandle` (stdout in production). Writes are
/// serialized through this actor so concurrent notifications never interleave
/// bytes on the pipe.
public actor FileHandleOutputSink: OutputSink {
    private let handle: FileHandle
    public init(_ handle: FileHandle) { self.handle = handle }
    public func write(line: String) async {
        handle.write(Data((line + "\n").utf8))
    }
}

/// The agent→client half of the bidirectional transport. Owns the output sink and
/// the table of in-flight OUTBOUND requests (the ones the agent makes on the
/// client: `fs/*`, `terminal/*`, `session/request_permission`). The inbound reader
/// loop calls `deliver(response:)` when it sees a result/error whose `id` we issued;
/// that resumes the awaiting `request(...)` call.
///
/// JSON-RPC id space: outbound requests use a negative counter so they never
/// collide with the client's (typically non-negative) request ids — purely a
/// hygiene measure since the two id spaces are independent per the spec.
public actor ClientConnection {
    private let sink: any OutputSink
    private var nextOutboundID = -1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Per-request timeout tasks, cancelled when the response arrives, so a bounded
    /// `request(timeout:)` resumes with `.timedOut` only when the client never answers.
    private var timeouts: [Int: Task<Void, Never>] = [:]

    public init(sink: any OutputSink) { self.sink = sink }

    public enum ConnectionError: Error, Sendable, Equatable {
        case rpc(code: Int, message: String)
        case cancelled
        case malformed(String)
        /// A bounded `request(timeout:)` whose client never answered in time.
        case timedOut
    }

    // MARK: Outbound

    /// Fire-and-forget notification (no id, no response): `session/update`,
    /// `session/cancel`, …
    public func notify(method: String, params: JSONValue) async {
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        await sink.write(line: envelope.serialized())
    }

    /// Request the client and await its response. Suspends until the reader loop
    /// routes the matching result/error back via `deliver(response:)`.
    public func request(
        method: String, params: JSONValue, timeout: Double? = nil
    ) async throws -> JSONValue {
        let id = nextOutboundID
        nextOutboundID -= 1
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { await sink.write(line: envelope.serialized()) }
            // C-1: bound the wait so a client that never answers (e.g. no
            // session/request_permission support) can't hang the turn. On expiry the
            // awaiter resumes with `.timedOut`; callers treat that as a denial.
            if let timeout, timeout > 0 {
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.expire(id)
                }
            }
        }
    }

    /// Resume a still-pending request with `.timedOut` and drop it. No-op if the
    /// response already arrived, so it never double-resumes a continuation.
    private func expire(_ id: Int) {
        timeouts[id] = nil
        guard let continuation = pending[id] else { return }
        pending[id] = nil
        continuation.resume(throwing: ConnectionError.timedOut)
    }

    /// Route an inbound response (a message that has `id` + `result`/`error`, no
    /// `method`) back to the awaiting `request(...)`. Returns true if it matched one
    /// of our outbound ids (so the reader knows it consumed it).
    @discardableResult
    public func deliver(response: JSONValue) -> Bool {
        guard let id = response["id"]?.intValue, let continuation = pending[id] else {
            return false
        }
        pending[id] = nil
        timeouts[id]?.cancel()
        timeouts[id] = nil
        if let error = response["error"] {
            let code = error["code"]?.intValue ?? -32603
            let message = error["message"]?.stringValue ?? "client error"
            continuation.resume(throwing: ConnectionError.rpc(code: code, message: message))
        } else {
            continuation.resume(returning: response["result"] ?? .object([:]))
        }
        return true
    }

    /// Fail all outstanding outbound requests (e.g. the client closed the pipe).
    public func failAll(_ error: Error) {
        let waiters = pending.values
        pending.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for continuation in waiters { continuation.resume(throwing: error) }
    }

    /// True if `id` is one we issued (negative) and still awaiting.
    public func isOutboundResponse(_ json: JSONValue) -> Bool {
        guard json["method"] == nil, let id = json["id"]?.intValue else { return false }
        return pending[id] != nil
    }
}
