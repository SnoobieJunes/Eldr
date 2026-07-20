// SPDX-License-Identifier: Apache-2.0
import A2ACore
import Foundation

/// Per-request facts a transport hands to `A2AServer.handle` — everything the
/// transport-agnostic core needs to know about the request that isn't in the
/// JSON-RPC body itself.
public struct A2ARequestContext: Sendable {
    /// The `A2A-Version` header/service-parameter value, verbatim. `nil` means the
    /// field was absent (which the spec defines as protocol version 0.3).
    public var declaredVersion: String?
    /// Whether the transport already authenticated this request (e.g. a valid
    /// bearer token over HTTP). `A2AServer` does no authentication itself — every
    /// transport binding MUST authenticate before calling `handle` (PRIVACY RULE:
    /// bearer auth is required on every HTTP route; this field exists so a future
    /// transport binding can assert that invariant in one place if it chooses to).
    public var isAuthenticated: Bool

    public init(declaredVersion: String?, isAuthenticated: Bool) {
        self.declaredVersion = declaredVersion
        self.isAuthenticated = isAuthenticated
    }
}

/// The transport-agnostic A2A server core: turns one JSON-RPC request line into one
/// response (or, for streaming methods, a line-per-SSE-event stream), driving a
/// pluggable `AgentExecutor` and `TaskStore`. An HTTP binding (`A2AHTTPServer`) wraps
/// this; so could a Multipeer/relay binding, unchanged.
///
/// **Version policy (deliberate, not a bug):** this SDK implements A2A v1.0 only.
/// An absent or empty `A2A-Version` means protocol 0.3 by the spec's own definition,
/// and any value other than exactly `"1.0"` is rejected with `VersionNotSupported`.
/// 0.3-era clients (and their `message/send`-style method names) are out of scope —
/// recorded as a deliberate non-goal, not an oversight.
///
/// An actor: task creation, the subscriber fan-out table, and in-flight execution
/// bookkeeping are all mutable state shared across concurrent callers.
public actor A2AServer {
    public enum Response: Sendable {
        case single(String)
        case stream(AsyncStream<String>)
    }

    private let card: A2AAgentCard
    private let executor: any AgentExecutor
    private let taskStore: any TaskStore

    /// Live subscribers per task id (`SendStreamingMessage` and `SubscribeToTask`
    /// callers currently awaiting events). Finishing a task's continuations and
    /// removing its entry happen together, in `broadcast`, so a finished task never
    /// leaves a stale (but empty) entry behind.
    private var subscribers: [String: [UUID: AsyncStream<A2AStreamResponse>.Continuation]] = [:]
    /// The in-flight execution `Task` per task id, so `CancelTask` can cooperatively
    /// cancel it in addition to calling `executor.cancel`.
    private var executingTasks: [String: Task<Void, Never>] = [:]

    /// History entries kept per task by this server's own status-append step
    /// (`TaskStore` implementations may apply their own, possibly different, cap —
    /// this one bounds what `A2AServer` itself appends before handing off to save).
    private static let maxHistoryMessages = 100

    public init(
        card: A2AAgentCard, executor: any AgentExecutor,
        taskStore: any TaskStore = InMemoryTaskStore()
    ) {
        self.card = card
        self.executor = executor
        self.taskStore = taskStore
    }

    // MARK: - Entry point

    /// Handle one JSON-RPC request line. Returns `nil` for a notification (a
    /// well-formed request with no `id`) per JSON-RPC 2.0 — no response is ever sent
    /// for those. Malformed input still gets a response (with a `null` id), since a
    /// parse failure means we cannot know whether the sender intended a notification.
    public func handle(rpcLine: String, context: A2ARequestContext) async -> Response? {
        // Version gate FIRST, before anything about the body is trusted.
        guard A2AVersion.isSupported(context.declaredVersion) else {
            return .single(Self.errorLine(id: nil, code: .versionNotSupported))
        }

        guard let data = rpcLine.data(using: .utf8),
            (try? JSONDecoder().decode(A2AJSONValue.self, from: data)) != nil
        else {
            return .single(Self.errorLine(id: nil, code: .jsonParseError))
        }
        guard let rpcRequest = try? JSONDecoder().decode(JSONRPCRequest.self, from: data)
        else {
            return .single(Self.errorLine(id: nil, code: .invalidRequest))
        }
        // A well-formed request with no id is a notification: no response, ever.
        guard let id = rpcRequest.id else { return nil }

        switch A2AMethod(rawValue: rpcRequest.method) {
        case .sendMessage:
            return await handleSendMessage(id: id, rpcRequest: rpcRequest)
        case .sendStreamingMessage:
            return await handleSendStreamingMessage(id: id, rpcRequest: rpcRequest)
        case .getTask:
            return await handleGetTask(id: id, rpcRequest: rpcRequest)
        case .listTasks:
            return await handleListTasks(id: id, rpcRequest: rpcRequest)
        case .cancelTask:
            return await handleCancelTask(id: id, rpcRequest: rpcRequest)
        case .subscribeToTask:
            return await handleSubscribeToTask(id: id, rpcRequest: rpcRequest)
        case .createTaskPushNotificationConfig, .getTaskPushNotificationConfig,
            .listTaskPushNotificationConfigs, .deleteTaskPushNotificationConfig:
            // PRIVACY RULE: push notifications are permanently unsupported — a
            // registered webhook URL leaks the client's network address to us on
            // every delivery. Not a missing feature; a refusal.
            return .single(Self.errorLine(id: id, code: .pushNotificationNotSupported))
        case .getExtendedAgentCard:
            if card.capabilities.extendedAgentCard == true {
                return .single(Self.successLine(id: id, result: card))
            }
            return .single(Self.errorLine(id: id, code: .unsupportedOperation))
        case .none:
            return .single(Self.errorLine(id: id, code: .methodNotFound))
        }
    }

    // MARK: - Method handlers

    private func handleSendMessage(id: JSONRPCID, rpcRequest: JSONRPCRequest) async -> Response
    {
        let sendRequest: A2ASendMessageRequest
        do {
            sendRequest = try rpcRequest.decodeParams(A2ASendMessageRequest.self)
        } catch {
            return .single(Self.errorLine(id: id, code: .invalidParams))
        }
        guard !sendRequest.message.parts.isEmpty else {
            return .single(
                Self.errorLine(
                    id: id, code: .invalidParams, message: "message.parts must not be empty"))
        }

        let task = Self.makeTask(from: sendRequest)
        await taskStore.save(task)
        let (subscriberID, events) = addSubscriber(taskId: task.id)
        spawnExecution(task: task, request: sendRequest)

        if sendRequest.configuration?.returnImmediately == true {
            removeSubscriber(taskId: task.id, id: subscriberID)
            return .single(Self.successLine(id: id, result: A2ASendMessageResponse.task(task)))
        }

        for await event in events {
            if case .statusUpdate(let update) = event,
                update.status.state.isTerminal || update.status.state.isInterrupted
            {
                break
            }
        }
        removeSubscriber(taskId: task.id, id: subscriberID)
        let final = await taskStore.task(id: task.id) ?? task
        return .single(Self.successLine(id: id, result: A2ASendMessageResponse.task(final)))
    }

    private func handleSendStreamingMessage(id: JSONRPCID, rpcRequest: JSONRPCRequest) async
        -> Response
    {
        let sendRequest: A2ASendMessageRequest
        do {
            sendRequest = try rpcRequest.decodeParams(A2ASendMessageRequest.self)
        } catch {
            return .single(Self.errorLine(id: id, code: .invalidParams))
        }
        guard !sendRequest.message.parts.isEmpty else {
            return .single(
                Self.errorLine(
                    id: id, code: .invalidParams, message: "message.parts must not be empty"))
        }

        let task = Self.makeTask(from: sendRequest)
        await taskStore.save(task)
        let (subscriberID, events) = addSubscriber(taskId: task.id)
        spawnExecution(task: task, request: sendRequest)

        return .stream(
            streamLines(
                id: id, taskId: task.id, subscriberID: subscriberID,
                initialFrames: [.task(task)], events: events))
    }

    private func handleGetTask(id: JSONRPCID, rpcRequest: JSONRPCRequest) async -> Response {
        let req: A2AGetTaskRequest
        do {
            req = try rpcRequest.decodeParams(A2AGetTaskRequest.self)
        } catch {
            return .single(Self.errorLine(id: id, code: .invalidParams))
        }
        guard var task = await taskStore.task(id: req.id) else {
            return .single(Self.errorLine(id: id, code: .taskNotFound))
        }
        task.history = Self.trimHistory(task.history, to: req.historyLength)
        return .single(Self.successLine(id: id, result: task))
    }

    private func handleListTasks(id: JSONRPCID, rpcRequest: JSONRPCRequest) async -> Response {
        let req: A2AListTasksRequest
        do {
            req = try rpcRequest.decodeParams(A2AListTasksRequest.self)
        } catch {
            return .single(Self.errorLine(id: id, code: .invalidParams))
        }
        let result = await taskStore.list(matching: req)
        return .single(Self.successLine(id: id, result: result))
    }

    private func handleCancelTask(id: JSONRPCID, rpcRequest: JSONRPCRequest) async -> Response {
        let req: A2ACancelTaskRequest
        do {
            req = try rpcRequest.decodeParams(A2ACancelTaskRequest.self)
        } catch {
            return .single(Self.errorLine(id: id, code: .invalidParams))
        }
        guard let task = await taskStore.task(id: req.id) else {
            return .single(Self.errorLine(id: id, code: .taskNotFound))
        }
        guard
            !task.status.state.isTerminal,
            TaskStateMachine.canTransition(from: task.status.state, to: .canceled)
        else {
            return .single(Self.errorLine(id: id, code: .taskNotCancelable))
        }

        await executor.cancel(taskId: req.id)
        executingTasks[req.id]?.cancel()
        executingTasks.removeValue(forKey: req.id)
        await applyStatus(taskId: req.id, status: A2ATaskStatus(state: .canceled), appendHistory: false)

        let finalTask = await taskStore.task(id: req.id) ?? task
        return .single(Self.successLine(id: id, result: finalTask))
    }

    private func handleSubscribeToTask(id: JSONRPCID, rpcRequest: JSONRPCRequest) async
        -> Response
    {
        let req: A2ASubscribeToTaskRequest
        do {
            req = try rpcRequest.decodeParams(A2ASubscribeToTaskRequest.self)
        } catch {
            return .single(Self.errorLine(id: id, code: .invalidParams))
        }
        guard let task = await taskStore.task(id: req.id) else {
            return .single(Self.errorLine(id: id, code: .taskNotFound))
        }
        guard !task.status.state.isTerminal else {
            return .single(Self.errorLine(id: id, code: .unsupportedOperation))
        }

        let (subscriberID, events) = addSubscriber(taskId: task.id)
        return .stream(
            streamLines(
                id: id, taskId: task.id, subscriberID: subscriberID, initialFrames: [],
                events: events))
    }

    // MARK: - Execution

    private func spawnExecution(task: A2ATask, request: A2ASendMessageRequest) {
        let sink = TaskEventSinkImpl(server: self, taskId: task.id)
        executingTasks[task.id] = Task { [executor] in
            await self.recordStatus(taskId: task.id, status: A2ATaskStatus(state: .working))
            do {
                let finalStatus = try await executor.execute(
                    task: task, request: request, events: sink)
                await self.finalizeExecution(taskId: task.id, status: finalStatus)
            } catch {
                let message = A2AMessage(
                    role: .agent, parts: [.text(error.localizedDescription)])
                await self.finalizeExecution(
                    taskId: task.id,
                    status: A2ATaskStatus(state: .failed, message: message))
            }
            self.clearExecuting(taskId: task.id)
        }
    }

    private func clearExecuting(taskId: String) {
        executingTasks.removeValue(forKey: taskId)
    }

    /// Called by the `TaskEventSink` for intermediate progress updates. No history
    /// append — only the final (terminal/interrupted) status carries its message
    /// into history, via `finalizeExecution`.
    fileprivate func recordStatus(taskId: String, status: A2ATaskStatus) async {
        await applyStatus(taskId: taskId, status: status, appendHistory: false)
    }

    fileprivate func recordArtifact(
        taskId: String, artifact: A2AArtifact, append: Bool, lastChunk: Bool
    ) async {
        guard var task = await taskStore.task(id: taskId) else { return }
        if append, let index = task.artifacts.firstIndex(where: { $0.artifactId == artifact.artifactId })
        {
            task.artifacts[index].parts.append(contentsOf: artifact.parts)
        } else {
            task.artifacts.append(artifact)
        }
        await taskStore.save(task)
        let event = A2ATaskArtifactUpdateEvent(
            taskId: task.id, contextId: task.contextId, artifact: artifact, append: append,
            lastChunk: lastChunk)
        broadcast(taskId: task.id, event: .artifactUpdate(event), finish: false)
    }

    private func finalizeExecution(taskId: String, status: A2ATaskStatus) async {
        await applyStatus(taskId: taskId, status: status, appendHistory: true)
    }

    /// The single choke point for every status mutation: validates the transition
    /// through `TaskStateMachine`, stamps a timestamp if the caller didn't supply
    /// one, persists, and broadcasts to subscribers — finishing (and closing) their
    /// streams once the new status is terminal or interrupted, per spec.
    private func applyStatus(taskId: String, status: A2ATaskStatus, appendHistory: Bool) async {
        guard var task = await taskStore.task(id: taskId) else { return }
        guard TaskStateMachine.canTransition(from: task.status.state, to: status.state) else {
            return
        }
        var newStatus = status
        if newStatus.timestamp == nil {
            newStatus.timestamp = Self.isoTimestamp()
        }
        task.status = newStatus
        if appendHistory, let message = newStatus.message {
            task.history.append(message)
            if task.history.count > Self.maxHistoryMessages {
                task.history.removeFirst(task.history.count - Self.maxHistoryMessages)
            }
        }
        await taskStore.save(task)

        let event = A2ATaskStatusUpdateEvent(
            taskId: task.id, contextId: task.contextId, status: newStatus)
        let shouldFinish = newStatus.state.isTerminal || newStatus.state.isInterrupted
        broadcast(taskId: task.id, event: .statusUpdate(event), finish: shouldFinish)
    }

    // MARK: - Subscriber fan-out

    private func addSubscriber(taskId: String) -> (
        id: UUID, events: AsyncStream<A2AStreamResponse>
    ) {
        let subscriberID = UUID()
        var continuation: AsyncStream<A2AStreamResponse>.Continuation!
        let stream = AsyncStream<A2AStreamResponse> { continuation = $0 }
        subscribers[taskId, default: [:]][subscriberID] = continuation
        return (subscriberID, stream)
    }

    /// Idempotent: finishing an already-finished (or never-registered) subscriber
    /// is a no-op. Finishing here (rather than just dropping the dictionary entry)
    /// guarantees any consumer still iterating this subscriber's stream observes
    /// completion instead of hanging forever.
    private func removeSubscriber(taskId: String, id: UUID) {
        subscribers[taskId]?[id]?.finish()
        subscribers[taskId]?[id] = nil
        if subscribers[taskId]?.isEmpty == true {
            subscribers[taskId] = nil
        }
    }

    private func broadcast(taskId: String, event: A2AStreamResponse, finish: Bool) {
        guard let subs = subscribers[taskId] else { return }
        for continuation in subs.values {
            continuation.yield(event)
            if finish { continuation.finish() }
        }
        if finish {
            subscribers[taskId] = nil
        }
    }

    /// Adapts a task's `events` stream (already `A2AStreamResponse`, in generation
    /// order) into the JSON-RPC-line `AsyncStream<String>` the transport sends as
    /// SSE, optionally prefixed with `initialFrames` (the submitted-task snapshot
    /// for `SendStreamingMessage`; empty for `SubscribeToTask`). Unregisters the
    /// subscriber when the consumer stops iterating, however that happens.
    private func streamLines(
        id: JSONRPCID, taskId: String, subscriberID: UUID,
        initialFrames: [A2AStreamResponse], events: AsyncStream<A2AStreamResponse>
    ) -> AsyncStream<String> {
        AsyncStream<String> { continuation in
            let pump = Task {
                for frame in initialFrames {
                    if let line = Self.encodeLine(id: id, payload: frame) {
                        continuation.yield(line)
                    }
                }
                for await event in events {
                    if let line = Self.encodeLine(id: id, payload: event) {
                        continuation.yield(line)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                pump.cancel()
                guard let self else { return }
                Task { await self.removeSubscriber(taskId: taskId, id: subscriberID) }
            }
        }
    }

    // MARK: - Helpers

    private static func makeTask(from request: A2ASendMessageRequest) -> A2ATask {
        let taskId = UUID().uuidString
        let contextId =
            request.message.contextId.isEmpty ? UUID().uuidString : request.message.contextId
        var message = request.message
        if message.contextId.isEmpty { message.contextId = contextId }
        if message.taskId.isEmpty { message.taskId = taskId }
        return A2ATask(
            id: taskId, contextId: contextId,
            status: A2ATaskStatus(state: .submitted, timestamp: Self.isoTimestamp()),
            artifacts: [], history: [message])
    }

    private static func trimHistory(_ history: [A2AMessage], to length: Int?) -> [A2AMessage] {
        guard let length else { return history }
        if length <= 0 { return [] }
        return Array(history.suffix(length))
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func encodeLine(id: JSONRPCID, payload: A2AStreamResponse) -> String? {
        guard let response = try? JSONRPCResponse(id: id, result: payload) else { return nil }
        return try? A2AWireCodec.encodeString(response)
    }

    private static func errorLine(id: JSONRPCID?, code: A2AErrorCode, message: String? = nil)
        -> String
    {
        let response = JSONRPCResponse(id: id, error: A2AErrorObject(code: code, message: message))
        return (try? A2AWireCodec.encodeString(response)) ?? Self.fallbackErrorLine
    }

    private static func successLine(id: JSONRPCID?, result: some Encodable) -> String {
        guard let response = try? JSONRPCResponse(id: id, result: result),
            let line = try? A2AWireCodec.encodeString(response)
        else {
            return errorLine(id: id, code: .internalError)
        }
        return line
    }

    private static let fallbackErrorLine =
        #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}"#
}

/// `TaskEventSink` implementation handed to the executor: a thin, `Sendable` bridge
/// back onto the owning `A2AServer` actor, scoped to one task id.
private struct TaskEventSinkImpl: TaskEventSink {
    let server: A2AServer
    let taskId: String

    func status(_ status: A2ATaskStatus) async {
        await server.recordStatus(taskId: taskId, status: status)
    }

    func artifact(_ artifact: A2AArtifact, append: Bool, lastChunk: Bool) async {
        await server.recordArtifact(
            taskId: taskId, artifact: artifact, append: append, lastChunk: lastChunk)
    }
}
