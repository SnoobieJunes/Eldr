import Darwin
import Foundation
import OSLog
import PQRCMCP

/// Hosts EldrChat's MCP server IN-PROCESS over a LOOPBACK Unix-domain socket
/// while a silo is unlocked and the user has turned local agent access ON
/// (A35 Phase 2). A tiny external `pqrc-mcp-bridge` shim (the binary Goose/Xcode
/// actually spawn) connects to this socket and pipes the editor's stdio to it —
/// because the real secure-chat store is unreadable without the silo KEK that
/// exists only in THIS running process's RAM, a standalone MCP process could only
/// ever serve demo data.
///
/// Privacy posture (cardinal rule):
/// - **Loopback only.** A Unix-domain socket has no network interface at all
///   (filesystem-namespaced, same-machine only); we NEVER fall back to a TCP
///   bind, so nothing is ever reachable off-box.
/// - **Token-gated.** The very first line a client sends MUST equal the pairing
///   token (random, Keychain-stored). A mismatch (or a missing first line) drops
///   the connection before a single MCP method runs.
/// - **Read-only + redacted.** It serves `RuntimeSecureChatBridge`, which returns
///   only firewall-redacted data (codenames, 64 KB-bounded) and has no send tool.
/// - **OFF by default, stops on lock.** The owner (`AppSession`) starts it only
///   on the explicit Settings toggle and `stop()`s it on lock / toggle-off.
///
/// Swift 6: the actor owns all mutable state (listen fd, run flag, live client
/// fds). Blocking `accept`/`read` happen on detached tasks; `stop()` closes the
/// fds, which unblocks them and unwinds the loops. No locks.
actor LocalMCPServer {
    enum StartError: Error, Equatable {
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong
        case alreadyRunning
    }

    private static let log = Logger(subsystem: "chat.eldr", category: "mcp")

    private let server: MCPServer
    private let token: String
    /// Where we bound the socket (handed to the shim via `PQRC_MCP_SOCKET`).
    let socketPath: String

    private var listenFD: Int32 = -1
    private var running = false
    private var acceptTask: Task<Void, Never>?
    /// Live connection fds, so `stop()` can hang up everything in flight.
    private var clientFDs: Set<Int32> = []

    /// - Parameters:
    ///   - bridge: the firewall-redacted data source (`RuntimeSecureChatBridge`).
    ///   - token: the pairing token a client must present as its first line.
    ///   - socketPath: a loopback UDS path under the app container/temp dir.
    init(bridge: any SecureChatBridge, token: String, socketPath: String) {
        self.server = MCPServer(bridge: bridge)
        self.token = token
        self.socketPath = socketPath
    }

    var isRunning: Bool { running }

    /// Binds the loopback UDS and begins accepting connections. Idempotent-ish:
    /// throws `.alreadyRunning` if already started.
    func start() throws {
        guard !running else { throw StartError.alreadyRunning }

        // A fresh path every start avoids "address already in use" from a stale
        // node and keeps the path unguessable; remove any leftover first.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socketCreateFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path is a fixed 104-byte (Darwin) buffer; leave room for the NUL.
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw StartError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addrLen) }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw StartError.bindFailed(e)
        }
        guard Darwin.listen(fd, 4) == 0 else {
            let e = errno
            close(fd)
            unlink(socketPath)
            throw StartError.listenFailed(e)
        }

        listenFD = fd
        running = true
        Self.log.notice("Local MCP server listening on loopback UDS")

        // The accept loop runs on a detached task and is `nonisolated`, so its
        // BLOCKING `accept()`/`read()` syscalls execute on that task's thread —
        // never on this actor's executor (which would wedge `stop()`/state reads
        // behind a blocked syscall). It hops back onto the actor only for state.
        acceptTask = Task.detached { [weak self, fd] in
            await self?.acceptLoop(listenFD: fd)
        }
    }

    /// Closes the listener and every live connection, removes the socket node, and
    /// returns to the not-running state. Safe to call when already stopped.
    func stop() {
        guard running || listenFD >= 0 else { return }
        running = false
        if listenFD >= 0 {
            close(listenFD)  // unblocks accept()
            listenFD = -1
        }
        for clientFD in clientFDs {
            close(clientFD)  // unblocks any in-flight read()
        }
        clientFDs.removeAll()
        acceptTask?.cancel()
        acceptTask = nil
        unlink(socketPath)
        Self.log.notice("Local MCP server stopped")
    }

    // MARK: - Accept / connection loops (nonisolated: blocking I/O off the actor)

    private func register(_ fd: Int32) { clientFDs.insert(fd) }

    private func unregister(_ fd: Int32) {
        if clientFDs.remove(fd) != nil { close(fd) }
    }

    /// Blocking accept loop, OFF the actor. `stop()` closes `listenFD`, which makes
    /// `accept()` fail (EBADF) and ends the loop.
    private nonisolated func acceptLoop(listenFD: Int32) async {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                // EINTR: retry while still running. Anything else (incl. EBADF from
                // stop()'s close): the listener is gone — exit.
                if errno == EINTR, await isRunning { continue }
                return
            }
            guard await isRunning else {
                close(clientFD)
                return
            }
            await register(clientFD)
            Task.detached { [weak self, clientFD] in
                await self?.serve(clientFD: clientFD)
                await self?.unregister(clientFD)
            }
        }
    }

    /// One client, OFF the actor: enforce the token on the FIRST line, then pump
    /// newline-delimited JSON-RPC through the MCP server until EOF or hang-up. Only
    /// the per-line `server.handle` and the `isRunning` check touch the actor.
    private nonisolated func serve(clientFD: Int32) async {
        // Defense in depth atop the token: a Unix socket accepts a connection from
        // ANY local process, so reject a peer running as a DIFFERENT user before
        // reading a byte (especially worth it now the server can be write-capable).
        // The token stays the primary gate; a getsockopt quirk never locks out a
        // legitimate same-user client (peerIsSameUser fails open on read failure).
        guard peerIsSameUser(clientFD) else {
            Self.log.notice("Local MCP client rejected: peer is a different user")
            return
        }
        var reader = LineReader(fd: clientFD)
        // First line MUST be the pairing token, else drop immediately.
        guard let first = reader.next(), constantTimeEquals(first, token) else {
            Self.log.notice("Local MCP client rejected: bad or missing pairing token")
            return
        }
        while await isRunning, let line = reader.next() {
            guard let response = await server.handle(line: line) else { continue }
            guard writeLine(response, to: clientFD) else { return }
        }
    }
}

// MARK: - Blocking line I/O over a raw fd

/// Reads newline-delimited UTF-8 lines from a blocking socket fd. Buffers across
/// reads; returns nil at EOF / error. Lives off the actor (it blocks).
private struct LineReader {
    let fd: Int32
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 16 * 1024)

    init(fd: Int32) { self.fd = fd }

    mutating func next() -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return String(decoding: lineData, as: UTF8.self)
            }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                // EOF: hand back any trailing partial line once, then stop.
                guard !buffer.isEmpty else { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return line
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }
    }
}

/// Writes `line` + "\n" to a blocking fd; false on error (caller hangs up).
private func writeLine(_ line: String, to fd: Int32) -> Bool {
    let bytes = Array((line + "\n").utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
        if written > 0 {
            offset += written
        } else if written < 0, errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

/// Length-checked, branch-stable token comparison so a reject can't be timed to
/// recover the token byte by byte (it's a same-machine secret, but cheap to do).
private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let lhs = Array(a.utf8)
    let rhs = Array(b.utf8)
    guard lhs.count == rhs.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
    return diff == 0
}

/// Whether the process connected to `fd` runs as the SAME effective user, via the
/// Darwin `LOCAL_PEERCRED` socket credential. Fails OPEN (returns true) if the
/// credential can't be read — the pairing token remains the authoritative gate, so
/// a getsockopt quirk must never lock out a legitimate same-user client.
private func peerIsSameUser(_ fd: Int32) -> Bool {
    var cred = xucred()
    var len = socklen_t(MemoryLayout<xucred>.size)
    let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len)
    guard result == 0, cred.cr_version == UInt32(XUCRED_VERSION) else { return true }
    return cred.cr_uid == geteuid()
}
