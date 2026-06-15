import Foundation
import Testing

@testable import PQRCACP

/// Skills (ACP available-commands / slash-commands): the agent advertises three
/// skills — `/spec`, `/snippet`, `/html` — via an `available_commands_update`
/// session/update and (belt-and-suspenders) in the initialize response, then routes
/// a `/skill …` prompt through that skill's focused system instruction. All checks
/// are network-free: a scripted `MockLLMClient` captures the system message the
/// agent built so we can assert the skill instruction reached the model.
@Suite("Skills")
struct SkillsTests {

    // MARK: Doubles (mirror ACPAgentTests so this file is self-contained)

    actor CapturingSink: OutputSink {
        private(set) var lines: [String] = []
        func write(line: String) async { lines.append(line) }
        func updates() -> [JSONValue] {
            lines.compactMap { JSONValue.parse($0) }
                .filter { $0["method"]?.stringValue == "session/update" }
                .compactMap { $0["params"]?["update"] }
        }
    }

    /// Records the message lists it was given so a test can inspect the system prompt.
    actor RecordingLLM: LLMClient {
        private var queue: [LLMResponse]
        private(set) var seen: [[LLMMessage]] = []
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            seen.append(messages)
            return queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
        func calls() -> [[LLMMessage]] { seen }
    }

    private func makeAgent(config: AgentConfig) -> (ACPAgent, CapturingSink, RecordingLLM) {
        let sink = CapturingSink()
        let connection = ClientConnection(sink: sink)
        let llm = RecordingLLM([LLMResponse(content: "ok")])
        let env = ToolEnvironment(developerDir: nil, workdir: "/tmp", baseEnvironment: [:])
        let agent = ACPAgent(connection: connection, llm: llm, toolEnvironment: env, config: config)
        return (agent, sink, llm)
    }

    private func parse(_ s: String?) throws -> JSONValue {
        let s = try #require(s)
        return try #require(JSONValue.parse(s))
    }

    // MARK: Catalog & config policy

    @Test func defaultSetHasAllThreeBuiltInSkills() {
        let set = AgentSkillSet.from(config: .default)
        #expect(set.skills.map(\.name) == ["spec", "snippet", "html"])
    }

    @Test func disabledConfigYieldsNoSkills() {
        let set = AgentSkillSet.from(config: AgentConfig(skillsEnabled: false))
        #expect(set.isEmpty)
    }

    @Test func allowlistNarrowsToSubsetPreservingCatalogOrder() {
        // Request in a different order than the catalog; advertise order is the catalog's.
        let set = AgentSkillSet.from(
            config: AgentConfig(skillAllowlist: ["html", "spec"]))
        #expect(set.skills.map(\.name) == ["spec", "html"])
    }

    @Test func availableCommandJSONHasNameDescriptionHint() {
        let json = AgentSkillSet.createSpec.availableCommandJSON
        #expect(json["name"]?.stringValue == "spec")
        #expect(json["description"]?.stringValue?.isEmpty == false)
        #expect(json["input"]?["hint"]?.stringValue?.isEmpty == false)
    }

    // MARK: ELDR_ACP_SKILLS parsing (boolean OR name list)

    @Test func skillsEnvParsesBooleansAndLists() {
        #expect(AgentConfig.parseSkills(nil).0 == true)
        #expect(AgentConfig.parseSkills(nil).1 == nil)
        #expect(AgentConfig.parseSkills("0").0 == false)
        #expect(AgentConfig.parseSkills("off").0 == false)
        #expect(AgentConfig.parseSkills("false").0 == false)
        #expect(AgentConfig.parseSkills("none").0 == false)
        #expect(AgentConfig.parseSkills("1") == (true, nil))
        #expect(AgentConfig.parseSkills("all") == (true, nil))
        let list = AgentConfig.parseSkills("spec, html")
        #expect(list.0 == true)
        #expect(list.1 == ["spec", "html"])
    }

    @Test func configFromEnvironmentHonorsSkillsToggle() {
        let off = AgentConfig.fromEnvironment(["ELDR_ACP_SKILLS": "off"], configDir: nil)
        #expect(off.skillsEnabled == false)
        let subset = AgentConfig.fromEnvironment(["ELDR_ACP_SKILLS": "spec html"], configDir: nil)
        #expect(subset.skillsEnabled == true)
        #expect(subset.skillAllowlist == ["spec", "html"])
        let defaulted = AgentConfig.fromEnvironment([:], configDir: nil)
        #expect(defaulted.skillsEnabled == true)
        #expect(defaulted.skillAllowlist == nil)
    }

    // MARK: Invocation parsing

    @Test func invocationParsesLeadingSlashCommand() {
        let set = AgentSkillSet.from(config: .default)
        let inv = set.invocation(for: "/spec a REST API for todos")
        #expect(inv?.skill.name == "spec")
        #expect(inv?.argument == "a REST API for todos")
    }

    @Test func bareCommandHasEmptyArgument() {
        let set = AgentSkillSet.from(config: .default)
        #expect(set.invocation(for: "/html")?.argument == "")
    }

    @Test func unknownCommandAndPlainTextAreNotInvocations() {
        let set = AgentSkillSet.from(config: .default)
        #expect(set.invocation(for: "/unknown do a thing") == nil)
        #expect(set.invocation(for: "just write some code") == nil)
        // A leading slash that is a path, not a known skill, is not an invocation.
        #expect(set.invocation(for: "/Users/x/file.swift") == nil)
    }

    @Test func disabledSetMatchesNothing() {
        let set = AgentSkillSet.from(config: AgentConfig(skillsEnabled: false))
        #expect(set.invocation(for: "/spec anything") == nil)
    }

    // MARK: Advertisement — available_commands_update after session/new

    @Test func sessionNew_advertisesAvailableCommandsUpdate() async throws {
        let (agent, sink, _) = makeAgent(config: .default)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#)

        let updates = await sink.updates()
        let adv = try #require(
            updates.first { $0["sessionUpdate"]?.stringValue == "available_commands_update" })
        let names = adv["availableCommands"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["spec", "snippet", "html"])
        // Shape: each has a description and an input hint.
        let first = try #require(adv["availableCommands"]?.arrayValue?.first)
        #expect(first["description"]?.stringValue?.isEmpty == false)
        #expect(first["input"]?["hint"]?.stringValue?.isEmpty == false)
    }

    @Test func sessionNew_withSkillsDisabled_advertisesNothing() async throws {
        let (agent, sink, _) = makeAgent(config: AgentConfig(skillsEnabled: false))
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#)
        let updates = await sink.updates()
        #expect(!updates.contains { $0["sessionUpdate"]?.stringValue == "available_commands_update" })
    }

    // MARK: Advertisement — initialize response also lists commands

    @Test func initialize_alsoListsAvailableCommands() async throws {
        let (agent, _, _) = makeAgent(config: .default)
        let response = try parse(
            await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#))
        let cmds = response["result"]?["agentCapabilities"]?["availableCommands"]?.arrayValue
        #expect(cmds?.compactMap { $0["name"]?.stringValue } == ["spec", "snippet", "html"])
    }

    @Test func initialize_withSkillsDisabled_omitsAvailableCommands() async throws {
        let (agent, _, _) = makeAgent(config: AgentConfig(skillsEnabled: false))
        let response = try parse(
            await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#))
        #expect(response["result"]?["agentCapabilities"]?["availableCommands"] == nil)
    }

    // MARK: Execution — a /skill prompt injects the skill's system instruction

    @Test func specSkillInjectsMarkdownInstructionAndStripsPrefix() async throws {
        let (agent, _, llm) = makeAgent(config: .default)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)

        let resp = try parse(
            await agent.handle(
                line:
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"/spec a todo API\"}]}}"
            ))
        #expect(resp["result"]?["stopReason"]?.stringValue == "end_turn")

        let calls = await llm.calls()
        let firstCall = try #require(calls.first)
        let system = try #require(firstCall.first { $0.role == .system })
        // The spec skill's instruction is present (Markdown spec writer).
        #expect(system.content.contains("Markdown specification"))
        #expect(system.content.contains("Skill: /spec"))
        // The base prompt facts are still present (cwd / tools), so the model keeps them.
        #expect(system.content.contains("/tmp"))
        // The user message is the ARGUMENT, prefix stripped.
        let user = try #require(firstCall.first { $0.role == .user })
        #expect(user.content == "a todo API")
    }

    @Test func htmlSkillInjectsSelfContainedHTMLInstruction() async throws {
        let (agent, _, llm) = makeAgent(config: .default)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"/html a bar chart of sales\"}]}}"
        )
        let system = try #require(
            (await llm.calls()).first?.first { $0.role == .system })
        #expect(system.content.contains("self-contained HTML"))
        #expect(system.content.contains("<!DOCTYPE html>"))
        // {cwd} in the skill instruction is substituted with the session cwd.
        #expect(!system.content.contains("{cwd}"))
    }

    @Test func plainPromptUsesBaseSystemPromptWithoutSkillInstruction() async throws {
        let (agent, _, llm) = makeAgent(config: .default)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"just say hi\"}]}}"
        )
        let system = try #require((await llm.calls()).first?.first { $0.role == .system })
        #expect(!system.content.contains("Skill: /"))
        let user = try #require((await llm.calls()).first?.first { $0.role == .user })
        #expect(user.content == "just say hi")
    }

    // MARK: systemPrompt composition (unit-level)

    @Test func systemPromptAppendsSkillAfterBaseAndOverride() {
        // Built-in base + skill.
        let p1 = ACPAgent.systemPrompt(cwd: "/work", config: .default, skill: AgentSkillSet.generateSnippet)
        #expect(p1.contains("EldrChat's coding agent"))  // base
        #expect(p1.contains("Skill: /snippet"))
        #expect(p1.contains("runnable code snippet"))

        // A full system-prompt override still gets the skill appended.
        let overridden = AgentConfig(systemPromptOverride: "BASE-OVERRIDE for {cwd}")
        let p2 = ACPAgent.systemPrompt(cwd: "/work", config: overridden, skill: AgentSkillSet.visualizeHTML)
        #expect(p2.contains("BASE-OVERRIDE for /work"))
        #expect(p2.contains("Skill: /html"))
    }
}
