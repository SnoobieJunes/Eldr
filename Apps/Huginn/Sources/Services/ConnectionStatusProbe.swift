import Foundation

/// Probes the local services Huginn coordinates so the Config UI can answer the two
/// questions the wizard leaves open — "is anything actually running?" and "on what
/// port?" — *honestly*:
///
///   • `eldr-acp` is **not a daemon**. A harness (Xcode, OpenClaw, sybilclaw) spawns it
///     over stdio on demand and it exits with the session, so there is nothing of ours
///     running between sessions. The most we can truthfully show is when it last ran —
///     the agent log file's modification time.
///   • sybilclaw's **gateway** (default :18789) and **contextgraph** (default :8302)
///     are the long-running daemons-on-a-port. We probe each with a plain HTTP GET: a
///     genuine reply (even an HTTP error status, or a WebSocket-upgrade rejection)
///     proves something is listening; a network-layer failure — refused, unreachable,
///     DNS failure, offline, timed out — means it's down. We never speak either
///     service's own protocol here — this is liveness only.
@MainActor
final class ConnectionStatusProbe: ObservableObject {
    enum Reachability: Equatable, Sendable {
        case unknown
        case checking
        case up
        case down(String)
    }

    @Published var gateway: Reachability = .unknown
    /// WS-B3: contextgraph's REST endpoint (default :8302), probed the same way as
    /// the gateway, for the Configuration tab's consolidated Status section.
    @Published var contextGraph: Reachability = .unknown
    /// When the agent last ran, inferred from the log file's mtime (best-effort: the
    /// launcher tees the agent's stderr there on every spawn). `nil` = never / no log.
    @Published var lastAgentActivity: Date?

    /// Liveness probe for the sybilclaw gateway. Huginn ships unsandboxed, so a
    /// localhost request is permitted.
    func probeGateway(host: String = "127.0.0.1", port: Int) async {
        gateway = .checking
        guard port > 0, port <= 65_535, let url = URL(string: "http://\(host):\(port)/") else {
            gateway = .down("Port \(port) is out of range")
            return
        }
        gateway = await Self.probeHTTP(url: url, notListening: "Nothing listening on :\(port)")
    }

    /// WS-B3: liveness probe for the contextgraph REST endpoint. Takes the raw
    /// configured endpoint string (e.g. "http://localhost:8302") rather than
    /// host/port — unlike the gateway, this one is a user-typed full URL
    /// (`ConfigurationStore.contextGraphURL`).
    func probeContextGraph(urlString: String) async {
        contextGraph = .checking
        guard let url = URL(string: urlString) else {
            contextGraph = .down("Not a valid URL")
            return
        }
        contextGraph = await Self.probeHTTP(
            url: url, notListening: "Nothing listening at \(urlString)")
    }

    /// Shared HTTP liveness probe: issues one GET and classifies the outcome.
    private static func probeHTTP(url: URL, notListening: String) async -> Reachability {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.5
        do {
            _ = try await URLSession.shared.data(for: request)
            return .up  // any HTTP response (incl. an error status) means something is listening
        } catch let error as URLError {
            return classify(error.code, notListening: notListening)
        } catch {
            return .down(error.localizedDescription)
        }
    }

    /// Classify a `URLError` code into up/down. `.up` ONLY for codes that can occur
    /// exclusively AFTER a peer actually answered the connection — a non-HTTP/garbled
    /// reply, or a TLS handshake that got far enough to fail on the certificate.
    /// Everything else (refused, unreachable, DNS failure, offline, cancelled, timed
    /// out, or any other/unknown code) is `.down`.
    ///
    /// This replaces a prior blanket `default: .up` that treated ANY URLError other
    /// than the three most obvious "refused" codes as proof of life — which silently
    /// misclassified `.timedOut`-adjacent conditions like `.dnsLookupFailed`,
    /// `.notConnectedToInternet`, `.resourceUnavailable`, `.cancelled`, and plain
    /// `.unknown` as "up". Extracted as a pure, `nonisolated` function (no network, no
    /// timer) so the fix — and the false-positive class it closes — is unit-testable
    /// headlessly (see `ConnectionStatusProbeTests`).
    nonisolated static func classify(_ code: URLError.Code, notListening: String) -> Reachability {
        switch code {
        case .cannotParseResponse, .badServerResponse, .zeroByteResource,
            .cannotDecodeContentData, .cannotDecodeRawData,
            .secureConnectionFailed, .serverCertificateHasBadDate,
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired:
            // The connection was established (or a TLS handshake at least started)
            // and something answered — just not with a clean HTTP response.
            return .up
        case .timedOut:
            return .down("\(notListening) (timed out)")
        default:
            // .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
            // .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
            // .cancelled, .unknown, etc. — genuinely not reachable. Fail toward "down"
            // on anything we don't explicitly recognize as proof of life.
            return .down(notListening)
        }
    }

    /// Refresh the agent's "last ran" timestamp from the log file's mtime.
    func refreshAgentActivity(logFile: String) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFile)
        lastAgentActivity = attrs?[.modificationDate] as? Date
    }
}
