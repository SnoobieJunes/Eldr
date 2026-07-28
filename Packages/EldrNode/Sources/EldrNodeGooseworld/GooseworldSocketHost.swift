// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCMCP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// WS-G5 — the node-side LOOPBACK host for the `eldr-gooseworld` extension.
//
// The extension binary is a dumb byte pump: it connects to this socket, sends the
// pairing TOKEN as the very first line, then copies goose's MCP JSON-RPC lines both
// ways. This host is its counterpart: listen on a Unix-domain socket (preferred; 0600,
// owner-only by filesystem permission) or 127.0.0.1 TCP (the client refuses non-loopback
// by construction), require the token line before ANY JSON-RPC is serviced, then answer
// each line through `GooseworldMCPServer` — which is where the four `world_*` tools and
// the `UntrustedDataEnvelope` containment live. The token exists because a loopback
// socket is reachable by every local process (the extension's own header says so): a
// connection that cannot present it is closed without servicing a single line.
//
// `@unchecked Sendable` JUSTIFICATION (CLAUDE.md requires one; precedent: `PTYProcess`):
// the mutable fds/state are guarded by `stateLock` for every access; the accept and
// per-connection read loops run on private dispatch queues and only cross into async
// via Task + the actor-backed server. A class (not an actor) because `stop()` must be
// synchronous and callable from teardown paths without an actor hop.
public final class GooseworldSocketHost: @unchecked Sendable {
    public enum Endpoint: Sendable, Equatable {
        /// Unix-domain socket at `path` (created 0600; any stale file is unlinked first).
        case unix(path: String)
        /// TCP on 127.0.0.1:`port` — the fallback for hosts where a socket path is
        /// awkward. Loopback-only by construction (we bind 127.0.0.1, never 0.0.0.0).
        case loopbackTCP(port: UInt16)
    }

    public enum HostError: Error, Equatable {
        case socketFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
        case pathTooLong
    }

    /// Longest accepted line (token or JSON-RPC). A peer process streaming an unbounded
    /// line is dropped, not buffered — same bounded posture as every other intake.
    static let maxLineBytes = 1024 * 1024

    /// WS-D1n — the dashboard method name. Deliberately slash-namespaced so it cannot
    /// collide with an MCP tool name (`world_wall_post` &c. are underscore-separated).
    static let statusMethod = "world/status"

    private let endpoint: Endpoint
    private let token: String
    private let server: GooseworldMCPServer
    /// WS-D1n — supplies the dashboard read model. nil ⇒ `world/status` is simply not
    /// implemented and falls through to the MCP server's unknown-method answer.
    private let statusProvider: (@Sendable () async -> TownStatusSnapshot)?

    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private let acceptQueue = DispatchQueue(label: "eldr-node.gooseworld.accept")

    public init(
        endpoint: Endpoint, token: String, server: GooseworldMCPServer,
        statusProvider: (@Sendable () async -> TownStatusSnapshot)? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.server = server
        self.statusProvider = statusProvider
    }

    /// Bind + listen + begin accepting. Each connection is serviced independently; the
    /// token gate runs per connection.
    public func start() throws {
        signal(SIGPIPE, SIG_IGN)  // a vanished client is a short write, never a crash
        let fd: Int32
        switch endpoint {
        case .unix(let path):
            fd = socket(AF_UNIX, Self.sockStreamType, 0)
            guard fd >= 0 else { throw HostError.socketFailed(errno: errno) }
            unlink(path)  // a stale socket file from a previous run would fail bind
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                close(fd)
                throw HostError.pathTooLong
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
            }
            guard bound == 0 else {
                let e = errno
                close(fd)
                throw HostError.bindFailed(errno: e)
            }
            chmod(path, 0o600)  // owner-only, same posture as every node data file
        case .loopbackTCP(let port):
            fd = socket(AF_INET, Self.sockStreamType, 0)
            guard fd >= 0 else { throw HostError.socketFailed(errno: errno) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback ONLY, never 0.0.0.0
            let len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
            }
            guard bound == 0 else {
                let e = errno
                close(fd)
                throw HostError.bindFailed(errno: e)
            }
        }
        guard listen(fd, 4) == 0 else {
            let e = errno
            close(fd)
            throw HostError.listenFailed(errno: e)
        }
        stateLock.lock()
        listenFD = fd
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            while let self {
                self.stateLock.lock()
                let fd = self.listenFD
                let stopped = self.stopped
                self.stateLock.unlock()
                guard !stopped, fd >= 0 else { return }
                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    return  // listen fd closed (stop()) or hard error — end the loop
                }
                self.serviceConnection(client)
            }
        }
    }

    /// Close the listener (in-flight connections finish on their own). Idempotent.
    public func stop() {
        stateLock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 { close(fd) }
        if case .unix(let path) = endpoint { unlink(path) }
    }

    deinit { stop() }

    // MARK: - Per-connection service

    private func serviceConnection(_ fd: Int32) {
        // One queue per connection owns the BLOCKING read loop; it yields whole lines
        // into an AsyncStream a Task consumes serially — so responses are written in
        // request order, and no blocking read ever runs on a concurrency thread.
        let queue = DispatchQueue(label: "eldr-node.gooseworld.conn")
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        queue.async {
            var buffer = Data()
            let newline = UInt8(ascii: "\n")
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            reading: while true {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    buffer.append(contentsOf: chunk[0..<n])
                    if buffer.count > Self.maxLineBytes { break }
                    while let idx = buffer.firstIndex(of: newline) {
                        let lineData = buffer[buffer.startIndex..<idx]
                        continuation.yield(String(decoding: lineData, as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...idx)
                    }
                } else if n < 0 && errno == EINTR {
                    continue reading
                } else {
                    break
                }
            }
            continuation.finish()
        }
        Task {
            var authenticated = false
            for await line in stream {
                if !authenticated {
                    // The token is the FIRST line, exactly. Anything else — including a
                    // valid JSON-RPC request — closes the connection unserviced.
                    guard line == token else { break }
                    authenticated = true
                    continue
                }
                // WS-D1n: the dashboard method is answered HERE, ahead of the MCP
                // server, and only after the same token gate.
                if let response = await self.statusResponse(for: line) {
                    guard Self.writeAll(fd, Array((response + "\n").utf8)) else { break }
                    continue
                }
                if let response = await server.handle(line: line) {
                    guard Self.writeAll(fd, Array((response + "\n").utf8)) else { break }
                }
            }
            close(fd)
        }
    }

    // MARK: - WS-D1n: the dashboard method

    /// JSON-RPC ids are a number, a string, or absent (a notification). Modelled exactly
    /// so the reply echoes the caller's id in its original type rather than coercing it.
    private enum RPCID: Encodable {
        case number(Int)
        case string(String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .number(let n): try c.encode(n)
            case .string(let s): try c.encode(s)
            }
        }
    }

    private struct StatusEnvelope: Encodable {
        let jsonrpc = "2.0"
        let id: RPCID
        let result: TownStatusSnapshot
    }

    /// Answer `world/status`, or nil to let the line fall through to the MCP server.
    ///
    /// **Why this lives here and not in `GooseworldMCPServer`.** The dashboard needs
    /// structured data; the MCP server's `world_towns` deliberately returns prose framed
    /// by `UntrustedDataEnvelope` for a model to read. Adding a structured variant to the
    /// server would widen the AGENT's capability surface — a flock could then enumerate
    /// towns in a machine-readable form — and those four tool descriptions are
    /// injection-hardened and CC0-donatable. Intercepting at the socket instead means
    /// `world/status` is not a tool, never appears in `tools/list`, and is unreachable by
    /// any goose flock, while still inheriting this socket's token gate and loopback bind.
    private func statusResponse(for line: String) async -> String? {
        guard let statusProvider,
            let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["method"] as? String == Self.statusMethod
        else { return nil }

        // A notification (no id) gets no reply, per JSON-RPC.
        let id: RPCID
        if let n = obj["id"] as? Int {
            id = .number(n)
        } else if let s = obj["id"] as? String {
            id = .string(s)
        } else {
            return nil
        }

        let snapshot = await statusProvider()
        guard let encoded = try? JSONEncoder().encode(StatusEnvelope(id: id, result: snapshot))
        else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Blocking write-all; false on error (mirrors the extension's own `writeAll`).
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// `SOCK_STREAM` imports as `Int32` on Darwin but as the `__socket_type` enum on
    /// Glibc — the same normalization the extension binary does.
    static var sockStreamType: Int32 {
        #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }
}
