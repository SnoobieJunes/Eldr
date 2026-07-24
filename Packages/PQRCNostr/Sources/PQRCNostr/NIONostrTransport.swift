// SPDX-License-Identifier: Apache-2.0
#if os(Linux)
import Foundation
import PQRCCore

// WS-L5 — the Linux `RelayTransport`. `NostrWebSocketTransport` (URLSession) compiles on Linux
// but can never connect ("WebSockets not supported by libcurl"), so a Linux node speaks NIP-01
// over `NIOWebSocketChannel` (SwiftNIO WebSocket + NIOSSL) instead. Deliberately STANDALONE —
// it reuses the shared `NostrWire` codec but does NOT touch the intricate, proven Apple
// transport (adaptive backoff / App Nap / NIP-11 learning live there and are not needed for a
// headless node's first connection). It implements the three no-default `RelayTransport`
// requirements — publish (with OK), subscribe (REQ→EVENT stream), authenticate (NIP-42) — and
// leaves currentStatus/checkConnection/maxContentLength/transportEvents to protocol defaults.
public actor NIONostrTransport: RelayTransport {
    public nonisolated let url: URL
    private var channel: NIOWebSocketChannel
    private let responseTimeout: Duration
    private var receiveTask: Task<Void, Never>?
    private var connected = false
    private var statusState: RelayStatus = .disconnected

    /// publish() waits here for the relay's ["OK", id, …], keyed by event id.
    private var pendingOKs: [String: CheckedContinuation<PublishAck, any Error>] = [:]
    /// Live subscriptions, keyed by our generated subscription id.
    private var subscriptions: [String: AsyncThrowingStream<NostrEvent, Error>.Continuation] = [:]
    /// NIP-42: relays send ["AUTH", challenge] unprompted on connect.
    private var authChallenge: String?
    private var challengeWaiters: [UUID: CheckedContinuation<String, any Error>] = [:]
    private var nextSubscriptionNumber = 0

    public init(url: URL, responseTimeout: Duration = .seconds(5)) {
        self.url = url
        self.channel = NIOWebSocketChannel()
        self.responseTimeout = responseTimeout
    }

    /// Dial the relay and start the receive loop. Returns self so call sites match the
    /// URLSession transport's `transports: [await transport.connect()]` shape.
    @discardableResult
    public func connect() async throws -> NIONostrTransport {
        try await ensureConnected()
        return self
    }

    /// Dial the relay if not currently connected, (re)creating a FRESH channel each time — the
    /// NIO channel's inbound stream is single-use, so a redial can't reuse it. The messenger's
    /// recovery loop drives publish/subscribe after a drop and each call lands here, honoring the
    /// Apple transport's lazy-`ensureConnected` redial contract (so one blip is not fatal).
    private func ensureConnected() async throws {
        if connected { return }
        receiveTask?.cancel()
        await channel.close()  // tear down the stale channel (idempotent) before redialing
        let fresh = NIOWebSocketChannel()
        try await fresh.connect(url: url)
        channel = fresh
        connected = true
        statusState = .connected
        let inbound = fresh.inboundText()
        receiveTask = Task { [weak self] in
            for await line in inbound {
                guard let self else { return }
                if let message = NostrWire.decodeRelay(line) {
                    await self.dispatch(message)
                }
            }
            await self?.handleDisconnect()
        }
    }

    public func currentStatus() async -> RelayStatus { statusState }

    public func publish(_ event: NostrEvent) async throws -> PublishAck {
        try await ensureConnected()
        try await channel.send(text: NostrWire.encode(.event(event)))
        return try await awaitOK(eventID: event.id, error: .publishDropped)
    }

    public func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        try? await ensureConnected()  // best-effort redial; a still-dead channel fails the send below
        nextSubscriptionNumber += 1
        let subscriptionID = "pqrc-sub-\(nextSubscriptionNumber)"
        let (stream, continuation) = AsyncThrowingStream<NostrEvent, Error>.makeStream()
        subscriptions[subscriptionID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.endSubscription(subscriptionID) }
        }
        // The relay streams stored events, then EOSE, then live — so EOSE needs no surfacing.
        do {
            let text = try NostrWire.encode(
                .req(subscriptionID: subscriptionID, filters: filters))
            try await channel.send(text: text)
        } catch {
            subscriptions.removeValue(forKey: subscriptionID)
            continuation.finish(throwing: error)
        }
        return stream
    }

    public func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {
        try await ensureConnected()
        // The challenge may already be here (relays send it on connect) or still in flight.
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
        // Kind-22242 answer (NIP-42). The wall clock is a transport protocol field here, not a
        // key-schedule input (SPEC §5.2 bans clocks from key derivation, not from AUTH recency).
        let authEvent = try keypair.sign(
            NostrEvent(
                pubkey: keypair.publicKeyHex,
                createdAt: Int64(Date().timeIntervalSince1970),
                kind: 22242,
                tags: [["relay", url.absoluteString], ["challenge", challenge]],
                content: ""),
            randomSource: randomSource)
        try await channel.send(text: NostrWire.encode(.auth(authEvent)))
        // The relay's OK verdict is authoritative: a rejected AUTH must THROW (fail-closed),
        // never report success — otherwise the messenger's auth-recovery loop never backs off
        // and spins forever against an AUTH-gated relay. Mirrors NostrWebSocketTransport.
        let ack = try await awaitOK(eventID: authEvent.id, error: .notAuthenticated)
        guard ack.accepted else { throw NostrError.notAuthenticated }
    }

    // MARK: - Inbound dispatch

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
        case .closed(let subscriptionID, let reason):
            let continuation = subscriptions.removeValue(forKey: subscriptionID)
            if reason.contains("auth-required") {
                continuation?.finish(throwing: NostrError.authRequired)
            } else {
                continuation?.finish()
            }
        case .eose:
            break  // stored-then-live: keep the stream open for live events.
        case .notice:
            break  // NOTICEs carry no state.
        }
    }

    private func handleDisconnect() {
        connected = false
        statusState = .disconnected
        for (_, continuation) in pendingOKs { continuation.resume(throwing: NostrError.publishDropped) }
        pendingOKs.removeAll()
        for (_, waiter) in challengeWaiters { waiter.resume(throwing: NostrError.notAuthenticated) }
        challengeWaiters.removeAll()
        for (_, continuation) in subscriptions { continuation.finish() }
        subscriptions.removeAll()
    }

    private func endSubscription(_ subscriptionID: String) async {
        subscriptions[subscriptionID] = nil
        if let text = try? NostrWire.encode(.close(subscriptionID: subscriptionID)) {
            try? await channel.send(text: text)
        }
    }

    private func awaitOK(eventID: String, error: NostrError) async throws -> PublishAck {
        let timeout = responseTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pendingOKs[eventID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeoutPendingOK(eventID, error: error)
            }
        }
    }

    private func timeoutPendingOK(_ eventID: String, error: NostrError) {
        pendingOKs.removeValue(forKey: eventID)?.resume(throwing: error)
    }

    private func timeoutChallengeWaiter(_ waiterID: UUID) {
        challengeWaiters.removeValue(forKey: waiterID)?.resume(throwing: NostrError.notAuthenticated)
    }
}
#endif
