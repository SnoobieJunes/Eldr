// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCACP

// Path-1 §6 end-to-end coverage for ACPClientDriver — the client half of ACP.
//
// Two layers:
//  1. The REAL binary: spawn `eldr-acp` (built as a test dependency) with the echo
//     LLM and drive initialize → session/new → session/prompt, asserting the actual
//     ordered update stream over the real stdio transport.
//  2. ATTACHED in-process: wire the driver to a live `ACPAgent` over a pair of pipes
//     with a scripted MockLLMClient — exercising the driver's full routing (outbound
//     requests, session/update rendering, AND servicing the agent's
//     session/request_permission) without a model server: tool cascade + a denied write.

/// Locates the products directory so the test can spawn the freshly-built `eldr-acp`.
final class BundleToken {}

private var agentBinaryURL: URL {
    if let override = ProcessInfo.processInfo.environment["ELDR_ACP_BIN"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    let dir = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
    return dir.appendingPathComponent("eldr-acp")
}

/// Records the driver's render callbacks for assertions.
private actor DriverRecorder {
    struct Update: Sendable { var status: String; var content: String?; var isError: Bool }
    private(set) var chunks: [String] = []
    private(set) var toolTitles: [String] = []
    private(set) var updates: [Update] = []
    private(set) var commands: [String] = []
    func chunk(_ s: String) { chunks.append(s) }
    func tool(_ title: String) { toolTitles.append(title) }
    func update(_ status: String, _ content: String?, _ isError: Bool) {
        updates.append(Update(status: status, content: content, isError: isError))
    }
    func setCommands(_ names: [String]) { commands = names }
    func chunksSnapshot() -> [String] { chunks }
    func titlesSnapshot() -> [String] { toolTitles }
    func updatesSnapshot() -> [Update] { updates }
    func commandsSnapshot() -> [String] { commands }
}

/// Scripted LLM (records the message lists it saw, returns queued responses).
private actor RecordingMockLLM: LLMClient {
    private var queue: [LLMResponse]
    private(set) var seen: [[LLMMessage]] = []
    init(_ responses: [LLMResponse]) { queue = responses }
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        seen.append(messages)
        return queue.isEmpty ? LLMResponse(content: "(done)") : queue.removeFirst()
    }
    func calls() -> [[LLMMessage]] { seen }
}

/// Splits pipe bytes into newline-delimited lines for the in-process agent pump.
/// `@unchecked Sendable`: only the single readability queue touches `buffer`.
private final class TestLineSplitter: @unchecked Sendable {
    private var buffer = Data()
    func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            lines.append(String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }
}

@Suite("ACPClientDriver E2E")
struct RunnerE2ETests {

    // MARK: Real binary over stdio

    @Test func realBinaryHandshakeAndEchoPrompt() async throws {
        // Hermetic config dir: the binary otherwise reads the operator's live
        // ~/.config/eldr-acp (skills/tools/env files), so their personal settings —
        // e.g. `skills` = 0 — would flip this test's outcome.
        let configDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: configDir) }

        let recorder = DriverRecorder()
        let handler = ACPClientHandler(
            onAgentMessageChunk: { await recorder.chunk($0) },
            onAvailableCommands: { await recorder.setCommands($0) })
        let driver = ACPClientDriver(
            executableURL: agentBinaryURL,
            environmentOverrides: [
                "ELDR_ACP_FAKE_LLM": "1",
                "ELDR_ACP_CONFIG_DIR": configDir,
            ],
            handler: handler)

        let info = try await driver.start(cwd: NSTemporaryDirectory())
        #expect(info.agentName == "eldr-acp")
        #expect(!info.sessionId.isEmpty)
        // Skills are advertised at initialize and/or via session/new's update.
        let advertised = Set(info.availableCommands).union(await recorder.commandsSnapshot())
        #expect(advertised.contains("spec"))

        let stopReason = try await driver.prompt("ping")
        #expect(stopReason == "end_turn")
        // The echo LLM streams back "Echo: <text>" as the answer.
        #expect(await recorder.chunksSnapshot().joined().contains("Echo: ping"))

        await driver.shutdown()
    }

    // MARK: Attached in-process agent (full driver routing, scripted LLM)

    /// Wire the driver to a live ACPAgent over two pipes, mirroring main.swift's
    /// routing of agent-outbound responses vs inbound requests.
    private func attach(
        agent: ACPAgent, connection: ClientConnection, sink: FileHandleOutputSink,
        agentRead: FileHandle
    ) {
        let splitter = TestLineSplitter()
        agentRead.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; return }
            for line in splitter.feed(data) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                Task {
                    if let msg = JSONValue.parse(trimmed), msg["method"] == nil, msg["id"] != nil {
                        await connection.deliver(response: msg)
                    } else if let response = await agent.handle(line: trimmed) {
                        await sink.write(line: response)
                    }
                }
            }
        }
    }

    /// Returns the driver, the agent, and the two pipes — the caller MUST keep the
    /// pipes alive for the test's duration: a `Pipe` deallocating closes its fds, which
    /// would EOF the transport mid-handshake.
    private func makeAttached(
        llm: any LLMClient, workdir: String, handler: ACPClientHandler
    ) -> (ACPClientDriver, ACPAgent, [Pipe]) {
        let agentToClient = Pipe()
        let clientToAgent = Pipe()
        let sink = FileHandleOutputSink(agentToClient.fileHandleForWriting)
        let connection = ClientConnection(sink: sink)
        let agent = ACPAgent(
            connection: connection, llm: llm,
            toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
            config: .default, configDir: nil, streamingEnabled: false)
        attach(
            agent: agent, connection: connection, sink: sink,
            agentRead: clientToAgent.fileHandleForReading)
        let driver = ACPClientDriver(
            input: clientToAgent.fileHandleForWriting,
            output: agentToClient.fileHandleForReading,
            handler: handler)
        return (driver, agent, [agentToClient, clientToAgent])
    }

    @Test func driverDrivesToolCascade() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-drv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filePath = (dir as NSString).appendingPathComponent("data.txt")
        let canary = "canary-\(UUID().uuidString.prefix(8))"
        try String(canary).write(toFile: filePath, atomically: true, encoding: .utf8)

        let llm = RecordingMockLLM([
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "c1", name: "read_file",
                        arguments: "{\"path\":\"\(filePath)\"}")
                ]),
            LLMResponse(content: "I read the file."),
        ])
        let recorder = DriverRecorder()
        let handler = ACPClientHandler(
            onAgentMessageChunk: { await recorder.chunk($0) },
            onToolCall: { _, title, _, _ in await recorder.tool(title) },
            onToolCallUpdate: { _, status, content, isError in
                await recorder.update(status, content, isError)
            })
        let (driver, _, keepAlive) = makeAttached(llm: llm, workdir: dir, handler: handler)
        defer { _ = keepAlive }  // keep the pipes open for the whole test

        _ = try await driver.start(cwd: dir)
        let stopReason = try await driver.prompt("read it")
        #expect(stopReason == "end_turn")
        #expect(await recorder.titlesSnapshot().contains { $0.contains("Read") })
        #expect(await recorder.chunksSnapshot().contains("I read the file."))
        // The completed tool_call_update carried the file's contents.
        #expect(
            await recorder.updatesSnapshot().contains {
                $0.status == "completed" && ($0.content?.contains(String(canary)) ?? false)
            })
        await driver.shutdown()
    }

    @Test func driverDeniesPermissionAndAgentReportsDenial() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-drv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = (dir as NSString).appendingPathComponent("should-not-exist.txt")

        let llm = RecordingMockLLM([
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "w1", name: "write_file",
                        arguments: "{\"path\":\"\(target)\",\"content\":\"nope\"}")
                ]),
            LLMResponse(content: "I could not write the file."),
        ])
        let recorder = DriverRecorder()
        let handler = ACPClientHandler(
            onAgentMessageChunk: { await recorder.chunk($0) },
            onToolCallUpdate: { _, status, content, isError in
                await recorder.update(status, content, isError)
            },
            requestPermission: { _, _ in false })  // deny every mutating tool
        let (driver, _, keepAlive) = makeAttached(llm: llm, workdir: dir, handler: handler)
        defer { _ = keepAlive }  // keep the pipes open for the whole test

        _ = try await driver.start(cwd: dir)
        let stopReason = try await driver.prompt("write a file")
        #expect(stopReason == "end_turn")
        // The write was denied → a failed tool_call_update, and the file never written.
        #expect(await recorder.updatesSnapshot().contains { $0.status == "failed" })
        #expect(!FileManager.default.fileExists(atPath: target))
        // The denial was fed back to the model on its second call.
        let calls = await llm.calls()
        #expect(calls.count == 2)
        #expect(calls[1].contains { $0.role == .tool && $0.content.contains("denied") })
        await driver.shutdown()
    }
}
