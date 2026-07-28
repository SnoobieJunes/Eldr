// SPDX-License-Identifier: Apache-2.0
import Foundation

// NODE-SIDE (macOS + Linux): a pseudo-terminal-backed interactive process — the Phase-D4
// PERSISTENT streaming terminal (REPLs, debuggers, long-running processes), as opposed
// to the one-shot `run_shell` (ToolExecutor). It only ever runs on the node (a Mac or,
// since WS-L4, a Linux server/Pi): the phone is the remote control that drives a node
// over an `ACPTransport` and never spawns a local shell. Guarded off the iOS-compiled
// library exactly like `ToolExecutor`/`ACPAgent`.
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
#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import CEldrPTYShim  // openpty + the real glibc POSIX_SPAWN_SETSID (see the shim header)
import Glibc
#endif

/// The node's default interactive shell (`NodeShell.defaultPath`: zsh on macOS, bash on
/// Linux) — or a caller-chosen executable — running on its own pseudo-terminal. Write
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

    /// Spawn `executable` (default `NodeShell.defaultPath`, login+interactive) on a fresh
    /// PTY in `cwd` with `environment`. The child runs in its OWN session/process group
    /// (`POSIX_SPAWN_SETSID`), so `terminate()` can signal the whole group and a child
    /// that forks its own children still gets cleaned up.
    ///
    /// - Parameters:
    ///   - executable: the program to run on the PTY. Defaults to the platform's
    ///     interactive login shell (`-l -i`) so it behaves like a real terminal
    ///     (prompt, rc files) — zsh on macOS, bash on Linux.
    ///   - arguments: argv after the executable (defaults to `["-l", "-i", "+m"]` for
    ///     the default shell).
    ///   - cwd: working directory for the child (nil → inherit).
    ///   - environment: the child's environment. `TERM` is forced to `xterm-256color` if
    ///     the caller didn't set one, so line-based tools behave.
    public init(
        executable: String = NodeShell.defaultPath,
        arguments: [String]? = nil,
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        #if canImport(Darwin)
        // openpty(3): allocate a master/slave PTY pair. The slave becomes the child's
        // controlling terminal; we keep the master to read/write the child's tty.
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw SpawnError.openptyFailed(errno: errno)
        }
        #else
        // Linux (WS-L4): `eldr_openpty` is the `CEldrPTYShim` wrapper over the real
        // openpty(3) — Swift's Glibc module exports NONE of the pty family, so the shim
        // provides it (AC139 predicted the shim). One call allocates the pair, grants +
        // unlocks the slave, and hands back its PATH. The parent closes its slave fd
        // immediately: the CHILD re-opens the slave BY PATH (the `addopen` file action
        // below), which is load-bearing — a fresh session leader (POSIX_SPAWN_SETSID)
        // acquiring its first tty via open(2) makes it the CONTROLLING terminal, which
        // dup2'ing a parent-opened fd would NOT — so the shell gets real tty semantics,
        // same as openpty+SETSID gives on macOS. Closing the parent copy also keeps the
        // EOF contract: once the child exits, nothing holds the slave open, so the master
        // read returns EOF/EIO. No no-slave-open read race hides in the gap: glibc's
        // posix_spawn blocks (CLONE_VFORK) until the child's file actions + exec have
        // run, and the master's read source is only created after it returns.
        var master: Int32 = -1
        var slave: Int32 = -1
        var nameBuf = [CChar](repeating: 0, count: 256)  // "/dev/pts/N" — ample
        guard eldr_openpty(&master, &slave, &nameBuf) == 0 else {
            throw SpawnError.openptyFailed(errno: errno)
        }
        close(slave)
        let slavePath = String(
            decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif

        // Build argv. The shell runs as a login + interactive shell so the PTY is a usable
        // REPL-style terminal (prompt, rc files), but with JOB CONTROL OFF (`+m` ==
        // `unsetopt monitor` in zsh / `set +m` in bash — both accept it at invocation).
        // This is load-bearing for the always-killable / no-orphan
        // guarantee: with job control ON, a backgrounded job (`cmd &`) gets its OWN
        // process group, which `kill(-pid, …)` in `terminate()` would NOT reach — leaving
        // an orphaned process running on the node (the #1 risk of this feature). With it
        // OFF, `&` children stay in the shell's process group, so killing the group reaps
        // EVERYTHING the session spawned. Interactive job control (Ctrl-Z / fg / bg) is
        // not needed for an agent-driven streaming terminal; a reliable kill is. A
        // caller-supplied executable uses its own args verbatim.
        let argv = arguments ?? (executable == NodeShell.defaultPath ? ["-l", "-i", "+m"] : [])
        var env = environment
        if env["TERM"] == nil { env["TERM"] = "xterm-256color" }

        // posix_spawn with a file-actions block that wires the slave to the child's
        // stdin/stdout/stderr and makes it the controlling terminal, then closes the
        // inherited fds in the child. POSIX_SPAWN_SETSID puts the child in a new
        // session (its own process group == its pid), so `kill(-pid, …)` in terminate()
        // reaps the whole group. (posix_spawn is the supported, fork-safe spawn primitive;
        // a bare fork()+exec() in a Swift process that has already started threads is
        // unsafe — only async-signal-safe calls are allowed between fork and exec.)
        // On Darwin these are imported as opaque pointers (`UnsafeMutableRawPointer?`),
        // initialized to nil and filled in by their `_init` calls; on Glibc they are
        // plain structs, so the declarations differ while every call line is shared.
        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t? = nil
        #else
        var fileActions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        #if canImport(Darwin)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, slave)
        posix_spawn_file_actions_addclose(&fileActions, master)
        #else
        // The child — session leader by the SETSID flag below — opens the slave BY PATH
        // as stdin (no O_NOCTTY → it becomes the controlling terminal; POSIX guarantees
        // addopen copies the path string), then stdin is dup2'd onto stdout/stderr and
        // the inherited master is closed so the parent's EOF semantics hold.
        slavePath.withCString {
            _ = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, $0, O_RDWR, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        #endif

        #if canImport(Darwin)
        var attr: posix_spawnattr_t? = nil
        #else
        var attr = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session (== new process group): the controlling tty is the slave (it's the
        // child's stdin), and the group is killable as a unit. On Linux the flag value
        // comes from the shim (`ELDR_POSIX_SPAWN_SETSID` — glibc's 0x80, NOT Darwin's
        // 0x0400; the Glibc module hides the macro behind __USE_GNU).
        #if canImport(Darwin)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        #else
        posix_spawnattr_setflags(&attr, ELDR_POSIX_SPAWN_SETSID)
        #endif

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
        // between fork and exec). `_np` = non-portable extension, but present on BOTH
        // platforms (Darwin, and glibc ≥ 2.29 on Linux). A bad path here just leaves the
        // child in the inherited cwd — never fatal.
        if let cwd {
            _ = cwd.withCString { posix_spawn_file_actions_addchdir_np(&fileActions, $0) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, executable, &fileActions, &attr, argvC, envpC)
        #if canImport(Darwin)
        // We no longer need the slave in the PARENT (the child owns its copy). Close it so
        // that when the child exits, the master read returns EOF. (On Linux the parent
        // never opened the slave — the child opens it by path — so there is nothing to
        // close; the child's exit surfaces on the master as EOF/EIO either way.)
        close(slave)
        #endif
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
            let err = errno  // capture immediately: nothing below reads before this
            if n > 0 {
                cont.yield(Data(buffer[0..<n]))
            } else if n < 0 && (err == EINTR || err == EAGAIN) {
                // Transient, NOT end-of-stream: a signal interrupted the read (EINTR) or no
                // data was actually ready (EAGAIN). Return and let the read source fire
                // again — finishing here would truncate a still-live terminal.
                return
            } else {
                // n == 0 → real EOF (child exited / we closed the fd); any other negative is
                // a hard error. Either way the stream is done.
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
                #if canImport(Darwin)
                let n = Darwin.write(masterFD, base + written, total - written)
                #else
                let n = Glibc.write(masterFD, base + written, total - written)
                #endif
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

    /// Resize the PTY window (TIOCSWINSZ) so full-screen tools (vim, top, less) lay
    /// out to the phone's terminal view (feature 9 — enhanced PTY). Best-effort and
    /// synchronous; a no-op once terminated or for a zero dimension.
    @discardableResult
    public func resize(cols: UInt16, rows: UInt16) -> Bool {
        stateLock.lock()
        let alive = state == .running
        stateLock.unlock()
        guard alive, cols > 0, rows > 0 else { return false }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        #if canImport(Darwin)
        return ioctl(masterFD, TIOCSWINSZ, &ws) == 0
        #else
        // Glibc imports the request constant as a signed int while ioctl takes UInt.
        return ioctl(masterFD, UInt(TIOCSWINSZ), &ws) == 0
        #endif
    }

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
        #if !canImport(Darwin)
        // Linux (WS-L4): the group kill alone is NOT sufficient here — interactive bash
        // re-enables job control even when invoked with `+m` (zsh honors it; bash's
        // interactive init wins), so a backgrounded job (`cmd &`) sits in its OWN process
        // group and the `kill(-pid, …)` above never reaches it. The kernel-truth backstop:
        // EVERYTHING the shell spawned lives in the child's SESSION (the child is the
        // session leader; descendants inherit the sid unless they setsid themselves), so
        // sweep /proc for processes whose session id == the child's pid and SIGKILL each.
        // Two bounded passes close the fork race window; the sweep never blocks teardown.
        // This also covers a caller-chosen executable that setpgid()s itself out of the
        // group — the group-kill hole zsh's `+m` merely papers over.
        for _ in 0..<2 {
            let survivors = Self.sessionMemberPIDs(sessionLeader: pid)
            if survivors.isEmpty { break }
            for member in survivors { kill(member, SIGKILL) }
            usleep(1000)  // 1 ms between passes; ≤ 2 ms total
        }
        #endif
        // Reap the child so it doesn't linger as a zombie. SIGKILL is delivered
        // asynchronously, so an immediate WNOHANG usually returns 0 (not dead YET). Poll a
        // few times with a 1 ms sleep: a killed child we own dies in well under a
        // millisecond, so this reaps it in the common case — while staying BOUNDED. A child
        // wedged in an uninterruptible (D-state) kernel wait can't be reaped until it leaves
        // that state, and teardown must not block on it, so we give up after the cap (≤50 ms)
        // and leave at most one short-lived zombie — the same worst case as before, but now
        // hit only in that pathological case instead of routinely.
        var status: Int32 = 0
        for _ in 0..<50 {
            let r = waitpid(pid, &status, WNOHANG)
            if r != 0 { break }  // r == pid: reaped. r < 0 (ECHILD): already gone / no child.
            usleep(1000)  // 1 ms; ≤ 50 ms total
        }

        // Cancel the read source → its cancel handler closes the master fd (exactly once).
        readSource.cancel()
        // Finish the output stream explicitly: cancelling the source means its event
        // handler may never fire the EOF `finish()`, so signal completion here. Finishing
        // an already-finished continuation is a documented no-op, so a natural EOF that
        // raced this is harmless.
        outputContinuation.finish()
    }

    #if !canImport(Darwin)
    /// Linux: the pids of every live process whose SESSION id equals `sessionLeader` —
    /// i.e. everything spawned inside this PTY session, whatever process group it moved
    /// itself into. Read from /proc/<pid>/stat, parsing after the LAST ')' so a comm
    /// containing spaces/parentheses can't shift the fields (after it: state, ppid,
    /// pgrp, session, …). Best-effort: entries that vanish mid-scan or can't be read
    /// are skipped — the caller re-sweeps.
    private static func sessionMemberPIDs(sessionLeader: pid_t) -> [pid_t] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc")
        else { return [] }
        var members: [pid_t] = []
        for entry in entries {
            guard let candidate = pid_t(entry) else { continue }  // numeric dirs only
            guard let data = FileManager.default.contents(atPath: "/proc/\(entry)/stat")
            else { continue }
            let stat = String(decoding: data, as: UTF8.self)
            guard let close = stat.lastIndex(of: ")") else { continue }
            let fields = stat[stat.index(after: close)...].split(separator: " ")
            guard fields.count >= 4, let session = Int32(fields[3]) else { continue }
            if session == sessionLeader { members.append(candidate) }
        }
        return members
    }
    #endif

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
#endif  // os(macOS) || os(Linux) — PTYProcess (node-side: spawns a shell on a pseudo-terminal)
