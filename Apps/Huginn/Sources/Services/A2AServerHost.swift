import A2ACore
import A2AHTTPServer
import A2AHarness
import A2AServer
import Foundation
import PQRCACP
import Security

// Surface (b) of the A2A capability: THIS Mac serves an A2A v1.0 endpoint other tools can
// call, in contrast to surface (a) (`ACPRelayHost`/`ACPNodeHost` + `A2AHarnessFactory`,
// where this Mac DELEGATES to a remote A2A agent). OFF by default; every inbound task needs
// explicit per-task operator approval (`InboundTaskGate`) before the harness runs at all,
// and nested tool-use inside an approved task defaults to DENY unless the operator also
// ticked "allow tool use" on that specific approval (fail-closed both ways, mirroring the
// C-1/C-3 gates elsewhere in this app).
//
// PRIVACY: task/message text is never logged — only counts/ids/status go to
// `DiagnosticsLog`. The bearer token lives in the Keychain only.

// MARK: - Per-task operator approval gate (fail-closed)

/// Gates every inbound A2A task behind an explicit operator decision on this Mac. Owned by
/// `A2AServerHost`; `HarnessAgentExecutor` calls `requestApproval` before running anything.
/// An actor (not itself `ObservableObject` — actors can't host `@Published`), so the owning
/// `@MainActor` host mirrors `updates` into its own published list for the UI.
actor InboundTaskGate {
    struct PendingApproval: Identifiable, Sendable, Equatable {
        let id: UUID
        let taskId: String
        /// Already truncated to ≤200 chars — the UI shows this verbatim, never the full text.
        let summary: String
        let peer: String
    }

    enum Decision: Sendable {
        case approved(allowToolUse: Bool)
        case denied(reason: String)
    }

    /// Deny-on-timeout bound (SPEC-equivalent to every other permission gate in this app
    /// defaulting closed on silence).
    static let timeoutSeconds: UInt64 = 120

    private var waiters: [UUID: CheckedContinuation<Decision, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var pending: [PendingApproval] = []
    private var updatesContinuation: AsyncStream<[PendingApproval]>.Continuation?

    /// The live pending-approval list, for the host to mirror into its `@Published` state.
    nonisolated let updates: AsyncStream<[PendingApproval]>

    init() {
        var continuation: AsyncStream<[PendingApproval]>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.updatesContinuation = continuation
    }

    /// Publish a new pending item and suspend until the operator (or the timeout) resolves
    /// it. `summary` is truncated to 200 chars here so no caller can accidentally publish
    /// more than the UI is meant to show.
    func requestApproval(
        taskId: String, summary: String, peer: String = "HTTP client (local)"
    ) async -> Decision {
        let id = UUID()
        let item = PendingApproval(id: id, taskId: taskId, summary: String(summary.prefix(200)), peer: peer)
        pending.append(item)
        updatesContinuation?.yield(pending)
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            timeoutTasks[id] = Task {
                try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
                await self.resolve(id: id, decision: .denied(reason: "Timed out waiting for operator approval"))
            }
        }
    }

    func approve(id: UUID, allowToolUse: Bool) {
        resolve(id: id, decision: .approved(allowToolUse: allowToolUse))
    }

    func deny(id: UUID) {
        resolve(id: id, decision: .denied(reason: "Rejected by operator"))
    }

    private func resolve(id: UUID, decision: Decision) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        pending.removeAll { $0.id == id }
        updatesContinuation?.yield(pending)
        continuation.resume(returning: decision)
    }
}

// MARK: - Executor: runs one approved task against the selected harness

/// The `AgentExecutor` behind the served A2A agent: gates on operator approval, then bridges
/// one A2A task to an in-process ACP harness run over an `InMemoryACPTransport` pair — the
/// exact same `runHarness` seam surface (a) uses to DELEGATE, run in reverse.
actor HarnessAgentExecutor: AgentExecutor {
    struct RefusedByAgent: Error, Sendable { let stopReason: String }

    // `@MainActor`-isolated (not `@Sendable`) — these read live `@MainActor` state
    // (`ACPBridgeService`/`ConfigurationStore` selections), mirroring
    // `LLMHealthChecker.configProvider`'s established pattern. Calling one from this actor
    // crosses isolation domains, hence the `await` at each call site below.
    private let descriptorProvider: @MainActor () -> HarnessDescriptor
    private let llmProvider: @MainActor () -> any LLMClient
    private let toolEnvironmentProvider: @MainActor () -> ToolEnvironment
    private let agentConfigProvider: @MainActor () -> AgentConfig
    private let gate: InboundTaskGate

    private var activeDrivers: [String: ACPClientDriver] = [:]
    private var activeHarnessTasks: [String: Task<Void, Never>] = [:]

    init(
        descriptorProvider: @escaping @MainActor () -> HarnessDescriptor,
        llmProvider: @escaping @MainActor () -> any LLMClient,
        toolEnvironmentProvider: @escaping @MainActor () -> ToolEnvironment,
        agentConfigProvider: @escaping @MainActor () -> AgentConfig,
        gate: InboundTaskGate
    ) {
        self.descriptorProvider = descriptorProvider
        self.llmProvider = llmProvider
        self.toolEnvironmentProvider = toolEnvironmentProvider
        self.agentConfigProvider = agentConfigProvider
        self.gate = gate
    }

    func execute(
        task: A2ATask, request: A2ASendMessageRequest, events: any TaskEventSink
    ) async throws -> A2ATaskStatus {
        let promptText = Self.extractText(request.message.parts)
        let decision = await gate.requestApproval(taskId: task.id, summary: promptText)
        switch decision {
        case .denied(let reason):
            // REJECTED, not thrown — a thrown error records FAILED (see A2AServer), and a
            // denial is a deliberate operator decision, not a failure.
            return A2ATaskStatus(state: .rejected, message: A2AMessage(role: .agent, parts: [.text(reason)]))
        case .approved(let allowToolUse):
            return try await runApproved(
                taskId: task.id, promptText: promptText, allowToolUse: allowToolUse, events: events)
        }
    }

    func cancel(taskId: String) async {
        // Fail-closed teardown: closing the client end finishes the harness's transport, so
        // the whole session unwinds regardless of where the run currently is.
        await activeDrivers[taskId]?.shutdown()
        activeHarnessTasks[taskId]?.cancel()
    }

    private func runApproved(
        taskId: String, promptText: String, allowToolUse: Bool, events: any TaskEventSink
    ) async throws -> A2ATaskStatus {
        let (clientEnd, nodeEnd) = InMemoryACPTransport.makePair()
        let descriptor = await descriptorProvider()
        let llm = await llmProvider()
        let toolEnvironment = await toolEnvironmentProvider()
        let config = await agentConfigProvider()

        let harnessTask = Task {
            await runHarness(
                descriptor: descriptor, client: nodeEnd, llm: llm, toolEnvironment: toolEnvironment,
                config: config, streamingEnabled: true, factory: A2AHarnessFactory())
        }
        activeHarnessTasks[taskId] = harnessTask
        defer { activeHarnessTasks[taskId] = nil }

        let collector = AgentAnswerCollector()
        // Nested harness permission requests (write_file/run_shell/…) default-DENY unless
        // THIS specific approval's "allow tool use" checkbox was ticked — independent of any
        // Mac-local `allowUngatedTools` preference (see `agentConfigProvider`'s doc comment).
        let handler = ACPClientHandler(
            onAgentMessageChunk: { text in
                await collector.append(text)
                await events.status(
                    A2ATaskStatus(
                        state: .working, message: A2AMessage(role: .agent, parts: [.text(text)])))
            },
            requestPermission: { _, _ in allowToolUse })
        let driver = ACPClientDriver(transport: clientEnd, handler: handler)
        activeDrivers[taskId] = driver
        defer { activeDrivers[taskId] = nil }

        do {
            _ = try await driver.start()
            let stopReason = try await driver.prompt(promptText)
            await driver.shutdown()
            harnessTask.cancel()
            guard stopReason != "refusal" else { throw RefusedByAgent(stopReason: stopReason) }
            let fullText = await collector.value
            if !fullText.isEmpty {
                await events.artifact(
                    A2AArtifact(artifactId: UUID().uuidString, parts: [.text(fullText)]),
                    append: false, lastChunk: true)
            }
            return A2ATaskStatus(state: .completed)
        } catch {
            await driver.shutdown()
            harnessTask.cancel()
            throw error
        }
    }

    private static func extractText(_ parts: [A2APart]) -> String {
        parts.compactMap(\.text).joined(separator: "\n")
    }
}

// MARK: - Host: owns the HTTP listener + Keychain-backed token + lifecycle

/// The served-A2A lifecycle object: OFF by default, started only by an explicit toggle
/// (`BridgeView`'s "A2A serving" section). Mirrors `ACPBridgeService`'s service-object
/// conventions (`@MainActor final class … ObservableObject`, mutable provider closures set
/// by the composition root — see `LLMHealthChecker.configProvider` for the established
/// pattern this follows).
@MainActor
final class A2AServerHost: ObservableObject {
    @Published private(set) var isServing = false
    @Published var port: Int = A2AServerHost.loadPort() {
        didSet { UserDefaults.standard.set(port, forKey: Self.portKey) }
    }
    @Published private(set) var bearerToken: String
    @Published private(set) var pendingApprovals: [InboundTaskGate.PendingApproval] = []
    @Published private(set) var lastError: String?

    /// Dependencies, wired by the composition root (`BridgeView`) once real selections
    /// exist. Defaults are inert (never used unless `start()` is called before wiring).
    var descriptorProvider: @MainActor () -> HarnessDescriptor = { .builtIn }
    var llmProvider: @MainActor () -> any LLMClient = { NullLLMClient() }
    var toolEnvironmentProvider: @MainActor () -> ToolEnvironment = { .fromEnvironment() }
    var agentConfigProvider: @MainActor () -> AgentConfig = { .default }

    static let portKey = "a2aServerPort"
    static let defaultPort = 41252
    static func loadPort() -> Int {
        (UserDefaults.standard.object(forKey: portKey) as? Int) ?? defaultPort
    }

    private static let tokenAccount = "a2a-server-bearer-token"
    private let keychain: KeychainBox
    private let gate = InboundTaskGate()
    private var approvalsTask: Task<Void, Never>?
    private var httpServer: A2AHTTPServer?

    init(keychain: KeychainBox = KeychainBox()) {
        self.keychain = keychain
        self.bearerToken = Self.loadOrCreateToken(keychain: keychain)
    }

    // MARK: Lifecycle

    func start() async {
        guard !isServing else { return }
        let descriptor = descriptorProvider()
        let card = Self.buildCard(descriptor: descriptor, port: port)
        let executor = HarnessAgentExecutor(
            descriptorProvider: descriptorProvider, llmProvider: llmProvider,
            toolEnvironmentProvider: toolEnvironmentProvider,
            agentConfigProvider: agentConfigProvider, gate: gate)
        let server = A2AServer(card: card, executor: executor)
        let authenticator = BearerAuthenticator(token: bearerToken)
        let http = A2AHTTPServer(
            server: server, card: card, authenticator: authenticator, port: UInt16(clamping: port))
        do {
            let boundPort = try await http.start()
            httpServer = http
            port = Int(boundPort)
            isServing = true
            lastError = nil
            approvalsTask = Task { [weak self] in
                guard let self else { return }
                for await items in gate.updates { self.pendingApprovals = items }
            }
            DiagnosticsLog.shared.post(.node, .info, "A2A server started", "port=\(boundPort)")
        } catch {
            lastError = "Could not start the A2A server: \(error)"
            DiagnosticsLog.shared.post(.node, .error, "A2A server failed to start", "\(error)")
        }
    }

    func stop() async {
        approvalsTask?.cancel()
        approvalsTask = nil
        await httpServer?.stop()
        httpServer = nil
        isServing = false
        pendingApprovals = []
        DiagnosticsLog.shared.post(.node, .info, "A2A server stopped")
    }

    // MARK: Approvals (forwarded to the gate)

    func approve(_ item: InboundTaskGate.PendingApproval, allowToolUse: Bool) async {
        await gate.approve(id: item.id, allowToolUse: allowToolUse)
    }

    func deny(_ item: InboundTaskGate.PendingApproval) async {
        await gate.deny(id: item.id)
    }

    // MARK: Token (Keychain-backed; mint once, rotate on demand)

    func regenerateToken() {
        let token = Self.makeToken()
        bearerToken = token
        try? keychain.save(Data(token.utf8), account: Self.tokenAccount)
        // A live listener was authenticated with the OLD token; restart so the new one
        // takes effect immediately rather than silently continuing to accept the old value.
        if isServing { Task { await self.restart() } }
    }

    private func restart() async {
        await stop()
        await start()
    }

    private static func loadOrCreateToken(keychain: KeychainBox) -> String {
        if let data = keychain.load(account: tokenAccount),
            let existing = String(data: data, encoding: .utf8), !existing.isEmpty
        {
            return existing
        }
        let token = makeToken()
        try? keychain.save(Data(token.utf8), account: tokenAccount)
        return token
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Agent card

    static func buildCard(descriptor: HarnessDescriptor, port: Int) -> A2AAgentCard {
        let skill = A2AAgentSkill(
            id: descriptor.id, name: descriptor.displayName,
            description:
                "A tethered coding agent (\(descriptor.displayName)) running on this Mac, reachable over the Eldr Node A2A server.",
            tags: ["coding-agent", "eldr"])
        return A2AAgentCard(
            name: "Eldr Node — \(descriptor.displayName)",
            description:
                "A tethered coding agent exposed over Agent2Agent (A2A). This Mac runs \(descriptor.displayName) and answers tasks submitted to this local endpoint; every task requires explicit operator approval on this Mac before it runs.",
            supportedInterfaces: [
                A2AAgentInterface(
                    url: "http://127.0.0.1:\(port)/a2a",
                    protocolBinding: A2AAgentInterface.jsonRPCBinding,
                    protocolVersion: "1.0")
            ],
            version: appVersion(),
            capabilities: A2AAgentCapabilities(
                streaming: true, pushNotifications: false, extendedAgentCard: false),
            defaultInputModes: ["text/plain"], defaultOutputModes: ["text/plain"],
            skills: [skill])
    }

    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}

/// Inert default for `A2AServerHost.llmProvider` before the composition root wires the real
/// one — never reached in production (the built-in descriptor's `.builtIn` path is the only
/// caller of `llm`, and `start()` is user-gated), kept only so the default closure type-checks.
struct NullLLMClient: LLMClient {
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        throw LLMError.notConfigured("A2AServerHost.llmProvider was not wired")
    }
}
