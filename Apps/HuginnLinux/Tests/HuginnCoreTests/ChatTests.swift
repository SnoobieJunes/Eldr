// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP
import Testing
@testable import HuginnCore

/// First turn: ask to write a file. Second turn: answer in text.
actor ScriptedLLM: LLMClient {
    private var calls = 0
    let path: String
    init(path: String) { self.path = path }
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        calls += 1
        if calls % 2 == 1 {
            let args = JSONValue.object(["path": .string(path), "content": .string("hello from agent\n")]).serialized()
            return LLMResponse(content: "", toolCalls: [LLMToolCall(id: "c\(calls)", name: "write_file", arguments: args)])
        }
        return LLMResponse(content: "done")
    }
}

@Suite("Test Chat drives the real ACPAgent")
struct ChatTests {
    func options(_ dir: String, auto: Bool = false, timeout: Double = 30) -> TestChatSession.Options {
        var agent = AgentConfig.default
        agent.permissionTimeoutSeconds = timeout
        agent.eventsFilePath = nil
        return .init(llm: LLMConfig(url: "", token: "", model: "m"), agent: agent, workdir: dir, autoApprove: auto)
    }

    func waitFor(_ s: TestChatSession, _ cond: @Sendable (TestChatSession) async -> Bool) async -> Bool {
        for _ in 0..<200 { if await cond(s) { return true }; try? await Task.sleep(for: .milliseconds(25)) }
        return false
    }

    @Test("echo brain: user + assistant bubbles")
    func echo() async {
        let tmp = TempDir(); defer { tmp.remove() }
        let s = TestChatSession(options: options(tmp.path), llm: EchoLLMClient())
        await s.send("hi there")
        #expect(await waitFor(s) { await $0.items.count >= 2 })
        let items = await s.items
        #expect(items.first?.role == .user && items.first?.text == "hi there")
        #expect(items.last?.role == .assistant && items.last?.text.contains("Echo: hi there") == true)
        #expect(await s.isResponding == false)
    }

    @Test("mutating tool waits for Approve; approving writes the file")
    func approve() async throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let target = tmp.sub("out.txt")
        let s = TestChatSession(options: options(tmp.path), llm: ScriptedLLM(path: "out.txt"))
        let turn = Task { await s.send("write it") }
        #expect(await waitFor(s) { await !$0.pendingApprovals.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: target))
        let a = try #require(await s.pendingApprovals.first)
        #expect(a.title.contains("out.txt"))
        await s.approve(a)
        await turn.value
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "hello from agent\n")
        let roles = await s.items.map(\.role)
        #expect(roles.contains(.toolCall) && roles.contains(.approvalNote) && roles.contains(.toolResult))
    }

    @Test("deny keeps the file unwritten")
    func deny() async throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let s = TestChatSession(options: options(tmp.path), llm: ScriptedLLM(path: "no.txt"))
        let turn = Task { await s.send("write it") }
        #expect(await waitFor(s) { await !$0.pendingApprovals.isEmpty })
        await s.deny(try #require(await s.pendingApprovals.first))
        await turn.value
        #expect(!FileManager.default.fileExists(atPath: tmp.sub("no.txt")))
        #expect(await s.items.contains { $0.text.hasPrefix("Denied:") })
    }

    @Test("an unanswered request is denied on timeout (fail closed)")
    func timeout() async {
        let tmp = TempDir(); defer { tmp.remove() }
        let s = TestChatSession(options: options(tmp.path, timeout: 0.3), llm: ScriptedLLM(path: "late.txt"))
        await s.send("write it")
        #expect(await waitFor(s) { await $0.items.contains { $0.text.hasPrefix("Timed out — denied") } })
        #expect(!FileManager.default.fileExists(atPath: tmp.sub("late.txt")))
    }

    @Test("auto-approve is visible in the transcript")
    func autoApprove() async {
        let tmp = TempDir(); defer { tmp.remove() }
        let s = TestChatSession(options: options(tmp.path, auto: true), llm: ScriptedLLM(path: "auto.txt"))
        await s.send("write it")
        #expect(FileManager.default.fileExists(atPath: tmp.sub("auto.txt")))
        #expect(await s.items.contains { $0.text.hasPrefix("Auto-approved:") })
    }

    @Test("reset mid-request fails the pending permission; nothing is written")
    func resetMidRequest() async {
        let tmp = TempDir(); defer { tmp.remove() }
        let s = TestChatSession(options: options(tmp.path), llm: ScriptedLLM(path: "torn.txt"))
        let turn = Task { await s.send("write it") }
        #expect(await waitFor(s) { await !$0.pendingApprovals.isEmpty })
        await s.reset()
        await turn.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: tmp.sub("torn.txt")))
        #expect(await s.pendingApprovals.isEmpty)
    }
}
