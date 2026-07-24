// SPDX-License-Identifier: Apache-2.0
//
//  NostrWebSocketTransport.swift
//  PQRCNostr
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession/URLSessionWebSocketTask live here on Linux
#endif
#if canImport(OSLog)
import OSLog
#endif
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
    public nonisolated let url: URL  // e.g. wss://relay.lerants.com or ws://127.0.0.1:7777

    private var socket: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    /// Periodic WebSocket ping so an idle connection isn't silently dropped by
    /// an intermediary (Cloudflare proxies close idle WebSockets after ~100 s).
    private var pingLoop: Task<Void, Never>?
    private let keepalivePing: Duration = .seconds(30)
    /// Mac/Catalyst ONLY: an App Nap assertion held for the life of the socket.
    /// On a Mac a visible-but-unfocused window gets napped — the OS suspends the
    /// app's `URLSessionWebSocketTask` (Console: "Suspending task"), so frames
    /// stop arriving and the relay silently stops syncing until the user clicks
    /// back. `beginActivity(.userInitiated)` keeps the task running while the
    /// window is OPEN, not only when frontmost. The token is retained here and
    /// released on teardown/disconnect; nil while not connected. iPhone never
    /// takes this path (see `beginVisibilityActivity`), so its battery-preserving
    /// background suspend (DEVIATIONS D6) is unchanged.
    private var visibilityActivity: (any NSObjectProtocol)?
    /// Circuit breaker: set after a connection/handshake failure so we stop
    /// redialing on every operation (a down relay otherwise logs a `-1011` per
    /// attempt). Cleared after an ADAPTIVE cooldown; the next operation redials.
    private var connectionBackoff = false
    /// Consecutive-failure counter driving the exponential cooldown. Reset to 0
    /// the instant a relay frame proves the socket is live — so a brief blip
    /// recovers in ~1s instead of being locked out for a flat 30s, while a
    /// genuinely-down relay still backs off to the cap and stops hammering.
    private var backoffAttempt = 0
    /// publish() waits here for the relay's ["OK", id, …], keyed by event id.
    private var pendingOKs: [String: CheckedContinuation<PublishAck, any Error>] = [:]
    /// Live subscriptions, keyed by our generated subscription id.
    private var subscriptions: [String: AsyncThrowingStream<NostrEvent, Error>.Continuation] = [:]
    /// NIP-42 challenge state: relays send ["AUTH", challenge] unprompted on
    /// connect; authenticate() may run before or after it arrives.
    private var authChallenge: String?
    private var challengeWaiters: [UUID: CheckedContinuation<String, any Error>] = [:]
    private var nextSubscriptionNumber = 0
    /// Connection health for the Settings indicator. Set `.connected` the
    /// instant any relay frame arrives (proves the socket is live), `.failed`
    /// on teardown/backoff. Purely observational — never gates delivery.
    private var statusState: RelayStatus = .disconnected
    /// Best-known event content limit (bytes) for adaptive chunk sizing: seeded
    /// from NIP-11 `max_content_length`, then lowered if the relay ever rejects
    /// with "content is too large: …, max is N" (some relays advertise more than
    /// they enforce — exactly what bit us). nil until learned.
    private var knownMaxContent: Int?
    private var nip11Attempted = false
    /// B2 diagnostics seam: live subscribers to this transport's connection-lifecycle
    /// events (Huginn's Relay tab / Inspector forward these into `DiagnosticsLog`'s
    /// `.relay` category). Purely observational, keyed so multiple observers can attach.
    private var eventContinuations: [UUID: AsyncStream<RelayTransportEvent>.Continuation] = [:]

    /// How long publish/authenticate wait for the relay before giving up.
    /// A dropped OK then surfaces as `publishDropped`, which the messenger's
    /// outbox treats exactly like simulator chaos: back off and retry.
    private let responseTimeout: Duration

    /// Adaptive reconnect cooldown bounds. The delay after the Nth consecutive
    /// failure is `min(base · 2^N, max)`: a single blip waits ~`base`, a
    /// persistent outage climbs to `max` and holds there.
    private let reconnectBaseBackoff: Duration
    private let reconnectMaxBackoff: Duration

    public init(
        url: URL, responseTimeout: Duration = .seconds(5),
        reconnectBaseBackoff: Duration = .seconds(1),
        reconnectMaxBackoff: Duration = .seconds(30)
    ) {
        self.url = url
        self.responseTimeout = responseTimeout
        self.reconnectBaseBackoff = reconnectBaseBackoff
        self.reconnectMaxBackoff = reconnectMaxBackoff
    }

    /// Cooldown for the current consecutive-failure count, clamped to the cap.
    private var currentBackoff: Duration {
        // Clamp the shift so 2^N can't overflow on a long outage.
        let factor = Double(1 << min(backoffAttempt, 16))
        let scaled = reconnectBaseBackoff * factor
        return scaled < reconnectMaxBackoff ? scaled : reconnectMaxBackoff
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
        statusState = .disconnected
    }

    public func currentStatus() async -> RelayStatus {
        if connectionBackoff { return .failed("Relay unreachable — retrying shortly") }
        return statusState
    }

    /// B2: a live stream of this transport's connection-lifecycle events. Each caller
    /// gets its own stream (fan-out via a keyed continuation dictionary); the stream
    /// ends when the caller stops consuming (normal `AsyncStream` teardown) — it is
    /// NEVER the only reference keeping this actor's socket alive.
    public func transportEvents() async -> AsyncStream<RelayTransportEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RelayTransportEvent>.makeStream()
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return stream
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    /// Fan out one lifecycle event to every live subscriber, and log it (host only —
    /// never event content; anything payload-adjacent like a subscription id or a
    /// relay-supplied reason string is `.private` per CLAUDE.md invariant 12).
    private func emit(_ event: RelayTransportEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
        let host = url.host ?? "unknown"
        switch event {
        case .connecting:
            Self.log.log("relay connecting host=\(host, privacy: .public)")
        case .connected:
            Self.log.log("relay connected host=\(host, privacy: .public)")
        case .disconnected(let reason):
            Self.log.log(
                "relay disconnected host=\(host, privacy: .public) reason=\(reason ?? "-", privacy: .private)"
            )
        case .eose(let subscriptionID):
            Self.log.log(
                "relay EOSE host=\(host, privacy: .public) sub=\(subscriptionID, privacy: .private)")
        case .authChallenge:
            Self.log.log("relay AUTH challenge host=\(host, privacy: .public)")
        case .authenticated:
            Self.log.log("relay AUTH ok host=\(host, privacy: .public)")
        case .authFailed(let reason):
            Self.log.log(
                "relay AUTH failed host=\(host, privacy: .public) reason=\(reason ?? "-", privacy: .private)"
            )
        case .error(let message):
            Self.log.error(
                "relay error host=\(host, privacy: .public) message=\(message, privacy: .private)")
        }
    }

    /// Dial if needed and wait briefly for the receive loop to confirm a live
    /// frame. In the running app the messenger already holds live subscriptions
    /// on this socket, so a healthy relay confirms within a few hundred ms.
    public func checkConnection() async -> RelayStatus {
        if connectionBackoff { return .failed("Relay unreachable — cooling down before retry") }
        ensureConnected()
        for _ in 0..<40 {  // up to ~4s
            switch statusState {
            case .connected, .failed:
                return await currentStatus()
            case .connecting, .disconnected:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return await currentStatus()
    }

    // MARK: RelayTransport

    /// Diagnostics only: logs event KIND, byte SIZE, and the relay's reason —
    /// never message content (canary-safe). Lets a relay rejecting/timing out on
    /// large events surface in Console instead of vanishing into a retry loop.
    private static let log = Logger(subsystem: "chat.pqrc", category: "relay")

    public func publish(_ event: NostrEvent) async throws -> PublishAck {
        ensureConnected()
        guard let socket else { throw NostrError.publishDropped }
        let wire = try NostrWire.encode(.event(event))
        let bytes = wire.utf8.count
        do {
            try await socket.send(.string(wire))
        } catch {
            // Diagnostics carry the event SIZE (and the relay reason, which can
            // echo it) — both are size-metadata that padding exists to hide
            // (SPEC §7). In-process OSLogStore can read even `.private` values
            // (DEVIATIONS A1), so the only privacy-safe option is to compile
            // them out of shipping builds entirely. Devs see full detail with a
            // debugger attached; TestFlight/release leak nothing.
            #if DEBUG
                Self.log.error(
                    "publish send failed kind=\(event.kind) bytes=\(bytes) error=\(error.localizedDescription)")
            #endif
            throw error
        }
        do {
            let ack = try await awaitOK(eventID: event.id, timeoutError: .publishDropped)
            if !ack.accepted {
                learnContentLimit(fromRejection: ack.message)
                #if DEBUG
                    Self.log.error(
                        "publish rejected kind=\(event.kind) bytes=\(bytes) reason=\(ack.message ?? "(none)")")
                #endif
            }
            return ack
        } catch {
            #if DEBUG
                Self.log.error(
                    "publish no-OK kind=\(event.kind) bytes=\(bytes) error=\(error.localizedDescription)")
            #endif
            throw error
        }
    }

    public func maxContentLength() async -> Int? {
        if !nip11Attempted {
            nip11Attempted = true
            if let advertised = await fetchNIP11ContentLimit() {
                knownMaxContent = min(knownMaxContent ?? advertised, advertised)
            }
        }
        return knownMaxContent
    }

    /// Fetches the relay's NIP-11 document over HTTP(S) and returns its
    /// `limitation.max_content_length`, if present.
    private func fetchNIP11ContentLimit() async -> Int? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (url.scheme == "wss") ? "https" : "http"
        guard let httpURL = components.url else { return nil }
        var request = URLRequest(url: httpURL)
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limitation = json["limitation"] as? [String: Any]
        else { return nil }
        return (limitation["max_content_length"] as? NSNumber)?.intValue
    }

    /// Lowers the known limit when the relay rejects an oversized event
    /// ("content is too large: …, max is N") — so a relay that advertises more
    /// than it enforces is corrected after one rejection instead of looping.
    private func learnContentLimit(fromRejection message: String?) {
        guard let message, message.contains("too large"),
            let marker = message.range(of: "max is ")
        else { return }
        let digits = message[marker.upperBound...].prefix { $0.isNumber }
        guard let n = Int(digits) else { return }
        knownMaxContent = min(knownMaxContent ?? n, n)
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

    /// `RelayTransport` conformance: standard NIP-42 AUTH with no extra tags.
    public func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {
        try await authenticate(keypair: keypair, randomSource: randomSource, extraTags: [])
    }

    /// Perform NIP-42 AUTH. `extraTags` are appended to the standard
    /// `relay`/`challenge` tags — Buzz's owner-attested agent path requires the
    /// NIP-OA `["auth", owner, conditions, sig]` tag here so the relay's
    /// membership gate resolves the owner (see `NIPOA` and countdown-bot's
    /// `build_auth_event`). Empty for ordinary strfry/khatru relays.
    public func authenticate(
        keypair: NostrKeypair, randomSource: any RandomSource, extraTags: [[String]]
    ) async throws {
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
                tags: [["relay", url.absoluteString], ["challenge", challenge]] + extraTags,
                content: ""
            ), randomSource: randomSource)
        guard let socket else {
            emit(.authFailed(reason: "no socket"))
            throw NostrError.notAuthenticated
        }
        try await socket.send(.string(NostrWire.encode(.auth(authEvent))))
        let ack: PublishAck
        do {
            ack = try await awaitOK(eventID: authEvent.id, timeoutError: .notAuthenticated)
        } catch {
            // Either the response timeout fired or the socket dropped mid-handshake
            // (teardown resolves pendingOKs with its own error) — both surface the
            // same way here: no OK ever arrived.
            emit(.authFailed(reason: "no response"))
            throw error
        }
        guard ack.accepted else {
            emit(.authFailed(reason: ack.message))
            throw NostrError.notAuthenticated
        }
        emit(.authenticated)
    }

    // MARK: Socket lifecycle

    private func ensureConnected() {
        // In backoff after a failure: don't redial (operations fail fast, no
        // new handshake attempt, no console spam) until the cooldown clears.
        guard socket == nil, !connectionBackoff else { return }
        // waitsForConnectivity: on a phone the network comes and goes; let the
        // session hold the dial until a route exists instead of failing fast.
        let configuration = URLSessionConfiguration.default
        #if canImport(Darwin)
        configuration.waitsForConnectivity = true  // get-only on swift-corelibs (Linux)
        #endif
        let task = URLSession(configuration: configuration).webSocketTask(with: url)
        socket = task
        statusState = .connecting
        emit(.connecting)
        task.resume()
        // Mac/Catalyst: assert "user-initiated work in progress" so App Nap
        // doesn't suspend this socket when the window loses focus but stays
        // visible. No-op on iPhone (keeps the v1 background-suspend behavior).
        beginVisibilityActivity()
        receiveLoop = Task { [weak self] in
            while let self {
                guard await self.receiveOnce(task) else { break }
            }
        }
        pingLoop?.cancel()
        let interval = keepalivePing
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, await self.pingCurrentSocket() else { break }
            }
        }
    }

    /// Mac/Catalyst ONLY: take an App Nap assertion so a visible-but-unfocused
    /// window keeps its relay socket alive instead of being suspended. Gated on
    /// the "iOS app running on Mac" runtimes — a real iPhone/iPad falls through
    /// and keeps the v1 behavior (relay drains on foreground only, no background
    /// fetch — DEVIATIONS D6), so battery and the privacy "no presence beacon"
    /// posture are untouched. `.userInitiated` (the user has the window open and
    /// is messaging) rather than `.background`; we do NOT disable system sleep —
    /// only App Nap of THIS app while it's on screen. Idempotent: holds one
    /// token at a time for the life of the socket.
    private func beginVisibilityActivity() {
        // App Nap is an Apple-platform concept (ProcessInfo.beginActivity/isMacCatalystApp);
        // a headless Linux node has no window to keep awake, so this is inert there.
        #if canImport(Darwin)
        let onMac =
            ProcessInfo.processInfo.isMacCatalystApp
            || ProcessInfo.processInfo.isiOSAppOnMac
        guard onMac, visibilityActivity == nil else { return }
        visibilityActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated, reason: "Relay sync while window is open")
        #endif
    }

    /// Releases the App Nap assertion (Mac/Catalyst). No-op when none is held.
    private func endVisibilityActivity() {
        #if canImport(Darwin)
        guard let token = visibilityActivity else { return }
        ProcessInfo.processInfo.endActivity(token)
        visibilityActivity = nil
        #endif
    }

    /// Sends a keepalive ping on the live socket; false if there's no socket to
    /// ping (the ping loop then exits and a later redial starts a fresh one).
    private func pingCurrentSocket() -> Bool {
        guard let socket else { return false }
        socket.sendPing { _ in }  // pong/errors are handled by the receive loop's teardown
        return true
    }

    /// One receive + dispatch. Returns false when the socket is done.
    private func receiveOnce(_ task: URLSessionWebSocketTask) async -> Bool {
        do {
            let message = try await task.receive()
            // Any frame from the relay proves the socket is live: mark healthy
            // and reset the cooldown so the next failure backs off from scratch.
            let wasConnected = statusState == .connected
            statusState = .connected
            backoffAttempt = 0
            if !wasConnected { emit(.connected) }
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
            emit(.authChallenge)
            let waiters = challengeWaiters.values
            challengeWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: challenge) }
        case .event(let subscriptionID, let event):
            subscriptions[subscriptionID]?.yield(event)
        case .closed(let subscriptionID, let reason):
            // Relay-initiated end of subscription. If it's a NIP-42 auth gate
            // (khatru sends ["AUTH", challenge] alongside this), surface it as a
            // typed error so the caller authenticates and re-subscribes;
            // otherwise finish cleanly so consumers fall out of their loops.
            let continuation = subscriptions.removeValue(forKey: subscriptionID)
            if reason.contains("auth-required") {
                continuation?.finish(throwing: NostrError.authRequired)
            } else {
                continuation?.finish()
            }
        case .eose(let subscriptionID):
            emit(.eose(subscriptionID: subscriptionID))
        case .notice:
            break  // NOTICEs carry no state.
        }
    }

    /// Fails everything in flight so callers retry against a fresh socket.
    private func teardown(error: any Error) {
        receiveLoop?.cancel()
        receiveLoop = nil
        pingLoop?.cancel()
        pingLoop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        // Drop the App Nap assertion with the socket it was protecting; a redial
        // re-takes one. (Mac/Catalyst only; no-op elsewhere.)
        endVisibilityActivity()
        authChallenge = nil
        if error is CancellationError {
            emit(.disconnected(reason: nil))
        } else {
            let description = Self.describe(error)
            statusState = .failed(description)
            emit(.error(description))
            emit(.disconnected(reason: description))
        }
        for (_, continuation) in pendingOKs { continuation.resume(throwing: error) }
        pendingOKs.removeAll()
        for (_, waiter) in challengeWaiters { waiter.resume(throwing: error) }
        challengeWaiters.removeAll()
        for (_, continuation) in subscriptions { continuation.finish(throwing: error) }
        subscriptions.removeAll()
        // Enter a cooldown so we stop hammering an unreachable relay and stop
        // flooding the console with handshake errors. The messenger's outbox
        // still retries — it just fails fast (no redial) until this clears.
        if !connectionBackoff {
            connectionBackoff = true
            let delay = currentBackoff
            backoffAttempt += 1
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                await self?.clearBackoff()
            }
        }
    }

    private func clearBackoff() {
        connectionBackoff = false
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

    /// Short, user-facing reason for the Settings indicator (no payload data).
    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "No internet connection"
            case NSURLErrorTimedOut: return "Connection timed out"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "Can't reach this server"
            case NSURLErrorSecureConnectionFailed: return "Secure connection failed"
            default: return "Connection error (\(ns.code))"
            }
        }
        return "Connection lost"
    }
}
