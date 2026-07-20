// SPDX-License-Identifier: Apache-2.0
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

    /// Regression: a `maxTurns` suffix boundary that lands BETWEEN an assistant
    /// tool_call and its `tool` result must not leave a leading orphaned `tool`
    /// message — the OpenAI shape rejects a `tool` message that doesn't follow a
    /// preceding `tool_calls`, which 400s the model mid-loop.
    @Test func oddTurnCapNeverOrphansLeadingToolResult() {
        // 5 tool round-trips = 10 tail messages [a0,t0,…,a4,t4]. An ODD cap (3) would
        // suffix to [t3,a4,t4] — a leading orphan. The trim must drop that t3.
        let trimmed = ContextBudget.trim(msgs(turns: 5), maxTurns: 3, maxChars: 0)
        // Every `tool` message must immediately follow an assistant with tool_calls
        // (here our test assistants carry no toolCalls array, so we assert the
        // weaker, sufficient invariant: the kept window never STARTS with a tool).
        let firstNonAnchor = trimmed.dropFirst(2).first  // after system + task
        #expect(firstNonAnchor?.role != .tool)
        // Anchors still present.
        #expect(trimmed.first?.role == .system)
        #expect(trimmed.contains { $0.role == .user && $0.content == "TASK" })
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

// A2 — tool-result aging/stubbing in ContextBudget.trim (keep last N verbatim, stub
// older ones to one line) that runs BEFORE whole-message drops.
@Suite("ContextBudget tool-result aging")
struct ContextBudgetAgingTests {
    private func msgs(toolResults: Int) -> [LLMMessage] {
        var m: [LLMMessage] = [
            LLMMessage(role: .system, content: "SYS"),
            LLMMessage(role: .user, content: "TASK"),
        ]
        for i in 0..<toolResults {
            m.append(LLMMessage(role: .assistant, content: "assistant \(i)"))
            m.append(
                LLMMessage(
                    role: .tool, content: "TOOL-BODY-\(i)-" + String(repeating: "x", count: 200),
                    toolCallId: "c\(i)"))
        }
        return m
    }

    @Test func stubsOlderKeepsLastNVerbatim() {
        // 10 tool results, keep last 4 verbatim; no turn/char drops so we see aging alone.
        let trimmed = ContextBudget.trim(
            msgs(toolResults: 10), maxTurns: 0, maxChars: 0, keepRecentToolResults: 4)
        // Message count is preserved — aging elides bodies, never drops messages.
        #expect(trimmed.count == msgs(toolResults: 10).count)

        let toolMsgs = trimmed.filter { $0.role == .tool }
        #expect(toolMsgs.count == 10)
        // The first 6 are stubbed…
        for old in toolMsgs.prefix(6) {
            #expect(old.content.hasPrefix(ContextBudget.toolStubPrefix))
        }
        // …the last 4 are verbatim (still carry their original body + call id).
        for (offset, recent) in toolMsgs.suffix(4).enumerated() {
            let i = 6 + offset
            #expect(recent.content.contains("TOOL-BODY-\(i)-"))
            #expect(recent.toolCallId == "c\(i)")
        }
    }

    @Test func agingRunsBeforeWholeMessageDrops_andShrinksTotal() {
        let full = msgs(toolResults: 8)
        let aged = ContextBudget.trim(full, maxTurns: 0, maxChars: 0, keepRecentToolResults: 4)
        // Aging alone (no drops) must reduce the total char count vs the untrimmed list.
        #expect(ContextBudget.totalChars(aged) < ContextBudget.totalChars(full))
        // Anchors are never stubbed.
        #expect(aged[0].content == "SYS")
        #expect(aged[1].content == "TASK")
        // Every stubbed message keeps its `tool` envelope so tool_call/tool pairing holds.
        for m in aged where m.content.hasPrefix(ContextBudget.toolStubPrefix) {
            #expect(m.role == .tool)
            #expect(m.toolCallId != nil)
        }
    }

    @Test func fewerThanKeepIsNoOp() {
        let full = msgs(toolResults: 3)
        let aged = ContextBudget.trim(full, maxTurns: 0, maxChars: 0, keepRecentToolResults: 4)
        // 3 tool results ≤ keep 4 → nothing stubbed.
        #expect(!aged.contains { $0.content.hasPrefix(ContextBudget.toolStubPrefix) })
    }

    @Test func keepZeroStubsAllButCurrentBatch() {
        // trim runs BEFORE the model call that consumes the trailing batch, so even
        // keep=0 must leave the newest (not-yet-read) tool result verbatim.
        let aged = ContextBudget.trim(
            msgs(toolResults: 5), maxTurns: 0, maxChars: 0, keepRecentToolResults: 0)
        let toolMsgs = aged.filter { $0.role == .tool }
        for old in toolMsgs.prefix(4) {
            #expect(old.content.hasPrefix(ContextBudget.toolStubPrefix))
        }
        #expect(toolMsgs.last?.content.contains("TOOL-BODY-4-") == true)
    }

    @Test func currentBatchNeverStubbedEvenWhenBiggerThanKeep() {
        // Three earlier single-result turns, then ONE assistant turn with a 6-result
        // batch the model has not seen yet. keep=2 < batch size: the whole trailing
        // batch stays verbatim (stubbing an unread result would make the model re-run
        // tools it just ran); the 3 earlier results age out.
        var m: [LLMMessage] = [
            LLMMessage(role: .system, content: "SYS"),
            LLMMessage(role: .user, content: "TASK"),
        ]
        for i in 0..<3 {
            m.append(LLMMessage(role: .assistant, content: "assistant \(i)"))
            m.append(LLMMessage(role: .tool, content: "OLD-BODY-\(i)", toolCallId: "old\(i)"))
        }
        m.append(LLMMessage(role: .assistant, content: "batch turn"))
        for i in 0..<6 {
            m.append(LLMMessage(role: .tool, content: "BATCH-BODY-\(i)", toolCallId: "b\(i)"))
        }

        let aged = ContextBudget.trim(m, maxTurns: 0, maxChars: 0, keepRecentToolResults: 2)
        let toolMsgs = aged.filter { $0.role == .tool }
        #expect(toolMsgs.count == 9)
        for old in toolMsgs.prefix(3) {
            #expect(old.content.hasPrefix(ContextBudget.toolStubPrefix))
        }
        for (i, fresh) in toolMsgs.suffix(6).enumerated() {
            #expect(fresh.content == "BATCH-BODY-\(i)")
        }
    }
}

// A2 — spill-to-file: an oversized tool result is written WHOLE to a jail-inside file
// (`<workdir>/.eldr/tool-results/`) and the model gets head+tail plus that path.
@Suite("ToolExecutor spill-to-file")
struct ToolExecutorSpillTests {
    private func freshWorkdir() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-spill-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func oversizedReadSpillsFullResultInsideJail() async throws {
        let workdir = freshWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let bigPath = (workdir as NSString).appendingPathComponent("big.txt")
        let body =
            "HEAD_MARKER\n" + String(repeating: "Z", count: 50_000) + "\nTAIL_MARKER"
        try Data(body.utf8).write(to: URL(fileURLWithPath: bigPath))

        let ex = ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: workdir),
            connection: nil, sessionId: "s1", maxResultBytes: 4096, spillOversizedResults: true)
        let read = await ex.run(tool: "read_file", args: .object(["path": .string("big.txt")]))

        #expect(!read.isError)
        // The message carries head+tail signal + the elision marker + the spill path.
        #expect(read.text.contains("HEAD_MARKER"))
        #expect(read.text.contains("TAIL_MARKER"))
        #expect(read.text.contains("bytes elided"))
        #expect(read.text.contains(ToolExecutor.spillDirRelative))
        // …and still fits the budget (the spill note's bytes are reserved out of it).
        #expect(read.text.utf8.count <= 4096)

        // A file landed under <workdir>/.eldr/tool-results/ and holds the FULL result.
        let spillDir = (workdir as NSString).appendingPathComponent(ToolExecutor.spillDirRelative)
        let entries = try FileManager.default.contentsOfDirectory(atPath: spillDir)
        #expect(entries.count == 1)
        let spilled = try String(
            contentsOfFile: (spillDir as NSString).appendingPathComponent(entries[0]),
            encoding: .utf8)
        #expect(spilled == body)

        // The advertised relative path is real: read_file can page it back.
        let rel = try #require(
            read.text.split(separator: "\n").first { $0.contains(ToolExecutor.spillDirRelative) })
        // Extract the `.eldr/tool-results/...txt` token from the note.
        let token = String(rel).components(separatedBy: " ").first {
            $0.contains(ToolExecutor.spillDirRelative)
        }
        let relPath = try #require(token)
        let paged = await ex.run(tool: "read_file", args: .object(["path": .string(relPath)]))
        #expect(paged.text.contains("HEAD_MARKER"))
    }

    @Test func spillDisabledByDefault_onlyTruncates() async throws {
        let workdir = freshWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let bigPath = (workdir as NSString).appendingPathComponent("big.txt")
        try Data(String(repeating: "Z", count: 50_000).utf8).write(
            to: URL(fileURLWithPath: bigPath))

        // Default init: spillOversizedResults defaults to false (bare executor).
        let ex = ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: workdir),
            connection: nil, sessionId: "s1", maxResultBytes: 4096)
        let read = await ex.run(tool: "read_file", args: .object(["path": .string("big.txt")]))

        #expect(read.text.contains("bytes elided"))
        #expect(!read.text.contains(ToolExecutor.spillDirRelative))
        // No spill directory was created.
        let spillDir = (workdir as NSString).appendingPathComponent(ToolExecutor.spillDirRelative)
        #expect(!FileManager.default.fileExists(atPath: spillDir))
    }

    @Test func underBudgetNeverSpills() async throws {
        let workdir = freshWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let path = (workdir as NSString).appendingPathComponent("small.txt")
        try Data("hello".utf8).write(to: URL(fileURLWithPath: path))

        let ex = ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: workdir),
            connection: nil, sessionId: "s1", maxResultBytes: 4096, spillOversizedResults: true)
        let read = await ex.run(tool: "read_file", args: .object(["path": .string("small.txt")]))
        #expect(read.text == "hello")
        let spillDir = (workdir as NSString).appendingPathComponent(ToolExecutor.spillDirRelative)
        #expect(!FileManager.default.fileExists(atPath: spillDir))
    }
}

// A2 — the two new AgentConfig knobs (verbatim-keep count, spill toggle).
@Suite("AgentConfig tool-result knobs")
struct AgentConfigToolResultKnobTests {
    @Test func defaults() {
        let c = AgentConfig.fromEnvironment([:], configDir: nil)
        #expect(c.toolResultKeepVerbatim == 4)
        #expect(c.toolResultSpillEnabled == true)
    }

    @Test func envOverrides() {
        let c = AgentConfig.fromEnvironment(
            [
                "ELDR_ACP_TOOL_RESULT_KEEP": "2",
                "ELDR_ACP_TOOL_RESULT_SPILL": "0",
            ], configDir: nil)
        #expect(c.toolResultKeepVerbatim == 2)
        #expect(c.toolResultSpillEnabled == false)
    }

    @Test func negativeKeepClampsToZero() {
        let c = AgentConfig(toolResultKeepVerbatim: -5)
        #expect(c.toolResultKeepVerbatim == 0)
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
