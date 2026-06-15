import Foundation
import Testing

@testable import PQRCACP

// Network-free coverage for the context-budgeting, tool-allowlist, and config
// parsing added to keep the agent usable across varied local models without
// flooding the context window. Pure string/struct math — no LLM, no I/O beyond a
// temp config file.

@Suite("ContextBudget.truncate")
struct ContextBudgetTruncateTests {
    @Test func shortInputUnchanged() {
        let s = "small result"
        #expect(ContextBudget.truncate(s, maxBytes: 8 * 1024) == s)
    }

    @Test func zeroOrMaxBudgetIsNoOp() {
        let s = String(repeating: "x", count: 5000)
        #expect(ContextBudget.truncate(s, maxBytes: 0) == s)
        #expect(ContextBudget.truncate(s, maxBytes: Int.max) == s)
    }

    @Test func oversizedIsTruncatedWithMarkerAndFitsBudget() {
        let s = String(repeating: "A", count: 10_000)
        let out = ContextBudget.truncate(s, maxBytes: 1024)
        #expect(out.count < s.count)
        #expect(out.contains("bytes elided"))
        // The marker advertises the knob so a user knows how to raise it.
        #expect(out.contains("ELDR_ACP_MAX_TOOL_RESULT_BYTES"))
        // Result stays within the requested budget.
        #expect(out.utf8.count <= 1024)
    }

    @Test func keepsHeadAndTailSignal() {
        // Head carries "FIRST", tail carries "LAST"; middle is filler to force a cut.
        let s = "FIRST_LINE\n" + String(repeating: "m", count: 20_000) + "\nLAST_LINE"
        let out = ContextBudget.truncate(s, maxBytes: 2048)
        #expect(out.contains("FIRST_LINE"))
        #expect(out.contains("LAST_LINE"))
    }

    @Test func multibyteStaysValidUTF8() {
        // Emoji are 4 UTF-8 bytes each; a byte budget that lands mid-character must
        // not split one — output must round-trip as valid UTF-8.
        let s = String(repeating: "😀", count: 4000)  // 16 KB of UTF-8
        let out = ContextBudget.truncate(s, maxBytes: 1000)
        #expect(out.utf8.count <= 1000)
        // Re-encode/decode succeeds (no replacement chars from a split scalar).
        let data = Array(out.utf8)
        #expect(String(decoding: data, as: UTF8.self) == out)
    }

    @Test func prefixSuffixRespectByteBudget() {
        let s = String(repeating: "é", count: 100)  // 2 bytes each → 200 bytes
        #expect(ContextBudget.prefixBytes(s, 10).utf8.count <= 10)
        #expect(ContextBudget.suffixBytes(s, 10).utf8.count <= 10)
        // Whole-character cuts: an odd byte budget rounds DOWN to a full char.
        #expect(ContextBudget.prefixBytes(s, 5).utf8.count == 4)
    }
}

@Suite("ContextBudget.trim")
struct ContextBudgetTrimTests {
    private func msgs(turns: Int) -> [LLMMessage] {
        var m: [LLMMessage] = [
            LLMMessage(role: .system, content: "SYSTEM PROMPT"),
            LLMMessage(role: .user, content: "TASK"),
        ]
        for i in 0..<turns {
            m.append(LLMMessage(role: .assistant, content: "assistant \(i)"))
            m.append(LLMMessage(role: .tool, content: "tool result \(i)", toolCallId: "c\(i)"))
        }
        return m
    }

    @Test func keepsSystemAndTaskAnchors() {
        let trimmed = ContextBudget.trim(msgs(turns: 50), maxTurns: 4, maxChars: 0)
        #expect(trimmed.first?.role == .system)
        #expect(trimmed.first?.content == "SYSTEM PROMPT")
        // The task (first user message) survives even with a tiny turn cap.
        #expect(trimmed.contains { $0.role == .user && $0.content == "TASK" })
    }

    @Test func boundsRecentTurns() {
        // 50 turns → 100 tail messages; cap at 6 keeps system + task + last 6.
        let trimmed = ContextBudget.trim(msgs(turns: 50), maxTurns: 6, maxChars: 0)
        #expect(trimmed.count == 1 /*system*/ + 1 /*task*/ + 6)
        // The most-recent content is what's kept.
        #expect(trimmed.last?.content == "tool result 49")
    }

    @Test func zeroTurnCapMeansNoTurnLimit() {
        let all = msgs(turns: 10)
        let trimmed = ContextBudget.trim(all, maxTurns: 0, maxChars: 0)
        #expect(trimmed.count == all.count)
    }

    @Test func charBudgetElidesOldestNonAnchorContent() {
        // Big old tool results, small anchors; a char cap must elide the OLD content
        // but keep the message envelopes (so tool_call/tool pairing stays valid) and
        // never touch system/task.
        var m: [LLMMessage] = [
            LLMMessage(role: .system, content: "SYS"),
            LLMMessage(role: .user, content: "TASK"),
        ]
        m.append(LLMMessage(role: .tool, content: String(repeating: "O", count: 5000), toolCallId: "old"))
        m.append(LLMMessage(role: .tool, content: String(repeating: "N", count: 100), toolCallId: "new"))

        let trimmed = ContextBudget.trim(m, maxTurns: 0, maxChars: 1000)
        // Same number of messages (we elide content, not drop messages).
        #expect(trimmed.count == m.count)
        // Anchors untouched.
        #expect(trimmed[0].content == "SYS")
        #expect(trimmed[1].content == "TASK")
        // The oldest big result got elided…
        #expect(trimmed[2].content.hasPrefix(ContextBudget.elisionPrefix))
        // …and the whole thing now fits the budget.
        #expect(ContextBudget.totalChars(trimmed) <= 1000)
    }

    @Test func emptyMessagesIsSafe() {
        #expect(ContextBudget.trim([], maxTurns: 4, maxChars: 100).isEmpty)
    }
}

@Suite("AgentConfig parsing")
struct AgentConfigTests {
    @Test func defaultsArePreservingAndSafe() {
        let c = AgentConfig.fromEnvironment([:], configDir: nil)
        #expect(c.maxToolResultBytes == 8 * 1024)
        #expect(c.maxHistoryTurns == 12)
        #expect(c.maxContextChars == 48 * 1024)
        #expect(c.toolAllowlist.isEmpty)
        #expect(c.promptPreamble == nil)
        #expect(c.systemPromptOverride == nil)
    }

    @Test func envOverridesBudgets() {
        let c = AgentConfig.fromEnvironment(
            [
                "ELDR_ACP_MAX_TOOL_RESULT_BYTES": "2048",
                "ELDR_ACP_MAX_HISTORY_TURNS": "4",
                "ELDR_ACP_MAX_CONTEXT_CHARS": "10000",
            ], configDir: nil)
        #expect(c.maxToolResultBytes == 2048)
        #expect(c.maxHistoryTurns == 4)
        #expect(c.maxContextChars == 10000)
    }

    @Test func nonPositiveByteCapBecomesUnbounded() {
        let c = AgentConfig.fromEnvironment(["ELDR_ACP_MAX_TOOL_RESULT_BYTES": "0"], configDir: nil)
        #expect(c.maxToolResultBytes == Int.max)
    }

    @Test func garbageBudgetFallsBackToDefault() {
        let c = AgentConfig.fromEnvironment(["ELDR_ACP_MAX_HISTORY_TURNS": "not-a-number"], configDir: nil)
        #expect(c.maxHistoryTurns == AgentConfig.default.maxHistoryTurns)
    }

    @Test func toolAllowlistParsesCommaAndSpace() {
        let c = AgentConfig.fromEnvironment(
            ["ELDR_ACP_TOOLS": "read_file, write_file run_shell"], configDir: nil)
        #expect(c.toolAllowlist == ["read_file", "write_file", "run_shell"])
    }

    @Test func promptPreambleFromEnv() {
        let c = AgentConfig.fromEnvironment(["ELDR_ACP_PROMPT_PREAMBLE": "Be terse."], configDir: nil)
        #expect(c.promptPreamble == "Be terse.")
    }

    @Test func configDirResolutionPrefersExplicitThenXDGThenHome() {
        #expect(
            AgentConfig.defaultConfigDir(["ELDR_ACP_CONFIG_DIR": "/custom"]) == "/custom")
        #expect(
            AgentConfig.defaultConfigDir(["XDG_CONFIG_HOME": "/x"]) == "/x/eldr-acp")
        #expect(
            AgentConfig.defaultConfigDir(["HOME": "/Users/me"]) == "/Users/me/.config/eldr-acp")
        #expect(AgentConfig.defaultConfigDir([:]) == nil)
    }

    @Test func readsPromptFilesFromConfigDirWhenEnvAbsent() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "  Always run swift build first.  ".data(using: .utf8)!.write(
            to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("prompt-preamble")))
        try "read_file\nrun_shell\n".data(using: .utf8)!.write(
            to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("tools")))

        let c = AgentConfig.fromEnvironment([:], configDir: dir)
        #expect(c.promptPreamble == "Always run swift build first.")  // trimmed
        #expect(c.toolAllowlist == ["read_file", "run_shell"])
    }

    @Test func envWinsOverConfigFile() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "from-file".data(using: .utf8)!.write(
            to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("prompt-preamble")))

        let c = AgentConfig.fromEnvironment(
            ["ELDR_ACP_PROMPT_PREAMBLE": "from-env"], configDir: dir)
        #expect(c.promptPreamble == "from-env")
    }
}

@Suite("Tool allowlist + descriptions")
struct ToolAllowlistTests {
    @Test func emptyAllowlistAdvertisesAllFour() {
        let names = ToolExecutor.toolDefinitions().map(\.name)
        #expect(Set(names) == Set(ToolExecutor.allToolNames))
    }

    @Test func allowlistRestrictsAndPreservesOrder() {
        let defs = ToolExecutor.toolDefinitions(allowlist: ["run_shell", "read_file"])
        // Order follows the canonical advertise order, not the allowlist order.
        #expect(defs.map(\.name) == ["read_file", "run_shell"])
    }

    @Test func unknownAllowlistNamesIgnored() {
        let defs = ToolExecutor.toolDefinitions(allowlist: ["read_file", "bogus_tool"])
        #expect(defs.map(\.name) == ["read_file"])
    }

    @Test func schemasPinRequiredArgsAndForbidExtras() {
        for def in ToolExecutor.toolDefinitions() {
            #expect(def.parameters["type"]?.stringValue == "object")
            #expect(def.parameters["additionalProperties"]?.boolValue == false)
            #expect(def.parameters["properties"] != nil)
        }
        // read_file/write_file/run_shell require their primary arg; list_dir doesn't.
        func required(_ name: String) -> [String] {
            ToolExecutor.toolDefinitions().first { $0.name == name }?
                .parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        #expect(required("read_file") == ["path"])
        #expect(required("write_file").sorted() == ["content", "path"])
        #expect(required("run_shell") == ["command"])
        #expect(required("list_dir").isEmpty)
    }
}

@Suite("ToolExecutor result capping")
struct ToolExecutorCapTests {
    @Test func largeFileReadIsTruncatedForTheModel() async throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("eldr-acp-big-\(UUID().uuidString).txt")
        let big = String(repeating: "Z", count: 50_000)
        try big.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let ex = ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: dir),
            connection: nil, sessionId: "s1", maxResultBytes: 4096)
        let read = await ex.run(tool: "read_file", args: .object(["path": .string(path)]))
        #expect(!read.isError)
        #expect(read.text.utf8.count <= 4096)
        #expect(read.text.contains("bytes elided"))
    }

    @Test func smallReadUncappedWhenUnderBudget() async throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("eldr-acp-sm-\(UUID().uuidString).txt")
        try "hello".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let ex = ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: dir),
            connection: nil, sessionId: "s1", maxResultBytes: 4096)
        let read = await ex.run(tool: "read_file", args: .object(["path": .string(path)]))
        #expect(read.text == "hello")
    }

    @Test func defaultExecutorIsUncapped() async throws {
        // Backward-compat: a ToolExecutor built without maxResultBytes (its old
        // signature) does not truncate — the agent layer is what opts into budgeting.
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("eldr-acp-uncapped-\(UUID().uuidString).txt")
        let body = String(repeating: "Q", count: 20_000)
        try body.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let ex = ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: dir),
            connection: nil, sessionId: "s1")
        let read = await ex.run(tool: "read_file", args: .object(["path": .string(path)]))
        #expect(read.text == body)
    }
}

@Suite("System prompt tuning")
struct SystemPromptTests {
    @Test func defaultMentionsCwdAndOneToolAtATime() {
        let p = ACPAgent.systemPrompt(cwd: "/work/dir")
        #expect(p.contains("/work/dir"))
        #expect(p.contains("ONE tool at a time"))
    }

    @Test func preambleIsAppended() {
        let cfg = AgentConfig(promptPreamble: "MODEL-SPECIFIC RULE")
        let p = ACPAgent.systemPrompt(cwd: "/x", config: cfg)
        #expect(p.contains("EldrChat's coding agent"))  // built-in retained
        #expect(p.contains("MODEL-SPECIFIC RULE"))  // preamble appended
    }

    @Test func overrideReplacesAndSubstitutesCwd() {
        let cfg = AgentConfig(systemPromptOverride: "Custom prompt. CWD={cwd}. Done.")
        let p = ACPAgent.systemPrompt(cwd: "/proj", config: cfg)
        #expect(p == "Custom prompt. CWD=/proj. Done.")
        #expect(!p.contains("EldrChat's coding agent"))  // built-in replaced
    }
}
