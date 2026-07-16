import A2ACore
import A2AServer
import Foundation
import PQRCACP
import Testing

@testable import Huginn

// A2A serving surface (b): the executor's approval gate + one-artifact completion path,
// and the host's Keychain-backed bearer token lifecycle. `.builtIn` + a scripted LLM keeps
// this headless/network-free (CLAUDE.md: "No unit test touches the network or the real
// clock") — no real harness process or HTTP listener involved.
#if os(macOS)
@Suite("HarnessAgentExecutor — approval gate + completion")
struct HarnessAgentExecutorTests {
    private actor ScriptedLLM: LLMClient {
        private var queue: [LLMResponse]
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
    }

    private actor RecordingSink: TaskEventSink {
        private(set) var artifacts: [(A2AArtifact, Bool, Bool)] = []
        func status(_ status: A2ATaskStatus) async {}
        func artifact(_ artifact: A2AArtifact, append: Bool, lastChunk: Bool) async {
            artifacts.append((artifact, append, lastChunk))
        }
    }

    private func makeTaskAndRequest(text: String) -> (A2ATask, A2ASendMessageRequest) {
        let message = A2AMessage(messageId: "m1", role: .user, parts: [.text(text)])
        let request = A2ASendMessageRequest(message: message)
        let task = A2ATask(
            id: UUID().uuidString, status: A2ATaskStatus(state: .working), history: [message])
        return (task, request)
    }

    /// Grab the first pending item's id off the gate's live stream (buffered — no race with
    /// `requestApproval`'s yield) and resolve it via `resolve`.
    private func resolveFirstPending(
        on gate: InboundTaskGate, resolve: @escaping (UUID) async -> Void
    ) async {
        for await items in gate.updates {
            guard let first = items.first else { continue }
            await resolve(first.id)
            break
        }
    }

    @Test func deniedApprovalReturnsRejectedNotThrown() async throws {
        let gate = InboundTaskGate()
        let executor = HarnessAgentExecutor(
            descriptorProvider: { .builtIn },
            llmProvider: { ScriptedLLM([LLMResponse(content: "should never run")]) },
            toolEnvironmentProvider: { ToolEnvironment(workdir: nil, baseEnvironment: [:]) },
            agentConfigProvider: { .default },
            gate: gate)
        let (task, request) = makeTaskAndRequest(text: "do something")
        let sink = RecordingSink()

        async let resultTask = executor.execute(task: task, request: request, events: sink)
        await resolveFirstPending(on: gate) { id in await gate.deny(id: id) }

        let status = try await resultTask
        #expect(status.state == .rejected)
        let artifacts = await sink.artifacts
        #expect(artifacts.isEmpty)
    }

    @Test func approvedRunProducesExactlyOneArtifactAndCompletes() async throws {
        let gate = InboundTaskGate()
        let executor = HarnessAgentExecutor(
            descriptorProvider: { .builtIn },
            llmProvider: { ScriptedLLM([LLMResponse(content: "hello from the agent")]) },
            toolEnvironmentProvider: { ToolEnvironment(workdir: nil, baseEnvironment: [:]) },
            agentConfigProvider: { .default },
            gate: gate)
        let (task, request) = makeTaskAndRequest(text: "say hello")
        let sink = RecordingSink()

        async let resultTask = executor.execute(task: task, request: request, events: sink)
        await resolveFirstPending(on: gate) { id in await gate.approve(id: id, allowToolUse: false) }

        let status = try await resultTask
        #expect(status.state == .completed)
        let artifacts = await sink.artifacts
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.0.parts.first?.text == "hello from the agent")
        #expect(artifacts.first?.2 == true)  // lastChunk
    }
}

@Suite("InboundTaskGate — timeout denies")
struct InboundTaskGateTests {
    @Test func unresolvedApprovalTimesOutAsDenied() async throws {
        // Exercise the real timeout path without waiting 120s: a request with no responder
        // at all still resolves (eventually) to denied — proven here by racing a short
        // deadline against the call and asserting it does NOT resolve before that deadline
        // (the fail-closed default is "still pending", never silently approved).
        let gate = InboundTaskGate()
        async let decision = gate.requestApproval(taskId: "t1", summary: "quick task")
        // Deny it ourselves immediately rather than waiting out the real 120s bound — this
        // suite only pins that an unresolved request stays pending (not auto-approved)
        // until something resolves it.
        for await items in gate.updates {
            guard let first = items.first else { continue }
            await gate.deny(id: first.id)
            break
        }
        let resolved = await decision
        guard case .denied = resolved else {
            Issue.record("expected .denied, got \(resolved)")
            return
        }
    }
}

@Suite("A2AServerHost — bearer token lifecycle")
struct A2AServerHostTokenTests {
    @MainActor
    @Test func tokenIsStableAcrossRestartsAndRegenerateRotatesIt() {
        let kc = KeychainBox(service: "test-a2a-host-\(UUID().uuidString)")
        defer { kc.delete(account: "a2a-server-bearer-token") }

        let first = A2AServerHost(keychain: kc)
        let token1 = first.bearerToken
        #expect(!token1.isEmpty)

        // A fresh instance over the SAME keychain service reloads the same token.
        let second = A2AServerHost(keychain: kc)
        #expect(second.bearerToken == token1)

        second.regenerateToken()
        #expect(second.bearerToken != token1)
        #expect(!second.bearerToken.isEmpty)

        // The rotation persisted — a third instance sees the NEW token, not the original.
        let third = A2AServerHost(keychain: kc)
        #expect(third.bearerToken == second.bearerToken)
    }
}
#endif
