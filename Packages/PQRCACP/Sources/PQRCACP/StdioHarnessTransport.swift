// SPDX-License-Identifier: Apache-2.0
import Foundation

// Phase 1 item 1 (the transport-agnostic driver) + the selectable-backend scaffold of
// docs/ACPRouterplan.md: for an EXTERNAL harness the node must SPAWN the harness binary as a
// subprocess and PROXY the phone's ACP line-stream to the harness's stdio. The phone↔node
// transport is one `ACPTransport`; THIS is the other one — an `ACPTransport` whose peer is a
// locally-spawned process's stdin/stdout. With both sides modeled as `ACPTransport`,
// `runACPProxy` pipes between them without knowing either is a process or a radio.
//
// macOS-only: spawning uses `Process`, which is unavailable on iOS — and per the plan the
// node (Mac/server/Pi) hosts harnesses; the phone is always the ACP *client* and never
// spawns one. Same `#if os(macOS)` gating as `runACPAgent` and the `.spawn` path in
// `ACPClientDriver`.

#if os(macOS)
/// An `ACPTransport` backed by a spawned external ACP harness: the child's **stdout →
/// `inboundLines()`** (newline-framed JSON-RPC, identical framing to the agent) and
/// **`send(_:)` → child stdin**; `close()` terminates it. Reuses the
/// `Pipe`/`readabilityHandler`/line-splitter pattern from `ACPClientDriver`'s `.spawn` path.
///
/// Lifecycle: created lazily-startable — `start()` spawns the process and begins reading.
/// `runHarness` calls `start()` then hands the transport to `runACPProxy`. Child exit / a
/// broken pipe FINISH the inbound stream cleanly (the proxy then closes the other side); a
/// write to a dead child is swallowed, never a crash (`SIGPIPE` is ignored process-wide, as
/// the agent/runner already do).
///
/// `@unchecked Sendable`: `ACPTransport` is `Sendable`, but this holds a `Process` and a
/// `FileHandle` (not `Sendable`) plus a continuation set under a lock. All mutable state is
/// guarded by `stateLock`; the continuation is only finished once (idempotent). Justified
/// here rather than an actor because `send(_:)` is a synchronous, non-`async` protocol
/// requirement (it must be callable from inside a JSON-RPC continuation, like the in-memory
/// transport), which an actor can't satisfy without hops.
public final class StdioHarnessTransport: ACPTransport, @unchecked Sendable {
    private let descriptor: HarnessDescriptor

    private let stateLock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var started = false
    private var closed = false
    /// The inbound stream's continuation. The child's stdout lines are yielded here; it is
    /// finished exactly once (on EOF, child exit, or `close()`) — finishing twice is a no-op.
    private var inboundContinuation: AsyncStream<String>.Continuation?
    private let inboundStream: AsyncStream<String>

    public init(descriptor: HarnessDescriptor) {
        self.descriptor = descriptor
        var captured: AsyncStream<String>.Continuation!
        self.inboundStream = AsyncStream<String> { captured = $0 }
        self.inboundContinuation = captured
    }

    /// Errors from spawning a `.stdioSpawn` harness.
    public enum SpawnError: Error, Sendable, Equatable {
        /// The descriptor isn't `.stdioSpawn` (built-in goes through `runACPAgent`, not here).
        case notStdioSpawn
        /// `Process.run()` failed to launch `command` (missing binary, bad permissions, …).
        case launchFailed(String)
    }

    /// Spawn the descriptor's `command`+`args`+`env` and begin reading its stdout into
    /// `inboundLines()`. Idempotent guard: a second call throws. The child's stderr is left
    /// inherited so the harness's own diagnostics surface (same as `ACPClientDriver.spawn`).
    public func start() throws {
        // Validate + claim the started flag under the lock, but DON'T do the spawn or wire the
        // reader inside `withLock`: `startReader`/`finishInbound` also take `stateLock`, and
        // `NSLock` is not reentrant — nesting would self-deadlock the calling thread. So the
        // lock guards only the small bits of mutable state; the Process work runs unlocked
        // (this object isn't started concurrently — the node spawns then hands it to one proxy).
        try stateLock.withLock {
            guard descriptor.kind == .stdioSpawn else { throw SpawnError.notStdioSpawn }
            guard !started else { throw SpawnError.launchFailed("already started") }
            started = true
        }

        // A write to a pipe whose child has exited raises SIGPIPE (kills the process). Ignore
        // it so a broken pipe surfaces as a swallowed write, not a crash — exactly as
        // eldr-acp/main.swift and ACPClientDriver.start() do.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        // Resolve a bare command name (e.g. "codex") on PATH via /usr/bin/env; an absolute or
        // relative path is used directly. The installed launchers are absolute paths.
        if descriptor.command.contains("/") {
            process.executableURL = URL(fileURLWithPath: descriptor.command)
            process.arguments = descriptor.args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [descriptor.command] + descriptor.args
        }
        // Env hygiene: an external harness (e.g. a cloud CLI) must inherit its OWN vendor key
        // (carried in `descriptor.env`) but NEVER the agent's long-term secrets. Scrub the
        // inherited node env of ELDR_/PQRC_/SYBILCLAW_ secrets FIRST, then layer descriptor.env
        // on top — otherwise the spawned harness could read ELDR_LLM_TOKEN / ELDR_ACP_METADATA_KEY
        // / SYBILCLAW_GATEWAY_TOKEN, the same self-exfiltration ToolEnvironment.shellEnvironment
        // guards against for run_shell/open_terminal. Shared scrub so the two seams can't drift.
        var environment = ToolEnvironment.scrubbingAgentSecrets(ProcessInfo.processInfo.environment)
        for (key, value) in descriptor.env { environment[key] = value }
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        // stderr inherited: the harness's diagnostics show, never corrupting the protocol
        // stream (stdout only).

        // Child exit → finish the inbound stream so the proxy closes the other side. Covers a
        // clean exit AND a crash; the EOF read path also finishes it (whichever fires first
        // wins — `finishInbound` is idempotent).
        process.terminationHandler = { [weak self] _ in
            self?.finishInbound()
        }

        do {
            try process.run()
        } catch {
            stateLock.withLock { started = false }
            throw SpawnError.launchFailed(
                "could not launch \(descriptor.command): \(error.localizedDescription)")
        }

        let continuation = stateLock.withLock { () -> AsyncStream<String>.Continuation? in
            self.process = process
            self.stdinHandle = inPipe.fileHandleForWriting
            return inboundContinuation
        }
        // The child could have already exited (terminationHandler may have fired and nilled the
        // continuation); if so, nothing to read.
        guard let continuation else { return }
        startReader(on: outPipe.fileHandleForReading, into: continuation)
    }

    // MARK: - ACPTransport

    public func inboundLines() -> AsyncStream<String> { inboundStream }

    /// Send one JSON-RPC line to the child's stdin (newline-framed). A failed write (child
    /// gone, pipe broken) is swallowed: the EOF/termination path finishes the inbound stream
    /// and the proxy tears down — a write must not crash. Matches `ACPClientDriver.writeLine`.
    public func send(_ line: String) {
        let handle = stateLock.withLock { stdinHandle }
        guard let handle else { return }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Terminate the child, close our stdin, and finish the inbound stream. Idempotent.
    public func close() {
        let (process, handle): (Process?, FileHandle?) = stateLock.withLock {
            guard !closed else { return (nil, nil) }
            closed = true
            let p = self.process
            let h = self.stdinHandle
            self.process = nil
            self.stdinHandle = nil
            return (p, h)
        }
        try? handle?.close()
        if let process, process.isRunning { process.terminate() }
        finishInbound()
    }

    // MARK: - Reader

    /// Stream the child's stdout, splitting on newlines, into the inbound continuation. EOF
    /// (empty read = child closed stdout / exited) finishes the stream — the proxy then closes
    /// the phone side. Mirrors `ACPClientDriver.startReader`. The continuation is passed in
    /// (not re-locked) because the only caller, `start()`, just read it under the lock — and
    /// re-locking here would self-deadlock the non-reentrant `NSLock`.
    private func startReader(on handle: FileHandle, into continuation: AsyncStream<String>.Continuation) {
        let splitter = HarnessLineSplitter()
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {  // EOF: harness closed stdout / exited
                fh.readabilityHandler = nil
                self?.finishInbound()
                return
            }
            for line in splitter.feed(data) { continuation.yield(line) }
        }
    }

    /// Finish the inbound stream exactly once (EOF, termination, or `close()` all funnel here).
    private func finishInbound() {
        let continuation: AsyncStream<String>.Continuation? = stateLock.withLock {
            let c = inboundContinuation
            inboundContinuation = nil
            return c
        }
        continuation?.finish()
    }
}

/// Accumulates raw pipe bytes and yields complete newline-delimited lines, holding any
/// trailing partial until its newline arrives. A local copy of `ACPClientDriver`'s private
/// `LineSplitter` (it's `private` there; duplicating keeps this transport self-contained
/// rather than widening that type's visibility). `@unchecked Sendable` for the same reason: a
/// single `FileHandle.readabilityHandler`, invoked serially on one Foundation queue, is the
/// only caller — no concurrent access to `buffer`.
private final class HarnessLineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }
}
#endif  // os(macOS) — StdioHarnessTransport spawns a Process (node-side only)
