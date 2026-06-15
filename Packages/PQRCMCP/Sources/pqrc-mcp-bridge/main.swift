#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif
import Foundation

// pqrc-mcp-bridge — the stdio SHIM (A35 Phase 2). EldrChat's real secure chat is
// in an encrypted store whose key lives only in the unlocked app's RAM, so a
// standalone MCP process can't read it. The app HOSTS the MCP server in-process
// on a loopback socket; THIS tiny binary is what Goose/Xcode spawn, and it just
// pipes the editor's stdin/stdout to that socket. It carries NO MCP logic.
//
// Config (set by the app's Settings panel, which shows you the exact values):
//   PQRC_MCP_SOCKET                  — path to the app's loopback Unix socket (preferred)
//   PQRC_MCP_PORT + PQRC_MCP_TOKEN   — 127.0.0.1 TCP fallback
//   PQRC_MCP_TOKEN                   — pairing token, sent as the FIRST line
//
// Diagnostics go to stderr so they never corrupt the protocol stream on stdout.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("pqrc-mcp-bridge: " + message + "\n").utf8))
    exit(1)
}

let env = ProcessInfo.processInfo.environment
guard let token = env["PQRC_MCP_TOKEN"], !token.isEmpty else {
    die("PQRC_MCP_TOKEN is required (the app's Settings panel shows it).")
}

// Connect: Unix-domain socket if PQRC_MCP_SOCKET is set, else 127.0.0.1:PORT.
let sockFD: Int32
if let path = env["PQRC_MCP_SOCKET"], !path.isEmpty {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { die("socket() failed (errno \(errno))") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        die("PQRC_MCP_SOCKET path too long")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard ok == 0 else { die("connect(unix) failed (errno \(errno)) — is the app unlocked with local agent access ON?") }
    sockFD = fd
} else if let portStr = env["PQRC_MCP_PORT"], let port = UInt16(portStr) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { die("socket() failed (errno \(errno))") }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only
    let len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard ok == 0 else { die("connect(127.0.0.1:\(port)) failed (errno \(errno)) — is the app unlocked with local agent access ON?") }
    sockFD = fd
} else {
    die("set PQRC_MCP_SOCKET (preferred) or PQRC_MCP_PORT.")
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

/// Copy everything from `src` to `dst` until EOF/error, then close `dst`'s write
/// side by closing the fd (signals the peer we're done).
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

// Handshake: the token is the very first line the in-app server requires.
guard writeAll(sockFD, Array((token + "\n").utf8)) else {
    die("failed to send pairing token")
}

// socket → stdout on a background thread; stdin → socket on the main thread.
// When either side hits EOF the process exits, tearing both down.
let outThread = Thread { pump(from: sockFD, to: FileHandle.standardOutput.fileDescriptor) }
outThread.stackSize = 1 << 20
outThread.start()

pump(from: FileHandle.standardInput.fileDescriptor, to: sockFD)
shutdown(sockFD, SHUT_WR)
// Give the reverse direction a moment to flush any final response, then exit.
while !outThread.isFinished { usleep(2000) }
exit(0)
