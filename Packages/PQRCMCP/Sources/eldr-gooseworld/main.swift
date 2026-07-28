// SPDX-License-Identifier: Apache-2.0
#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif
import Foundation

// `SOCK_STREAM` imports as `Int32` on Darwin but as the `__socket_type` enum on Glibc,
// so normalize it once for the `socket()` calls below (Linux town port).
#if canImport(Glibc)
private let sockStreamType = Int32(SOCK_STREAM.rawValue)
#else
private let sockStreamType = SOCK_STREAM
#endif

// eldr-gooseworld — the goose extension binary (GOOSEWORLD §6 WS-G3).
//
// A goose extension IS an MCP server, so this is what you register in a goosetown to
// give its flock `world_wall_post` / `world_wall_read` / `world_delegate` /
// `world_towns`. What it is NOT is an MCP server: it is a PIPE, and that is the whole
// security argument.
//
// The node (Huginn or eldr-node) owns the agent identity key, the paired-town list, the
// standing grants and the ratchet state. SPEC §13.5: agent keys never leave the node. If
// this binary spoke the protocol it would need the identity to sign with, and every
// goosetown that loaded it — plus every process that could read its argv, environment or
// core dump — would be inside the key's blast radius. Instead the unlocked node HOSTS
// `GooseworldMCPServer` on a loopback socket and this process copies bytes to it. It
// holds no key, no wall state, no cursor, and no grant; killing it loses nothing and
// compromising it grants nothing beyond the loopback session it already had.
//
// It is also why the pairing token exists: a loopback socket is reachable by every local
// process, so the node demands a token as the FIRST line before it will serve anything.
//
// Config (the node's settings panel prints the exact values):
//   ELDR_GOOSEWORLD_SOCKET                       — Unix-domain socket path (preferred)
//   ELDR_GOOSEWORLD_PORT + ELDR_GOOSEWORLD_TOKEN — 127.0.0.1 TCP fallback
//   ELDR_GOOSEWORLD_TOKEN                        — pairing token, sent as the first line
//
// Diagnostics go to stderr so they never corrupt the JSON-RPC stream on stdout, and they
// never include wall content — this process must not become the place where quarantined
// remote text leaks into a plaintext log (CLAUDE.md invariant 12).

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("eldr-gooseworld: " + message + "\n").utf8))
    exit(1)
}

let env = ProcessInfo.processInfo.environment
guard let token = env["ELDR_GOOSEWORLD_TOKEN"], !token.isEmpty else {
    die("ELDR_GOOSEWORLD_TOKEN is required (the node's settings panel shows it).")
}

// Connect: Unix-domain socket if ELDR_GOOSEWORLD_SOCKET is set, else 127.0.0.1:PORT.
// There is deliberately no way to point this at a non-loopback address: the node is on
// this machine by definition, and a remote-host option would turn a config typo into an
// unencrypted cross-network agent channel.
let sockFD: Int32
if let path = env["ELDR_GOOSEWORLD_SOCKET"], !path.isEmpty {
    let fd = socket(AF_UNIX, sockStreamType, 0)
    guard fd >= 0 else { die("socket() failed (errno \(errno))") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        die("ELDR_GOOSEWORLD_SOCKET path too long")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard ok == 0 else {
        die("connect(unix) failed (errno \(errno)) — is the node running and unlocked with gooseworld access ON?")
    }
    sockFD = fd
} else if let portStr = env["ELDR_GOOSEWORLD_PORT"], let port = UInt16(portStr) {
    let fd = socket(AF_INET, sockStreamType, 0)
    guard fd >= 0 else { die("socket() failed (errno \(errno))") }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only
    let len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard ok == 0 else {
        die("connect(127.0.0.1:\(port)) failed (errno \(errno)) — is the node running and unlocked with gooseworld access ON?")
    }
    sockFD = fd
} else {
    die("set ELDR_GOOSEWORLD_SOCKET (preferred) or ELDR_GOOSEWORLD_PORT.")
}

/// Blocking write-all of `bytes` to `fd`; false on error.
@Sendable func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
    }
    return true
}

/// Copy everything from `src` to `dst` until EOF/error.
@Sendable func pump(from src: Int32, to dst: Int32) {
    var buf = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let n = buf.withUnsafeMutableBytes { read(src, $0.baseAddress, $0.count) }
        if n > 0 {
            if !writeAll(dst, Array(buf[0..<n])) { break }
        } else if n == 0 {
            break  // EOF
        } else if errno == EINTR {
            continue
        } else {
            break
        }
    }
}

// Handshake: the token is the very first line the in-node server requires.
guard writeAll(sockFD, Array((token + "\n").utf8)) else {
    die("failed to send pairing token")
}

// socket → stdout on a background thread; stdin → socket on the main thread.
// When either side hits EOF the process exits, tearing both down.
let outThread = Thread { pump(from: sockFD, to: FileHandle.standardOutput.fileDescriptor) }
outThread.stackSize = 1 << 20
outThread.start()

pump(from: FileHandle.standardInput.fileDescriptor, to: sockFD)
shutdown(sockFD, Int32(SHUT_WR))
// Give the reverse direction a moment to flush any final response, then exit.
while !outThread.isFinished { usleep(2000) }
exit(0)
