#if os(macOS)

import A2ACore
import A2AServer
import Foundation
import Network

/// Typed failures `A2AHTTPServer` itself raises (distinct from `NWError`s the
/// underlying socket layer can throw out of `start()`).
public enum A2AHTTPServerError: Error, Sendable, Equatable {
    case alreadyStarted
}

/// The A2A HTTP(S) JSON-RPC 1.0 binding's server side: a loopback-only, bearer-
/// authenticated HTTP/1.1 listener in front of a transport-agnostic `A2AServer`.
///
/// PRIVACY RULES enforced here (hard requirements, not defaults to be relaxed by a
/// caller): the listener binds `127.0.0.1` only — `NWParameters.requiredLocalEndpoint`
/// pins the loopback host so the socket layer itself cannot be coaxed into binding a
/// non-loopback address — and every route, including the agent card, requires a
/// valid bearer token. There is no TLS: loopback traffic never leaves the device, so
/// there is nothing on the wire for TLS to protect against.
///
/// Connection handling is intentionally simple for v1: one HTTP request per TCP
/// connection (`Connection: close` on every response). A production multi-request
/// keep-alive binding is future work, not a v1.0 requirement — the SDK's own
/// `A2AClient`/`HTTPJSONRPCTransport` doesn't need it (a fresh `URLSession` request
/// opens its own connection per call already).
public actor A2AHTTPServer {
    private let server: A2AServer
    private let card: A2AAgentCard
    private let authenticator: BearerAuthenticator
    private let requestedPort: UInt16

    private var listener: NWListener?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    /// `port: 0` (the default) binds an ephemeral loopback port; `start()` returns
    /// whatever port was actually bound.
    public init(
        server: A2AServer, card: A2AAgentCard, authenticator: BearerAuthenticator,
        port: UInt16 = 0
    ) {
        self.server = server
        self.card = card
        self.authenticator = authenticator
        self.requestedPort = port
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil else { throw A2AHTTPServerError.alreadyStarted }

        let parameters = NWParameters.tcp
        let port: NWEndpoint.Port =
            requestedPort == 0 ? .any : (NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        // Pin the local endpoint to loopback so this listener can NEVER end up bound
        // to a non-loopback interface, regardless of what port is requested.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.adopt(connection) }
        }

        let resolvedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // NWListener invokes this handler serially; only the first .ready or
            // .failed decides the continuation.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        return resolvedPort
    }

    public func stop() async {
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        listener?.cancel()
        listener = nil
    }

    // MARK: - Per-connection handling

    private func adopt(_ connection: NWConnection) {
        let id = UUID()
        connectionTasks[id] = Task { [weak self] in
            await self?.serve(connection)
            await self?.connectionEnded(id)
        }
    }

    private func connectionEnded(_ id: UUID) {
        connectionTasks[id] = nil
    }

    /// One request per connection: read until a full request is parsed (or the
    /// connection closes / a parse error makes that impossible), route it, respond,
    /// close.
    private func serve(_ connection: NWConnection) async {
        connection.start(queue: .global())
        defer { connection.cancel() }

        var buffer = Data()
        var request: MinimalHTTPRequest?
        do {
            while request == nil {
                guard let chunk = try await Self.receive(connection) else {
                    return  // connection closed (EOF) before a full request arrived
                }
                guard !chunk.isEmpty else { continue }  // spurious empty callback; retry
                buffer.append(chunk)
                request = try MinimalHTTP.parse(buffer: buffer)
            }
        } catch {
            try? await Self.send(MinimalHTTP.response(status: 400, reason: "Bad Request"), over: connection)
            return
        }
        guard let request else { return }

        await route(request, over: connection)
    }

    private func route(_ request: MinimalHTTPRequest, over connection: NWConnection) async {
        // PRIVACY RULE: bearer auth required on EVERY route, including the agent
        // card — no body detail on failure, just 401.
        guard authenticator.authorize(request.headers["authorization"]) else {
            try? await Self.send(MinimalHTTP.response(status: 401, reason: "Unauthorized"), over: connection)
            return
        }

        if request.method == "GET", request.target == A2AAgentCard.wellKnownPath {
            guard let body = try? A2AWireCodec.encode(card) else {
                try? await Self.send(
                    MinimalHTTP.response(status: 500, reason: "Internal Server Error"),
                    over: connection)
                return
            }
            try? await Self.send(
                MinimalHTTP.response(
                    status: 200, reason: "OK",
                    headers: [("Content-Type", "application/json")], body: body),
                over: connection)
            return
        }

        guard request.method == "POST", request.target == "/a2a" || request.target == "/" else {
            try? await Self.send(MinimalHTTP.response(status: 404, reason: "Not Found"), over: connection)
            return
        }

        let rpcLine = String(decoding: request.body, as: UTF8.self)
        let context = A2ARequestContext(
            declaredVersion: request.headers[A2AVersion.headerName.lowercased()],
            isAuthenticated: true)

        guard let response = await server.handle(rpcLine: rpcLine, context: context) else {
            try? await Self.send(MinimalHTTP.response(status: 204, reason: "No Content"), over: connection)
            return
        }

        switch response {
        case .single(let line):
            try? await Self.send(
                MinimalHTTP.response(
                    status: 200, reason: "OK",
                    headers: [("Content-Type", "application/json")], body: Data(line.utf8)),
                over: connection)
        case .stream(let lines):
            do {
                try await Self.send(MinimalHTTP.sseHead(), over: connection)
                for await line in lines {
                    try await Self.send(MinimalHTTP.sseFrame(line), over: connection)
                }
            } catch {
                // Peer went away mid-stream; nothing more to do — `serve`'s defer
                // closes the connection either way.
            }
        }
    }

    // MARK: - Socket plumbing

    private static func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data, contentContext: .defaultMessage, isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// One inbound chunk (up to 64 KiB). `nil` means the connection closed with no
    /// more data.
    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

#endif
