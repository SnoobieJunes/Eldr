//
//  NostrWebSocketTransport.swift
//  PQRCNostr
//
//  Created by Auston on 6/12/26.
//

import Foundation
import PQRCCore

/// The real-network `RelayTransport`: NIP-01 over `URLSessionWebSocketTask`.
///
/// This is the production side of THE transport swap point (APP-SPEC §4):
/// `PQRCMessenger` cannot tell this apart from a `LocalRelayConnection`, and
/// the TEST-PLAN §7 conformance suite is the acceptance gate — run it against
/// any relay you intend to use (see `swapPoint_webSocket*` tests, gated so
/// the default test run stays network-free per CLAUDE.md).
///
/// Connection model: one instance = one WebSocket = one NIP-42 auth scope,
/// mirroring `LocalRelayConnection`. The socket dials lazily on first use (so
/// constructing a transport is free), or eagerly via `connect()`. On socket
/// failure every pending publish and subscription fails fast; the messenger's
/// outbox retry loop (APP-SPEC §13) is the recovery mechanism, and each retry
/// attempt redials a fresh socket.
public actor NostrWebSocketTransport: RelayTransport {
    public let url: URL  // e.g. wss://relay.lerants.com or ws://127.0.0.1:7777

    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    /// publish() waits here for the relay's ["OK", id, …], keyed by event id.
    private var pendingOKs: [String: CheckedContinuation<PublishAck, any Error>] = [:]
    /// Live subscriptions, keyed by our generated subscription id.
    private var subscriptions: [String: AsyncThrowingStream<NostrEvent, Error>.Continuation] = [:]
    /// NIP-42 challenge state: relays send ["AUTH", challenge] unprompted on
    /// connect; authenticate() may run before or after it arrives.
    private var authChallenge: String?
    private var challengeWaiters: [UUID: CheckedContinuation<String, any Error>] = [:]
    private var nextSubscriptionNumber = 0

    /// How long publish/authenticate wait for the relay before giving up.
    /// A dropped OK then surfaces as `publishDropped`, which the messenger's
    /// outbox treats exactly like simulator chaos: back off and retry.
    private let responseTimeout: Duration

    public init(url: URL, responseTimeout: Duration = .seconds(5)) {
        self.url = url
        self.responseTimeout = responseTimeout
    }

    /// Eagerly opens the socket and returns self, so call sites can write
    /// `transports: [await transport.connect()]` symmetrically with
    /// `LocalRelaySimulator.connect()`.
    @discardableResult
    public func connect() -> NostrWebSocketTransport {
        ensureConnected()
        return self
    }

    public func disconnect() {
        teardown(error: CancellationError())
    }

    // MARK: RelayTransport

    public func publish(_ event: NostrEvent) async throws -> PublishAck {
        ensureConnected()
        guard let socket else { throw NostrError.publishDropped }
        try await socket.send(.string(NostrWire.encode(.event(event))))
        return try await awaitOK(eventID: event.id, timeoutError: .publishDropped)
    }

    public func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        ensureConnected()
        nextSubscriptionNumber += 1
        let subscriptionID = "pqrc-sub-\(nextSubscriptionNumber)"
        let (stream, continuation) = AsyncThrowingStream<NostrEvent, Error>.makeStream()
        subscriptions[subscriptionID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.endSubscription(subscriptionID) }
        }
        // The relay streams stored events first, then EOSE, then live events —
        // which is exactly the protocol's "stored first, then live" contract,
        // so the EOSE marker itself needs no surfacing here.
        if let socket, let text = try? NostrWire.encode(.req(subscriptionID: subscriptionID, filters: filters)) {
            do {
                try await socket.send(.string(text))
            } catch {
                continuation.finish(throwing: error)
            }
        } else {
            continuation.finish(throwing: NostrError.publishDropped)
        }
        return stream
    }

    public func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {
        ensureConnected()
        // The challenge may already be here (relays send it on connect) or
        // still in flight — wait for it either way.
        let challenge: String
        if let authChallenge {
            challenge = authChallenge
        } else {
            let waiterID = UUID()
            let timeout = responseTimeout
            challenge = try await withCheckedThrowingContinuation { continuation in
                challengeWaiters[waiterID] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutChallengeWaiter(waiterID)
                }
            }
        }
        // Kind-22242 answer (NIP-42). The real wall clock is correct here:
        // relays check created_at recency, and AUTH timing is not part of any
        // key schedule (SPEC §5.2 bans clocks from key derivation, not from
        // transport-level protocol fields).
        let authEvent = try keypair.sign(
            NostrEvent(
                pubkey: keypair.publicKeyHex,
                createdAt: Int64(Date().timeIntervalSince1970),
                kind: 22242,
                tags: [["relay", url.absoluteString], ["challenge", challenge]],
                content: ""
            ), randomSource: randomSource)
        guard let socket else { throw NostrError.notAuthenticated }
        try await socket.send(.string(NostrWire.encode(.auth(authEvent))))
        let ack = try await awaitOK(eventID: authEvent.id, timeoutError: .notAuthenticated)
        guard ack.accepted else { throw NostrError.notAuthenticated }
    }

    // MARK: Socket lifecycle

    private func ensureConnected() {
        guard socket == nil else { return }
        // waitsForConnectivity: on a phone the network comes and goes; let the
        // session hold the dial until a route exists instead of failing fast.
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        let task = URLSession(configuration: configuration).webSocketTask(with: url)
        socket = task
        task.resume()
        receiveLoop = Task { [weak self] in
            while let self {
                guard await self.receiveOnce(task) else { break }
            }
        }
    }

    /// One receive + dispatch. Returns false when the socket is done.
    private func receiveOnce(_ task: URLSessionWebSocketTask) async -> Bool {
        do {
            let message = try await task.receive()
            let text: String
            switch message {
            case .string(let value):
                text = value
            case .data(let value):
                text = String(decoding: value, as: UTF8.self)
            @unknown default:
                return true
            }
            // Unknown/malformed relay messages are ignored, never fatal.
            if let parsed = NostrWire.decodeRelay(text) {
                dispatch(parsed)
            }
            return true
        } catch {
            teardown(error: error)
            return false
        }
    }

    private func dispatch(_ message: NostrRelayMessage) {
        switch message {
        case .ok(let eventID, let accepted, let text):
            pendingOKs.removeValue(forKey: eventID)?
                .resume(returning: PublishAck(eventID: eventID, accepted: accepted, message: text))
        case .auth(let challenge):
            authChallenge = challenge
            let waiters = challengeWaiters.values
            challengeWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: challenge) }
        case .event(let subscriptionID, let event):
            subscriptions[subscriptionID]?.yield(event)
        case .closed(let subscriptionID, _):
            // Relay-initiated end of subscription: finish cleanly so consumers
            // fall out of their `for try await` loops instead of hanging.
            subscriptions.removeValue(forKey: subscriptionID)?.finish()
        case .eose, .notice:
            break  // EOSE handled by stream ordering; NOTICEs carry no state.
        }
    }

    /// Fails everything in flight so callers retry against a fresh socket.
    private func teardown(error: any Error) {
        receiveLoop?.cancel()
        receiveLoop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        authChallenge = nil
        for (_, continuation) in pendingOKs { continuation.resume(throwing: error) }
        pendingOKs.removeAll()
        for (_, waiter) in challengeWaiters { waiter.resume(throwing: error) }
        challengeWaiters.removeAll()
        for (_, continuation) in subscriptions { continuation.finish(throwing: error) }
        subscriptions.removeAll()
    }

    private func endSubscription(_ subscriptionID: String) async {
        subscriptions[subscriptionID] = nil
        if let socket, let text = try? NostrWire.encode(.close(subscriptionID: subscriptionID)) {
            try? await socket.send(.string(text))
        }
    }

    // MARK: Timeout plumbing

    /// Parks a continuation in `pendingOKs` until `dispatch` resolves it with
    /// the relay's OK, or the timeout fires first. Single-resume is guaranteed
    /// by the dictionary: whoever `removeValue`s the continuation owns it.
    private func awaitOK(eventID: String, timeoutError: NostrError) async throws -> PublishAck {
        let timeout = responseTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pendingOKs[eventID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeoutPendingOK(eventID, error: timeoutError)
            }
        }
    }

    private func timeoutPendingOK(_ eventID: String, error: NostrError) {
        pendingOKs.removeValue(forKey: eventID)?.resume(throwing: error)
    }

    private func timeoutChallengeWaiter(_ waiterID: UUID) {
        challengeWaiters.removeValue(forKey: waiterID)?
            .resume(throwing: NostrError.notAuthenticated)
    }
}
