// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

// WS-D2h — Huginn's read path to the node's dashboard model (`world/status`).
//
// **Why a mirror type and not the node's own.** Huginn deliberately does NOT link
// EldrNode — the pbxproj build phase that bundles `eldr-buzz-agent` says so in as many
// words ("Huginn SUPERVISES this binary as a child process; it does not link EldrNode").
// Linking it to share one struct would pull the entire node package, its relay stack and
// its keystore into the app. So the wire shape is mirrored here and pinned by
// `worldStatusWireMatchesTheNodeContract`, which fails if the two drift.
//
// **Why this is read-only.** There is no write counterpart and no method here that
// mutates node state. Revocation stays where it already lives — the grants file, the
// phone — so the dashboard can never become a second, weaker authorization path.

/// Mirror of the node's `TownStatusSnapshot`. Field names are the wire contract.
struct TownStatusWire: Decodable, Equatable, Sendable {
    struct Town: Decodable, Equatable, Sendable {
        let townID: String
        let label: String
        let wallGranted: Bool
        let delegateGranted: Bool
        /// Unix seconds of last inbound contact; 0 = never seen this run.
        let lastSeen: Int64
        /// When authorization fully lapses; nil = no live grant.
        let grantExpiry: Int64?
    }
    let nodeTownID: String
    let localAgentID: String
    let towns: [Town]
    let droppedInboundCount: Int
    let generatedAt: Int64

    /// The wire contract, asserted by test against the node's `allowedFieldNames`.
    static let fieldNames: Set<String> = [
        "nodeTownID", "localAgentID", "towns", "droppedInboundCount", "generatedAt",
        "townID", "label", "wallGranted", "delegateGranted", "lastSeen", "grantExpiry",
    ]
}

enum WorldStatusError: Error, Equatable {
    /// No socket/token configured — the node's town plane isn't set up on this Mac.
    case notConfigured
    /// Socket exists but nothing accepted — the usual case: the node isn't running.
    case nodeUnreachable(String)
    case noResponse
    case decodeFailed(String)
}

enum WorldStatusClient {

    /// Where the socket + token come from. The PROCESS ENVIRONMENT wins over the env
    /// file, so a Huginn launched from a shell that exported them (how the node itself is
    /// usually started) agrees with the node rather than with a stale template file.
    struct Config: Equatable {
        var socketPath: String?
        var port: UInt16?
        var token: String
    }

    static func resolveConfig(
        paths: ConfigPaths, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Config? {
        let fileValues = parseEnvFile(at: paths.gooseworldEnvFile)
        func value(_ key: String) -> String? {
            if let v = environment[key]?.trimmed, !v.isEmpty { return v }
            if let v = fileValues[key]?.trimmed, !v.isEmpty { return v }
            return nil
        }
        guard let token = value("ELDR_GOOSEWORLD_TOKEN") else { return nil }
        let socketPath = value("ELDR_GOOSEWORLD_SOCKET")
        let port = value("ELDR_GOOSEWORLD_PORT").flatMap(UInt16.init)
        guard socketPath != nil || port != nil else { return nil }
        return Config(socketPath: socketPath, port: port, token: token)
    }

    /// Parse a shell-sourceable `KEY=value` env file. Comment lines and the template's
    /// commented placeholders are ignored — a template file must read as "not configured",
    /// not as a token of literal text `paste-the-pairing-token-here`.
    static func parseEnvFile(at path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmed
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[line.startIndex..<eq]).trimmed
            var value = String(line[line.index(after: eq)...]).trimmed
            // Tolerate `export K=v` and quoted values, the two shapes a hand-edited
            // env file actually takes.
            if key.hasPrefix("export ") { continue }
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// Fetch one snapshot. Blocking socket work runs off the cooperative pool.
    static func fetch(paths: ConfigPaths, timeout: TimeInterval = 3) async throws -> TownStatusWire {
        guard let config = resolveConfig(paths: paths) else { throw WorldStatusError.notConfigured }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try fetchBlocking(config, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fetchBlocking(_ config: Config, timeout: TimeInterval) throws
        -> TownStatusWire
    {
        let fd: Int32
        if let path = config.socketPath {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw WorldStatusError.nodeUnreachable("socket() failed") }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                close(fd)
                throw WorldStatusError.nodeUnreachable("socket path too long")
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
                let e = errno
                close(fd)
                // ECONNREFUSED/ENOENT here is the COMMON case (node not running), not an
                // error state the user did anything wrong to reach.
                throw WorldStatusError.nodeUnreachable(String(cString: strerror(e)))
            }
        } else {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw WorldStatusError.nodeUnreachable("socket() failed") }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = (config.port ?? 0).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only, never routable
            let len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
            }
            guard ok == 0 else {
                let e = errno
                close(fd)
                throw WorldStatusError.nodeUnreachable(String(cString: strerror(e)))
            }
        }
        defer { close(fd) }

        // A hung node must not hang the UI: bound both directions.
        var tv = timeval(
            tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Token FIRST line, exactly as the extension does — then the request.
        let request = config.token + "\n" + #"{"jsonrpc":"2.0","id":1,"method":"world/status"}"# + "\n"
        var payload = Array(request.utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                sent += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                throw WorldStatusError.nodeUnreachable("write failed")
            }
        }
        payload.removeAll()

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while out.count < 4 * 1024 * 1024 {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
                if out.contains(UInt8(ascii: "\n")) { break }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        // A wrong token closes the connection with nothing serviced — that is an empty
        // read, and it must not be reported as "no towns".
        guard !out.isEmpty else { throw WorldStatusError.noResponse }
        let line = out.prefix(while: { $0 != UInt8(ascii: "\n") })

        struct Envelope: Decodable { let result: TownStatusWire }
        do {
            return try JSONDecoder().decode(Envelope.self, from: Data(line)).result
        } catch {
            throw WorldStatusError.decodeFailed(String(decoding: line.prefix(200), as: UTF8.self))
        }
    }
}

extension StringProtocol {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
