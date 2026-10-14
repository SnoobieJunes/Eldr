// SPDX-License-Identifier: AGPL-3.0-only
// Ported from Apps/Huginn WorldStatusClient (WS-D2h) for Glibc (WS-N10). Read-only: there
// is no write path here; revocation stays in the grants file and on the phone.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation

public struct TownStatusWire: Decodable, Equatable, Sendable {
    public struct Town: Decodable, Equatable, Sendable {
        public let townID: String
        public let label: String
        public let wallGranted: Bool
        public let delegateGranted: Bool
        public let lastSeen: Int64
        public let grantExpiry: Int64?
    }
    public let nodeTownID: String
    public let localAgentID: String
    public let towns: [Town]
    public let droppedInboundCount: Int
    public let generatedAt: Int64

    /// Pinned against the node's encoder (see `worldStatusWireMatchesTheNodeContract`).
    public static let fieldNames: Set<String> = [
        "nodeTownID", "localAgentID", "towns", "droppedInboundCount", "generatedAt",
        "townID", "label", "wallGranted", "delegateGranted", "lastSeen", "grantExpiry",
    ]
}

public enum WorldStatusError: Error, Equatable {
    case notConfigured
    case nodeUnreachable(String)
    case noResponse
    case decodeFailed(String)

    public var message: String {
        switch self {
        case .notConfigured: return "No town socket configured (mcp-town.env has no ELDR_GOOSEWORLD_TOKEN + socket/port)."
        case .nodeUnreachable(let why): return "The node isn't answering: \(why)"
        case .noResponse: return "The node closed the connection (wrong token?)."
        case .decodeFailed(let s): return "Unexpected reply: \(s)"
        }
    }
}

public enum WorldStatusClient {
    public struct Config: Equatable, Sendable {
        public var socketPath: String?
        public var port: UInt16?
        public var token: String
    }

    public static func resolveConfig(
        paths: HuginnPaths, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Config? {
        let file = EnvFile.read(paths.gooseworldEnvFile)
        func value(_ k: String) -> String? {
            if let v = environment[k]?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
            if let v = file[k]?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
            return nil
        }
        guard let token = value("ELDR_GOOSEWORLD_TOKEN") else { return nil }
        let socketPath = value("ELDR_GOOSEWORLD_SOCKET")
        let port = value("ELDR_GOOSEWORLD_PORT").flatMap(UInt16.init)
        guard socketPath != nil || port != nil else { return nil }
        return Config(socketPath: socketPath, port: port, token: token)
    }

    public static func fetch(paths: HuginnPaths, timeout: TimeInterval = 3) async throws(WorldStatusError) -> TownStatusWire {
        guard let config = resolveConfig(paths: paths) else { throw .notConfigured }
        return try await fetch(config, timeout: timeout)
    }

    public static func fetch(_ config: Config, timeout: TimeInterval = 3) async throws(WorldStatusError) -> TownStatusWire {
        let r: Result<TownStatusWire, WorldStatusError> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: .success(try fetchBlocking(config, timeout: timeout))) }
                catch let e as WorldStatusError { cont.resume(returning: .failure(e)) }
                catch { cont.resume(returning: .failure(.noResponse)) }
            }
        }
        return try r.get()
    }

    #if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    private static let streamType = SOCK_STREAM
    #endif

    static func fetchBlocking(_ config: Config, timeout: TimeInterval) throws(WorldStatusError) -> TownStatusWire {
        let fd: Int32
        if let path = config.socketPath {
            fd = socket(AF_UNIX, streamType, 0)
            guard fd >= 0 else { throw .nodeUnreachable("socket() failed") }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                close(fd); throw .nodeUnreachable("socket path too long")
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes); raw[bytes.count] = 0
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
            }
            guard ok == 0 else {
                let e = errno; close(fd); throw .nodeUnreachable(String(cString: strerror(e)))
            }
        } else {
            fd = socket(AF_INET, streamType, 0)
            guard fd >= 0 else { throw .nodeUnreachable("socket() failed") }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = (config.port ?? 0).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only
            let len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
            }
            guard ok == 0 else {
                let e = errno; close(fd); throw .nodeUnreachable(String(cString: strerror(e)))
            }
        }
        defer { close(fd) }
        var tv = timeval()
        tv.tv_sec = Int(timeout)
        tv.tv_usec = .init((timeout - floor(timeout)) * 1_000_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let request = config.token + "\n" + #"{"jsonrpc":"2.0","id":1,"method":"world/status"}"# + "\n"
        let payload = Array(request.utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { throw .nodeUnreachable("write failed") }
        }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while out.count < 4 * 1024 * 1024 {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
                if out.contains(UInt8(ascii: "\n")) { break }
            } else if n < 0 && errno == EINTR { continue } else { break }
        }
        guard !out.isEmpty else { throw .noResponse }
        let line = out.prefix(while: { $0 != UInt8(ascii: "\n") })
        struct Envelope: Decodable { let result: TownStatusWire }
        do { return try JSONDecoder().decode(Envelope.self, from: Data(line)).result }
        catch { throw .decodeFailed(String(decoding: line.prefix(200), as: UTF8.self)) }
    }
}
