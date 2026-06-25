import Foundation

/// Probes the local services Huginn coordinates so the Config UI can answer the two
/// questions the wizard leaves open — "is anything actually running?" and "on what
/// port?" — *honestly*:
///
///   • `eldr-acp` is **not a daemon**. A harness (Xcode, OpenClaw, sybilclaw) spawns it
///     over stdio on demand and it exits with the session, so there is nothing of ours
///     running between sessions. The most we can truthfully show is when it last ran —
///     the agent log file's modification time.
///   • sybilclaw's **gateway** is the long-running daemon-on-a-port (default :18789).
///     We probe it with a plain HTTP GET: any reply (even a WebSocket-upgrade rejection)
///     proves something is listening; "connection refused" means it's down. We never
///     speak the gateway protocol here — this is liveness only.
@MainActor
final class ConnectionStatusProbe: ObservableObject {
    enum Reachability: Equatable, Sendable {
        case unknown
        case checking
        case up
        case down(String)
    }

    @Published var gateway: Reachability = .unknown
    /// When the agent last ran, inferred from the log file's mtime (best-effort: the
    /// launcher tees the agent's stderr there on every spawn). `nil` = never / no log.
    @Published var lastAgentActivity: Date?

    /// Liveness probe for the sybilclaw gateway. `.up` on any HTTP reply, `.down` on a
    /// refused connection or timeout. Huginn ships unsandboxed, so a localhost request
    /// is permitted.
    func probeGateway(host: String = "127.0.0.1", port: Int) async {
        gateway = .checking
        guard port > 0, port <= 65_535, let url = URL(string: "http://\(host):\(port)/") else {
            gateway = .down("Port \(port) is out of range")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        do {
            _ = try await URLSession.shared.data(for: request)
            gateway = .up  // any HTTP response means something is listening
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                gateway = .down("Nothing listening on :\(port)")
            case .timedOut:
                gateway = .down("No response on :\(port) (timed out)")
            default:
                // A reset / non-HTTP reply still means a server is there.
                gateway = .up
            }
        } catch {
            gateway = .down(error.localizedDescription)
        }
    }

    /// Refresh the agent's "last ran" timestamp from the log file's mtime.
    func refreshAgentActivity(logFile: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFile)
        lastAgentActivity = attrs?[.modificationDate] as? Date
    }
}
