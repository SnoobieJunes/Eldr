// SPDX-License-Identifier: Apache-2.0
#if canImport(Network)

import Foundation
import Network
import PQRCCore

/// The "pqrc-relay" server (APP-SPEC §4, stretch goal S2): a WebSocket
/// frontend that speaks the NIP-01 subset + NIP-42 AUTH and is backed by a
/// `LocalRelaySimulator` — so the wire behavior (store-and-forward,
/// replaceable events, anchor-relay kind-1059 gating, chaos injection) is the
/// exact same code the in-process test matrix already proves.
///
/// Intended uses:
/// - `swift run pqrc-relay` — a localhost relay two iOS simulators (or any
///   Nostr client, e.g. `nak`/`websocat`) can share for demos.
/// - In-process loopback target for the gated `WebSocket loopback` test suite
///   that runs the TEST-PLAN §7 transport conformance gate against the real
///   `NostrWebSocketTransport` client.
///
/// Debug/demo tooling only: it is NEVER compiled into a Release app build and
/// holds events in memory with no persistence. Production deployments use an
/// AUTH-gated strfry/khatru anchor relay (SPEC §9.1, §15) — see
/// docs/SETUP-GUIDE.md.
public actor NostrRelayServer {
    private let relay: LocalRelaySimulator
    private let requestedPort: UInt16
    private var listener: NWListener?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    /// `port: 0` binds an ephemeral port (loopback tests); `start()` returns
    /// the resolved one.
    public init(relay: LocalRelaySimulator, port: UInt16 = 7777) {
        self.relay = relay
        self.requestedPort = port
    }

    // MARK: Lifecycle

    /// Binds and starts accepting connections; returns the bound port.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard listener == nil else { throw NostrError.invalidEvent }
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
            throw NostrError.invalidEvent
        }
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.adopt(connection) }
        }
        // Wait for .ready so the caller can connect immediately after return.
        let resolved: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // NWListener invokes this handler serially; the first .ready or
            // failure decides the continuation, later states only log state.
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
        return resolved
    }

    public func stop() {
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        listener?.cancel()
        listener = nil
    }

    // MARK: Per-connection protocol loop

    private func adopt(_ connection: NWConnection) {
        let id = UUID()
        connectionTasks[id] = Task { [weak self] in
            await self?.serve(connection, id: id)
            await self?.connectionEnded(id)
        }
    }

    private func connectionEnded(_ id: UUID) {
        connectionTasks[id] = nil
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        let connectionID = id.uuidString
        connection.start(queue: .global())
        // NIP-42: challenge first, unprompted — the client cannot read any
        // kind-1059 envelope until it answers (anchor-relay rule, SPEC §9.1).
        let challenge = await relay.issueChallenge(connectionID: connectionID)
        try? await send(.auth(challenge: challenge), over: connection)

        var authedPubkey: String?
        var subscriptionTasks: [String: Task<Void, Never>] = [:]
        defer {
            for task in subscriptionTasks.values { task.cancel() }
            connection.cancel()
        }

        while !Task.isCancelled {
            guard let text = try? await receiveText(connection) else { break }
            // Unknown/malformed messages are ignored, never fatal (SPEC §12).
            guard let message = NostrWire.decodeClient(text) else { continue }
            switch message {
            case .event(let event):
                if let ack = try? await relay.handlePublish(event) {
                    try? await send(
                        .ok(eventID: ack.eventID, accepted: ack.accepted,
                            message: ack.message ?? ""),
                        over: connection)
                }
                // A thrown publish is the simulator's chaos drop: the relay
                // "never saw it", so no OK goes out and outboxes must retry.
            case .auth(let event):
                let verified = await relay.verifyAuth(connectionID: connectionID, authEvent: event)
                if verified { authedPubkey = event.pubkey }
                try? await send(
                    .ok(eventID: event.id, accepted: verified,
                        message: verified ? "" : "auth-required: bad challenge or signature"),
                    over: connection)
            case .req(let subscriptionID, let filters):
                subscriptionTasks[subscriptionID]?.cancel()
                let (backlog, live) = await relay.handleSubscribeSplit(
                    filters: filters, authedPubkey: authedPubkey)
                for event in backlog {
                    try? await send(.event(subscriptionID: subscriptionID, event), over: connection)
                }
                try? await send(.eose(subscriptionID: subscriptionID), over: connection)
                subscriptionTasks[subscriptionID] = Task {
                    do {
                        for try await event in live {
                            try await Self.sendStatic(
                                .event(subscriptionID: subscriptionID, event), over: connection)
                        }
                    } catch {
                        // Subscription or connection gone; loop ends.
                    }
                }
            case .close(let subscriptionID):
                subscriptionTasks.removeValue(forKey: subscriptionID)?.cancel()
            }
        }
    }

    // MARK: WebSocket plumbing

    private func send(_ message: NostrRelayMessage, over connection: NWConnection) async throws {
        try await Self.sendStatic(message, over: connection)
    }

    /// Static so subscription pump tasks can send without re-entering the actor.
    private static func sendStatic(
        _ message: NostrRelayMessage, over connection: NWConnection
    ) async throws {
        let text = try NostrWire.encode(message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8), contentContext: context, isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// One inbound WebSocket text frame; nil-throwing on close/cancel.
    private func receiveText(_ connection: NWConnection) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data,
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata,
                    metadata.opcode == .text
                else {
                    // Close frame or non-text traffic: treat as end of stream.
                    continuation.resume(throwing: NostrError.invalidEvent)
                    return
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

#endif
