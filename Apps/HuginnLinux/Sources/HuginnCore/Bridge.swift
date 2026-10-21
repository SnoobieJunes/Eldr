// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The Bridge tab: serve the full ACP agent to the owner's phone over the relay by
/// supervising `eldr-node` (the macOS app hosts the relay agent in-process; on Linux the
/// same EldrNodeCore runs as the `eldr-node` daemon — DEVIATIONS AC207). The owner gate
/// (C-3) is enforced INSIDE eldr-node; this only refuses to start without an owner.
public struct BridgeSettings: Codable, Sendable, Equatable {
    public var ownerHex: String
    public var relayURL: String
    public var workdir: String
    /// `sybilclaw` (default), `eldr-acp`, or a HarnessRegistry id.
    public var responder: String

    public init(ownerHex: String = "", relayURL: String = "wss://relay.lerants.com",
                workdir: String = "", responder: String = "eldr-acp") {
        self.ownerHex = ownerHex; self.relayURL = relayURL
        self.workdir = workdir; self.responder = responder
    }

    public enum Problem: Sendable, Equatable {
        case missingOwner, badOwner, badRelay(String), badWorkdir
        public var message: String {
            switch self {
            case .missingOwner: return "Paste the phone's identity (hex) — the node refuses to serve with no owner."
            case .badOwner: return "The owner identity must be hex."
            case .badRelay(let why): return "Relay URL: \(why)"
            case .badWorkdir: return "The workdir does not exist."
            }
        }
    }

    public var problems: [Problem] {
        var out: [Problem] = []
        let owner = ownerHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if owner.isEmpty { out.append(.missingOwner) }
        else if owner.count % 2 != 0 || !owner.allSatisfy(\.isHexDigit) { out.append(.badOwner) }
        if case .failure(let why) = RelayURL.validate(relayURL) { out.append(.badRelay(why.message)) }
        if !workdir.isEmpty {
            var dir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: workdir, isDirectory: &dir) || !dir.boolValue { out.append(.badWorkdir) }
        }
        return out
    }

    public func arguments() -> [String] {
        var a = ["--owner", ownerHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "--relay", relayURL]
        if !workdir.isEmpty { a += ["--workdir", workdir] }
        if !responder.isEmpty { a += ["--responder", responder] }
        return a
    }

    /// Wrap a daemon command so its stdout is line-buffered (Swift `print` is block-buffered
    /// into a file, so status would only appear at exit and be lost on SIGTERM). Uses
    /// coreutils `stdbuf` when present; otherwise runs the command unchanged.
    public static func lineBuffered(
        _ executable: String, _ arguments: [String], stdbuf: String = "/usr/bin/stdbuf"
    ) -> (executable: String, arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: stdbuf) else { return (executable, arguments) }
        return (stdbuf, ["-oL", "-eL", executable] + arguments)
    }

    public static func load(_ paths: HuginnPaths) -> BridgeSettings {
        guard let d = FileManager.default.contents(atPath: paths.bridgeFile),
            let s = try? JSONDecoder().decode(BridgeSettings.self, from: d)
        else { return BridgeSettings() }
        return s
    }

    public func save(_ paths: HuginnPaths) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(self) else { return false }
        try? FileManager.default.createDirectory(atPath: paths.configDir, withIntermediateDirectories: true)
        return (try? d.write(to: URL(fileURLWithPath: paths.bridgeFile), options: .atomic)) != nil
    }
}

/// Relay URL policy shared by Bridge and Buzz: wss:// anywhere, plaintext ws:// only on
/// loopback (port of `ConfigurationStore.validateRelayOverride`).
public enum RelayURL {
    public enum Problem: Error, Equatable {
        case empty, invalidURL, unsupportedScheme, plaintextOffLoopback
        public var message: String {
            switch self {
            case .empty: return "required (e.g. wss://relay.example.com)"
            case .invalidURL: return "that isn't a URL."
            case .unsupportedScheme: return "use a wss:// (or loopback ws://) WebSocket URL."
            case .plaintextOffLoopback: return "plaintext ws:// is only allowed for a relay on this machine — use wss://."
            }
        }
    }

    public static func validate(_ raw: String) -> Result<URL, Problem> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.empty) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return .failure(.invalidURL)
        }
        switch scheme {
        case "wss": return .success(url)
        case "ws":
            let loop = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
            return loop ? .success(url) : .failure(.plaintextOffLoopback)
        default: return .failure(.unsupportedScheme)
        }
    }
}
