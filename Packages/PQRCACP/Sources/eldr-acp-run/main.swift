// SPDX-License-Identifier: Apache-2.0
import Foundation
#if os(macOS) || os(Linux)
import PQRCACP
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux (pingLLM)
#endif
#if canImport(Glibc)
import Glibc  // signal/SIGINT
#endif

// `eldr-acp-run` — a terminal ACP CLIENT that drives the real `eldr-acp` agent so you
// can run and test it by hand against real LM Studio and real files. It's a thin UX
// layer over `ACPClientDriver` (the reusable client core the PQRC bridge also uses):
// it spawns the agent, prints the resolved LLM config, pings the endpoint, then runs
// a REPL — type a task, watch the tool calls and the streamed answer, approve writes
// (or pass `--yes` to auto-approve), `:quit` to exit, Ctrl-C to cancel the live turn.
//
// Usage: eldr-acp-run [--dir <path>] [--yes]
//   --dir <path>   working directory for the agent (default: current directory)
//   --yes          auto-approve every permission request (non-interactive)
// LLM config comes from ELDR_LLM_URL / ELDR_LLM_TOKEN / ELDR_LLM_MODEL (see
// run-agent.sh for the LM-Studio defaults).

struct Options {
    var workdir: String
    var autoApprove: Bool
}

func parseOptions(_ arguments: [String], cwd: String) -> Options {
    var workdir = cwd
    var autoApprove = false
    var i = 1
    while i < arguments.count {
        switch arguments[i] {
        case "--dir":
            if i + 1 < arguments.count {
                workdir = (arguments[i + 1] as NSString).expandingTildeInPath
                i += 1
            }
        case "--yes", "-y":
            autoApprove = true
        default:
            break
        }
        i += 1
    }
    return Options(workdir: workdir, autoApprove: autoApprove)
}

/// Locate the `eldr-acp` agent binary: an explicit `ELDR_ACP_BIN`, else a sibling of
/// this runner (they're built into the same directory), else bare `eldr-acp` on PATH.
func resolveAgentBinary(_ environment: [String: String]) -> URL {
    if let override = environment["ELDR_ACP_BIN"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    let runner = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let sibling = runner.deletingLastPathComponent().appendingPathComponent("eldr-acp")
    if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
    return sibling
}

/// Best-effort reachability check of the LLM server (the OpenAI `/models` endpoint),
/// so a misconfigured URL is obvious before the first prompt rather than 120s later.
func pingLLM(_ config: LLMConfig) async -> String {
    var base = config.url.trimmingCharacters(in: .whitespaces)
    while base.hasSuffix("/") { base.removeLast() }
    if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
    let modelsURL = base.hasSuffix("/v1") ? base + "/models" : base + "/v1/models"
    guard let url = URL(string: modelsURL) else { return "unknown (bad URL)" }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    if !config.token.isEmpty {
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    }
    do {
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        if let http = response as? HTTPURLResponse {
            return (200..<400).contains(http.statusCode) ? "reachable" : "HTTP \(http.statusCode)"
        }
        return "reachable"
    } catch {
        return "UNREACHABLE (\(error.localizedDescription))"
    }
}

// Throwing writes: piping the runner into `head`/a dead pager must not abort it
// with the uncatchable NSException the legacy `write(_:)` raises on EPIPE.
func out(_ s: String) { try? FileHandle.standardOutput.write(contentsOf: Data((s + "\n").utf8)) }
func outInline(_ s: String) { try? FileHandle.standardOutput.write(contentsOf: Data(s.utf8)) }

@main
struct EldrACPRun {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let cwd = FileManager.default.currentDirectoryPath
        let options = parseOptions(CommandLine.arguments, cwd: cwd)
        let llmConfig = LLMConfig.fromEnvironment(environment)
        let usingFakeLLM = environment["ELDR_ACP_FAKE_LLM"] == "1"

        out("eldr-acp-run — terminal ACP client")
        out("  workdir: \(options.workdir)")
        if usingFakeLLM {
            out("  LLM: built-in echo (ELDR_ACP_FAKE_LLM=1)")
        } else {
            out("  LLM url=\(llmConfig.url) model=\(llmConfig.model) timeout=\(Int(llmConfig.requestTimeoutSeconds))s")
            let status = await pingLLM(llmConfig)
            out("  endpoint: \(status)")
        }
        out(options.autoApprove ? "  permissions: auto-approve (--yes)" : "  permissions: ask")

        // Track in-flight tool calls so the streamed answer is separated cleanly.
        let renderer = Renderer(autoApprove: options.autoApprove)
        let handler = ACPClientHandler(
            onAgentMessageChunk: { text in await renderer.agentChunk(text) },
            onToolCall: { _, title, kind, _ in await renderer.toolCall(title: title, kind: kind) },
            onToolCallUpdate: { _, status, content, isError in
                await renderer.toolUpdate(status: status, content: content, isError: isError)
            },
            onAvailableCommands: { names in
                if !names.isEmpty { out("  skills: \(names.map { "/\($0)" }.joined(separator: " "))") }
            },
            requestPermission: { title, kind in await renderer.permission(title: title, kind: kind) }
        )

        let driver = ACPClientDriver(
            executableURL: resolveAgentBinary(environment),
            handler: handler)

        do {
            let info = try await driver.start(cwd: options.workdir)
            out("  agent: \(info.agentName ?? "?") \(info.agentVersion ?? "")  session: \(info.sessionId)")
        } catch {
            out("Failed to start eldr-acp: \(error)")
            return
        }

        // Ctrl-C cancels the in-flight turn (first press) and exits if pressed idle.
        let turnFlag = TurnFlag()
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            Task {
                if await turnFlag.isRunning {
                    out("\n^C — cancelling the current turn…")
                    await driver.cancel()
                } else {
                    out("\nBye.")
                    await driver.shutdown()
                    exit(0)
                }
            }
        }
        sigint.resume()

        out("\nReady. Type a task (:quit to exit).")
        while true {
            outInline("\n› ")
            guard let line = readLine(strippingNewline: true) else { break }  // EOF (Ctrl-D)
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if text == ":quit" || text == ":q" { break }

            await turnFlag.start()
            await renderer.beginTurn()
            do {
                let stopReason = try await driver.prompt(text)
                await renderer.endTurn(stopReason: stopReason)
            } catch {
                out("\n[error: \(error)]")
            }
            await turnFlag.finish()
        }

        await driver.shutdown()
        out("Bye.")
    }
}

/// Serializes terminal rendering of the streamed answer + tool lifecycle, and owns
/// the interactive permission prompt. An actor so the driver's concurrent callbacks
/// never interleave half-lines on the terminal.
actor Renderer {
    private let autoApprove: Bool
    private var streamedAnything = false
    init(autoApprove: Bool) { self.autoApprove = autoApprove }

    func beginTurn() { streamedAnything = false }

    func agentChunk(_ text: String) {
        if !streamedAnything { outInline("\n"); streamedAnything = true }
        outInline(text)
    }

    func toolCall(title: String, kind: String) {
        let glyph = kind == "execute" ? "▶" : (kind == "edit" ? "✎" : "·")
        out("\n  \(glyph) \(title)")
    }

    func toolUpdate(status: String, content: String?, isError: Bool) {
        guard status == "completed" || status == "failed" else { return }
        let mark = isError ? "✗" : "✓"
        if let content, !content.isEmpty {
            let oneLine = content.split(separator: "\n").first.map(String.init) ?? content
            let clipped = oneLine.count > 200 ? String(oneLine.prefix(200)) + "…" : oneLine
            out("    \(mark) \(clipped)")
        } else {
            out("    \(mark) \(status)")
        }
    }

    func permission(title: String, kind: String) -> Bool {
        if autoApprove {
            out("\n  [auto-approve] \(title)")
            return true
        }
        outInline("\n  Allow “\(title)”? [y/N] ")
        let answer = readLine(strippingNewline: true)?.lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }

    func endTurn(stopReason: String) {
        if streamedAnything { outInline("\n") }
        if stopReason != "end_turn" { out("[\(stopReason)]") }
    }
}

/// Tracks whether a turn is in flight (so Ctrl-C cancels vs. exits).
actor TurnFlag {
    private(set) var isRunning = false
    func start() { isRunning = true }
    func finish() { isRunning = false }
}
#else
// WS-L4 made the terminal ACP client run on macOS AND Linux; this stub now covers only
// platforms with neither (nothing real builds this target there).
@main
struct EldrACPRun {
    static func main() {
        FileHandle.standardError.write(Data(
            "eldr-acp-run: the terminal ACP client requires macOS or Linux.\n".utf8))
        exit(1)
    }
}
#endif
