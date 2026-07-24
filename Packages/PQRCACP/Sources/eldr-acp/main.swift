// SPDX-License-Identifier: Apache-2.0
import Foundation
#if os(macOS)
import PQRCACP

// EldrChat ACP agent over stdio. An ACP client (Xcode 27) spawns this binary and
// drives it with newline-delimited JSON-RPC on stdin; the agent writes responses
// and streams session/update notifications on stdout. Diagnostics go to stderr so
// they never corrupt the protocol stream.
//
// The BRAIN is a self-hosted OpenAI-compatible LLM (LM Studio / Ollama / vLLM)
// configured via ELDR_LLM_URL / ELDR_LLM_TOKEN / ELDR_LLM_MODEL. Set
// ELDR_ACP_FAKE_LLM=1 to use a built-in echo "LLM" (no server needed) for smoke
// tests. Shell commands honor DEVELOPER_DIR (select Xcode) and ELDR_WORKDIR.

/// Tracks the in-flight per-line Tasks so the process can drain them before exit
/// (piped stdin hits EOF fast; without this the program would exit before the
/// async handlers flush their stdout writes).
actor InFlight {
    private var tasks: [Task<Void, Never>] = []
    func add(_ task: Task<Void, Never>) { tasks.append(task) }
    func drain() async {
        // Snapshot-and-await in waves: awaiting a turn can spawn more reads/tasks.
        while !tasks.isEmpty {
            let wave = tasks
            tasks.removeAll()
            for t in wave { await t.value }
        }
    }
}

@main
struct EldrACPMain {
    static func main() async {
        if CommandLine.arguments.contains("--version") {
            // A4: full version+build line (staleness seam) — Huginn/Xcode read this back
            // and compare it to the version they were built against.
            print(ACPAgent.agentVersionSummary)
            return
        }

        // If the client closes our stdout (it went away mid-write), don't die from
        // SIGPIPE — let the write fail and the read loop hit EOF and exit cleanly.
        signal(SIGPIPE, SIG_IGN)

        let environment = ProcessInfo.processInfo.environment

        // C-6: stderr is an at-rest diagnostic sink — the Configurator launcher tees
        // it to a logfile. Scrub credential-shaped substrings (e.g. a token embedded
        // in ELDR_LLM_URL) before they hit disk. Standalone binary, so it uses the
        // built-in redactor; the in-app path injects PQRCCore's via AgentConfig.
        func log(_ message: String) {
            // Throwing write, not `write(_:)`: if the launcher/tee that holds our
            // stderr dies, the legacy API raises an uncatchable NSException (same
            // broken-pipe crash class as the stdout sink). Diagnostics are best-effort.
            try? FileHandle.standardError.write(
                contentsOf: Data("eldr-acp: \(ACPLogRedactor.scrub(message))\n".utf8))
        }

        // Choose the brain.
        let llm: any LLMClient
        if environment["ELDR_ACP_FAKE_LLM"] == "1" {
            llm = EchoLLMClient()
            log("using built-in echo LLM (ELDR_ACP_FAKE_LLM=1)")
        } else {
            let config = LLMConfig.fromEnvironment(environment)
            llm = OpenAICompatibleLLMClient(config: config)
            log("LLM url=\(config.url) model=\(config.model)")
        }

        // Context-budget / tool / prompt tuning (ELDR_ACP_* env + ~/.config/eldr-acp).
        let config = AgentConfig.fromEnvironment(environment)
        let toolList = config.toolAllowlist.isEmpty ? "all" : config.toolAllowlist.joined(separator: ",")
        log(
            "context budget: maxToolResultBytes=\(config.maxToolResultBytes == Int.max ? "∞" : String(config.maxToolResultBytes)) "
                + "maxHistoryTurns=\(config.maxHistoryTurns) maxContextChars=\(config.maxContextChars) tools=\(toolList)")

        let skillSet = AgentSkillSet.from(config: config)
        let skillList =
            skillSet.isEmpty
            ? "none (disabled)" : skillSet.skills.map { "/\($0.name)" }.joined(separator: " ")
        log("skills: \(skillList)")

        // Streaming on by default; ELDR_ACP_STREAM=0/off/false disables it (echo/tests).
        let streamingEnabled: Bool = {
            switch (environment["ELDR_ACP_STREAM"] ?? "").lowercased() {
            case "0", "off", "false", "no": return false
            default: return true
            }
        }()
        // The turn-level timeout mirrors the LLM's own request timeout.
        let timeoutSeconds = LLMConfig.fromEnvironment(environment).requestTimeoutSeconds
        log("streaming=\(streamingEnabled) request-timeout=\(Int(timeoutSeconds))s")

        let sink = FileHandleOutputSink(FileHandle.standardOutput)
        let connection = ClientConnection(sink: sink)
        let agent = ACPAgent(
            connection: connection,
            llm: llm,
            toolEnvironment: .fromEnvironment(environment),
            config: config,
            configDir: AgentConfig.defaultConfigDir(environment),
            maxIterations: config.maxIterations,
            streamingEnabled: streamingEnabled,
            requestTimeoutSeconds: timeoutSeconds)
        let inFlight = InFlight()

        log("ready on stdio")

        // Read stdin on a DEDICATED queue, NEVER on a Swift-concurrency thread: a
        // blocking `readLine()` on a cooperative thread starves the writer, so the
        // agent's computed response doesn't reach the OS pipe until the NEXT read
        // returns. Against a conformant request/response client (Xcode 27) that
        // deadlocks on the very first `initialize` (the client waits for a reply
        // that won't flush until it sends another line — which it never does). The
        // queue yields lines into an AsyncStream the async main drains, so no
        // blocking read runs on a concurrency thread and each response flushes at once.
        let lines = AsyncStream<String> { continuation in
            let reader = DispatchQueue(label: "chat.pqrc.acp.stdin")
            reader.async {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }

        // CRUCIAL routing: a line that is a RESPONSE to one of our outbound requests
        // (no "method", has "id") goes STRAIGHT to the ClientConnection actor, NOT
        // through the agent — the agent may be awaiting that very response inside
        // session/prompt, so routing it through the agent would deadlock. Each line
        // is handled on its own Task so a long-running prompt turn doesn't block
        // delivery of the responses it awaits; the tasks are drained before exit.
        for await line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let message = JSONValue.parse(trimmed), message["method"] == nil,
                message["id"] != nil
            {
                let task = Task<Void, Never> {
                    _ = await connection.deliver(response: message)
                }
                await inFlight.add(task)
                continue
            }

            let task = Task {
                if let response = await agent.handle(line: trimmed) {
                    await sink.write(line: response)
                }
            }
            await inFlight.add(task)
        }

        // stdin closed — no response can ever arrive now, so fail the waits that
        // depend on one first (an un-timed `session/request_permission` would park
        // its turn forever; `requestPermission` maps the failure to a denial), THEN
        // let outstanding turns finish before we exit. If the client is fully gone
        // their writes no-op against the latched sink.
        await connection.failAll(ClientConnection.ConnectionError.cancelled)
        await inFlight.drain()
        log("stdin closed; exiting")
    }
}
#else
// The ACP agent host drives Process/PTY tools (macOS-only — WS-L4). Linux gets a stub so the
// package builds; the agent host itself is not yet available on a Linux node.
@main
struct EldrACPMain {
    static func main() {
        FileHandle.standardError.write(Data(
            "eldr-acp: the ACP agent host is macOS-only; not available on Linux.\n".utf8))
        exit(1)
    }
}
#endif
