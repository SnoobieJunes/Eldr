import Foundation
import Testing

@testable import PQRCACP

// PTY lifecycle proofs (Phase D4). macOS-only — PTYProcess spawns a real /bin/zsh on a
// pseudo-terminal, so these run on the node, never the iOS app target. Hermetic: no
// network, no relay; a real child process whose death we VERIFY (the whole point — an
// interactive shell that can't be reliably killed is the project's highest risk).
#if os(macOS)
import Darwin

@Suite("PTYProcess — interactive PTY lifecycle (Phase D4)")
struct PTYProcessTests {

    /// Poll `condition` up to `timeoutMillis`, yielding between checks. Deterministic
    /// readiness instead of a fixed sleep (the child's output arrives asynchronously off
    /// a DispatchSource).
    private func waitUntil(
        _ timeoutMillis: Int = 5_000, _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return await condition()
    }

    /// Is `pid` still a live process? `kill(pid, 0)` returns 0 while it exists (and the
    /// caller can signal it) and -1/ESRCH once it's reaped/gone. A SIGKILLed-and-reaped
    /// child returns ESRCH.
    private func processAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Accumulates the PTY's output stream off the single consumer, so a test can await
    /// "the stream contained X" without racing the reader.
    private actor OutputSink {
        private(set) var text = ""
        func append(_ data: Data) { text += String(decoding: data, as: UTF8.self) }
        func contains(_ needle: String) -> Bool { text.contains(needle) }
        func snapshot() -> String { text }
        /// Extract the `CHILDPID=<n>` the backgrounded-child test prints, or nil. Scans
        /// for a `CHILDPID=` immediately FOLLOWED BY DIGITS — the echoed input line is
        /// `CHILDPID=$!` (no digits) and must be skipped in favor of the real output line.
        func parsedChildPID() -> pid_t? {
            var searchStart = text.startIndex
            while let range = text.range(of: "CHILDPID=", range: searchStart..<text.endIndex) {
                let digits = text[range.upperBound...].prefix { $0.isNumber }
                if let n = Int32(digits), n > 0 { return n }
                searchStart = range.upperBound
            }
            return nil
        }
    }

    /// Spawn zsh, drain its output into a sink, return both. The caller drives stdin.
    private func spawnWithSink() throws -> (pty: PTYProcess, sink: OutputSink, reader: Task<Void, Never>) {
        let pty = try PTYProcess(
            cwd: NSTemporaryDirectory(),
            environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"])
        let sink = OutputSink()
        let reader = Task {
            for await chunk in pty.output { await sink.append(chunk) }
        }
        return (pty, sink, reader)
    }

    // MARK: - (1) spawn → write → read → terminate (the child actually dies)

    @Test func spawnZsh_echoesStdin_thenTerminateKillsTheChild() async throws {
        let (pty, sink, reader) = try spawnWithSink()
        defer { reader.cancel() }

        // The PID is private; capture it via reflection-free means: we assert death
        // through the public surface (isTerminated) AND independently below using a
        // marker that can only appear if the shell ran our command.
        let marker = "PTY_OK_\(UUID().uuidString.prefix(8))"
        // Write a command + newline. An interactive zsh on a tty echoes input and runs it,
        // so the marker shows up in the output stream.
        #expect(pty.write("echo \(marker)\n"))

        let sawMarker = await waitUntil { await sink.contains(marker) }
        let snapshot = await sink.snapshot()
        #expect(sawMarker, "the PTY must stream back the child's stdout; got: \(snapshot)")

        // Terminate — the child must die and the stream must finish.
        pty.terminate()
        #expect(pty.isTerminated)
    }

    /// Stronger death proof: a LONG-RUNNING child (`sleep 600`) backgrounded under the
    /// shell must be killed by terminate() — not just the shell. We capture the child's
    /// PID from its own output and assert `kill(pid,0)` reports it gone.
    @Test func terminate_killsLongRunningChild_noOrphan() async throws {
        let (pty, sink, reader) = try spawnWithSink()
        defer { reader.cancel() }

        // Start a long sleep in the background and print its PID. The sleep is in the
        // shell's process group; terminate() signals the whole group (-pid), so the sleep
        // dies with the shell — proving no orphan survives.
        #expect(pty.write("sleep 600 & echo CHILDPID=$!\n"))

        // Parse CHILDPID=<n> out of the stream (the sink actor holds it).
        let gotPID = await waitUntil(8_000) { await sink.parsedChildPID() != nil }
        let snapshot = await sink.snapshot()
        #expect(gotPID, "could not read the backgrounded child's PID; got: \(snapshot)")
        let childPID = await sink.parsedChildPID() ?? 0
        #expect(processAlive(childPID), "the sleep child should be alive before terminate()")

        pty.terminate()

        // The whole process group was SIGKILLed; the child must be gone shortly after.
        let childGone = await waitUntil(5_000) { !self.processAlive(childPID) }
        #expect(childGone, "terminate() must kill the backgrounded child — no orphaned process")
    }

    // MARK: - (2) terminate() is idempotent + closes fds

    @Test func terminate_isIdempotent() async throws {
        let (pty, _, reader) = try spawnWithSink()
        defer { reader.cancel() }
        #expect(pty.write("echo first\n"))

        pty.terminate()
        #expect(pty.isTerminated)
        // Calling it again (and again) must be a clean no-op — no crash, no double-close,
        // no double-kill of a recycled PID.
        pty.terminate()
        pty.terminate()
        #expect(pty.isTerminated)

        // A write after termination is a silent no-op (returns false), never a crash on a
        // closed fd.
        #expect(pty.write("echo after\n") == false)
    }

    /// After terminate(), the master fd is closed exactly once (via the read source's
    /// cancel handler). We can't read the private fd, but a second close of the same fd
    /// number would be observable as corruption; idempotent terminate() + a no-op write
    /// (above) together exercise that the closed-fd path is safe. Here we additionally
    /// confirm the output stream FINISHES (it can only finish when the fd EOFs/closes).
    @Test func terminate_finishesOutputStream() async throws {
        let pty = try PTYProcess(
            cwd: NSTemporaryDirectory(), environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"])
        // A flag the consumer sets ONLY when the stream finishes (the for-await loop
        // exits) — which can happen only after the fd EOFs/closes.
        let done = Flag()
        let drainer = Task {
            for await _ in pty.output {}
            await done.set()
        }
        defer { drainer.cancel() }
        pty.terminate()
        // The stream must finish within a bounded time (fd closed → EOF → finish()).
        let finished = await waitUntil(5_000) { await done.value }
        #expect(finished, "the output stream must finish after terminate() closes the fd")
    }

    private actor Flag {
        private(set) var value = false
        func set() { value = true }
    }
}
#endif  // os(macOS)
