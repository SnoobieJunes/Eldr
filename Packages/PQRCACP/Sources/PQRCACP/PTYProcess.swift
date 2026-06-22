import Foundation

// NODE-SIDE (macOS only): a pseudo-terminal-backed interactive process — the Phase-D4
// PERSISTENT streaming terminal (REPLs, debuggers, long-running processes), as opposed
// to the one-shot `run_shell` (ToolExecutor). It only ever runs on the Mac node: the
// phone is the remote control that drives a Mac over an `ACPTransport` and never spawns
// a local shell. Guarded off the iOS-compiled library exactly like `ToolExecutor`/
// `ACPAgent`.
//
// THIS TYPE IS THE MECHANISM ONLY — it spawns a shell on a PTY and streams its bytes. It
// owns NONE of the safety policy: the open-ended-interactive-shell GATE (the standing
// `autonomousChangesConsent`, fail-closed without it) lives PHONE-SIDE in
// `PersonaRuntime`, and the node still enforces its own C-1 permission round-trip before
// a PTY is created (`ToolExecutor.openInteractiveTerminal`). What this file guarantees is
// the two LOW-LEVEL safeguards the higher layers depend on:
//   • ALWAYS-KILLABLE: `terminate()` kills the child process group and closes the master
//     fd — idempotent, callable at any time, from any task. The phone's Stop control and
//     the fail-closed teardown both bottom out here.
//   • NO ORPHANS: closing the master fd ends the output stream, and `terminate()` SIGKILLs
//     the whole child process group (not just the shell) so a long-running child can't
//     outlive the session.
#if os(macOS)
import Darwin

/// A `/bin/zsh` (or caller-chosen executable) running on its own pseudo-terminal. Write
/// stdin to it, consume its combined stdout+stderr as an `AsyncStream<Data>`, and
/// `terminate()` to kill the child and close the fds.
///
/// One reader: `output` is a single-consumer `AsyncStream`. A background `DispatchSource`
/// drains the master fd and yields each chunk; EOF (the child closed its side, or we
/// closed ours) finishes the stream.
public final class PTYProcess: @unchecked Sendable {
    // @unchecked Sendable JUSTIFICATION (CLAUDE.md requires a written one; precedent:
    // `LineSplitter` in ACPClientDriver). The only mutable state is `state`, and EVERY
    // access to it goes through `stateLock` (an `NSLock`). The class therefore presents
    // a data-race-free interface across tasks: `write`, `terminate`, and the background
    // read source can all touch it concurrently, but never without the lock. The raw fds
    // and pid are immutable after `spawn`. We use a class (not an actor) deliberately:
    // `terminate()` must be callable synchronously from a fail-closed teardown path
    // (deinit-adjacent, signal-safe `kill`/`close`) without hopping an actor — an actor
    // hop is exactly the kind of await that could be skipped under cancellation and leave
    // an orphaned shell, the #1 risk of this feature.

    /// Spawn failures (distinct so the executor can report a precise reason).
    public enum SpawnError: Error, Sendable, Equatable {
        case openptyFailed(errno: Int32)
        case forkFailed(errno: Int32)
        case execNeverStarted
    }

    private let masterFD: Int32
    private let pid: pid_t
    private let outputContinuation: AsyncStream<Data>.Continuation
    /// Combined stdout+stderr of the child, chunked as it arrives. Single-consumer.
    public let output: AsyncStream<Data>

    /// Guards `state`. An `NSLock` (not an actor) so `terminate()` is synchronous — see
    /// the @unchecked Sendable justification above.
    private let stateLock = NSLock()
    private enum State { case running, terminated }
    private var state: State = .running
    private let readSource: DispatchSourceRead

    /// Spawn `executable` (default `/bin/zsh`, login+interactive) on a fresh PTY in `cwd`
    /// with `environment`. The child runs in its OWN session/process group (`setsid` via
    /// the controlling-terminal setup `openpty` gives us), so `terminate()` can signal the
    /// whole group and a child that forks its own children still gets cleaned up.
    ///
    /// - Parameters:
    ///   - executable: the program to run on the PTY. Defaults to an interactive login
    ///     zsh (`-l -i`) so it behaves like a real terminal (prompt, rc files).
    ///   - arguments: argv after the executable (defaults to `["-l", "-i"]` for zsh).
    ///   - cwd: working directory for the child (nil → inherit).
    ///   - environment: the child's environment. `TERM` is forced to `xterm-256color` if
    ///     the caller didn't set one, so line-based tools behave.
    public init(
        executable: String = "/bin/zsh",
        arguments: [String]? = nil,
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        // openpty(3): allocate a master/slave PTY pair. The slave becomes the child's
        // controlling terminal; we keep the master to read/write the child's tty.
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw SpawnError.openptyFailed(errno: errno)
        }

        // Build argv. zsh runs as a login + interactive shell so the PTY is a usable
        // REPL-style terminal (prompt, rc files), but with JOB CONTROL OFF (`+m` ==
        // `unsetopt monitor`). This is load-bearing for the always-killable / no-orphan
        // guarantee: with job control ON, a backgrounded job (`cmd &`) gets its OWN
        // process group, which `kill(-pid, …)` in `terminate()` would NOT reach — leaving
        // an orphaned process running on the Mac (the #1 risk of this feature). With it
        // OFF, `&` children stay in the shell's process group, so killing the group reaps
        // EVERYTHING the session spawned. Interactive job control (Ctrl-Z / fg / bg) is
        // not needed for an agent-driven streaming terminal; a reliable kill is. A
        // caller-supplied executable uses its own args verbatim.
        let argv = arguments ?? (executable == "/bin/zsh" ? ["-l", "-i", "+m"] : [])
        var env = environment
        if env["TERM"] == nil { env["TERM"] = "xterm-256color" }

        // posix_spawn with a file-actions block that wires the slave fd to the child's
        // stdin/stdout/stderr and makes it the controlling terminal, then closes the
        // inherited master/slave in the child. POSIX_SPAWN_SETSID puts the child in a new
        // session (its own process group == its pid), so `kill(-pid, …)` in terminate()
        // reaps the whole group. (posix_spawn is the supported, fork-safe spawn primitive;
        // a bare fork()+exec() in a Swift process that has already started threads is
        // unsafe — only async-signal-safe calls are allowed between fork and exec.)
        // On Darwin these are imported as opaque pointers (`UnsafeMutableRawPointer?`),
        // initialized to nil and filled in by their `_init` calls.
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, slave)
        posix_spawn_file_actions_addclose(&fileActions, master)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session (== new process group): the controlling tty is the slave (it's the
        // child's stdin), and the group is killable as a unit.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        // Marshal argv/envp into C arrays (NULL-terminated). Each strdup'd string is freed
        // after the spawn.
        var argvC: [UnsafeMutablePointer<CChar>?] = [strdup(executable)]
        argvC.append(contentsOf: argv.map { strdup($0) })
        argvC.append(nil)
        var envpC: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envpC.append(nil)
        defer {
            for p in argvC where p != nil { free(p) }
            for p in envpC where p != nil { free(p) }
        }

        // Set the child's cwd via the spawn file actions (race-free; applied in the child
        // between fork and exec). `_np` = Darwin/BSD non-portable extension, present on
        // macOS. A bad path here just leaves the child in the inherited cwd — never fatal.
        if let cwd {
            _ = cwd.withCString { posix_spawn_file_actions_addchdir_np(&fileActions, $0) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, executable, &fileActions, &attr, argvC, envpC)
        // We no longer need the slave in the PARENT (the child owns its copy). Close it so
        // that when the child exits, the master read returns EOF.
        close(slave)
        guard rc == 0 else {
            close(master)
            throw SpawnError.forkFailed(errno: rc)
        }

        self.masterFD = master
        self.pid = childPID

        var continuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream<Data> { continuation = $0 }
        self.outputContinuation = continuation

        // Drain the master fd on a private queue. availableData-style read via a
        // DispatchSource so we never block a thread waiting on the tty.
        let source = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: DispatchQueue(label: "eldr-acp.pty.reader"))
        self.readSource = source
        let cont = continuation!
        let fd = master
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if n > 0 {
                cont.yield(Data(buffer[0..<n]))
            } else {
                // n == 0 → EOF (child exited / we closed the fd). n < 0 with EAGAIN is not
                // possible for a blocking fd under a read source; any other negative is a
                // hard error. Either way the stream is done.
                cont.finish()
            }
        }
        source.setCancelHandler { [fd] in
            // The source owns the fd's read side; closing here (once, on cancel) is the
            // single close of the master fd.
            close(fd)
        }
        // Finishing the stream when the consumer stops is fine; the source keeps draining
        // until terminate() cancels it.
        source.resume()
    }

    /// Write `data` to the child's stdin (the PTY master). A partial/failed write on a
    /// terminated PTY is a silent no-op (the child is gone). Best-effort and synchronous.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        stateLock.lock()
        let alive = state == .running
        stateLock.unlock()
        guard alive, !data.isEmpty else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            var written = 0
            let total = raw.count
            guard let base = raw.baseAddress else { return false }
            while written < total {
                let n = Darwin.write(masterFD, base + written, total - written)
                if n > 0 {
                    written += n
                } else {
                    // EOF/closed pipe/error: stop. SIGPIPE is ignored process-wide by the
                    // client driver's `signal(SIGPIPE, SIG_IGN)`, so a dead child surfaces
                    // as a short write, not a crash.
                    break
                }
            }
            return written == total
        }
    }

    /// Convenience: write a UTF-8 string to stdin.
    @discardableResult
    public func write(_ text: String) -> Bool { write(Data(text.utf8)) }

    /// Kill the child (its whole process group) and close the master fd. IDEMPOTENT and
    /// synchronous — safe to call from any task, repeatedly, and from a fail-closed
    /// teardown. After this the `output` stream finishes (the read source's cancel handler
    /// closes the fd; the child's exit would also EOF it). This is the always-killable
    /// guarantee the phone's Stop control and the relay/lock/background teardown rely on.
    public func terminate() {
        stateLock.lock()
        if state == .terminated {
            stateLock.unlock()
            return
        }
        state = .terminated
        stateLock.unlock()

        // SIGTERM the whole process group first (negative pid == the group, since the
        // child is a session leader via POSIX_SPAWN_SETSID), then SIGKILL to guarantee
        // death even if the child trapped TERM. A child that forked its own children dies
        // with the group, so nothing is orphaned.
        kill(-pid, SIGTERM)
        kill(-pid, SIGKILL)
        // Reap the zombie so the child is fully gone (non-blocking; the kill above already
        // delivered SIGKILL, and we don't want to block teardown if it lingers a tick —
        // WNOHANG plus the SIGKILL is enough to prevent an orphan).
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)

        // Cancel the read source → its cancel handler closes the master fd (exactly once).
        readSource.cancel()
        // Finish the output stream explicitly: cancelling the source means its event
        // handler may never fire the EOF `finish()`, so signal completion here. Finishing
        // an already-finished continuation is a documented no-op, so a natural EOF that
        // raced this is harmless.
        outputContinuation.finish()
    }

    /// Whether the child has been terminated (or the fd closed). Best-effort snapshot.
    public var isTerminated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state == .terminated
    }

    deinit {
        // Backstop: if the owner dropped us without calling terminate(), don't leak a
        // shell. terminate() is idempotent, so a prior explicit call makes this a no-op.
        terminate()
    }
}
#endif  // os(macOS) — PTYProcess (node-side: spawns a shell on a pseudo-terminal)
