// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// Device-hosted relay over a `NearbyLink` (MultipeerConnectivity) — a "local
/// relay in your pocket" for crowded places with no trusted Wi-Fi (airport,
/// train, road trip). ONE device hosts (`NearbyRelayHost`, wrapping the same
/// `LocalRelaySimulator` engine the app already uses); companion devices connect
/// over the radio with `MultipeerRelayClient`, which is an ordinary
/// `RelayTransport` — nothing above it knows the relay lives on a peer's phone
/// instead of the internet. No router, no public relay, no third party.
///
/// Privacy: the host is a *trusted peer's device*, not a public server — it sees
/// the same thing any relay sees (gift-wrapped ciphertext + p-tags, never
/// content), and the kind-1059 anchor-relay rule still applies (a wrap is served
/// only to the AUTHed, p-tagged recipient), so the host can't fan a wrap to the
/// wrong companion. The radio itself authenticates nobody; all real guarantees
/// ride the seal + ratchet inside, exactly as on the internet relay path.
///
/// ONE exception to "host never sees content": the OPTIONAL AI-sharing path
/// (`ai_request`). When a companion explicitly opts into the host's AI, it sends
/// its own message text (egress-firewall-redacted — contact names → codenames)
/// to the host's model. That is content, by the companion's own choice and
/// consent; the relay/message-delivery path remains content-free.
///
/// The whole protocol runs against `LocalLinkSimulator` in tests; only the MC
/// radio adapter (`MultipeerNearbyLink`) needs hardware.

// MARK: - Wire frames

/// Frames exchanged between a relay HOST and its CLIENTS over a `NearbyLink`.
/// JSON, stable snake_case names, unknown fields tolerated (forward compat).
/// `event`/`filters` ride pre-encoded as `Data` (matching `LinkPayload`), so the
/// frame never double-encodes a nested model.
struct RelayHubFrame: Codable, Sendable {
    enum Kind: String, Codable {
        case hello                       // host → client on connect ("I'm a relay host")
        case authChallenge = "auth_challenge"  // host → client: NIP-42 challenge
        case auth                        // client → host: signed kind-22242 event
        case authOK = "auth_ok"          // host → client: AUTH accepted
        case req                         // client → host: subscribe
        case close                       // client → host: close a subscription
        case event                       // publish (c→h) / matched delivery (h→c)
        case eose                        // host → client: end of stored events
        case ok                          // host → client: publish ack
        case aiRequest = "ai_request"    // client → host: share-your-AI inference
        case aiResponse = "ai_response"  // host → client: inference reply (or error)
    }
    var kind: Kind
    var subID: String?
    var event: Data?
    var filters: Data?
    var eventID: String?
    var accepted: Bool?
    var message: String?
    var challenge: String?
    var aiID: String?
    var aiSystem: String?
    var aiPrompt: String?
    var aiReply: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case subID = "sub_id"
        case event, filters
        case eventID = "event_id"
        case accepted, message, challenge
        case aiID = "ai_id"
        case aiSystem = "ai_system"
        case aiPrompt = "ai_prompt"
        case aiReply = "ai_reply"
    }

    static func encodeEvent(_ e: NostrEvent) -> Data? { try? WireJSON.encoder().encode(e) }
    static func decodeEvent(_ d: Data) -> NostrEvent? {
        try? WireJSON.decoder().decode(NostrEvent.self, from: d)
    }
    static func encodeFilters(_ f: [NostrFilter]) -> Data? { try? WireJSON.encoder().encode(f) }
    static func decodeFilters(_ d: Data) -> [NostrFilter]? {
        try? WireJSON.decoder().decode([NostrFilter].self, from: d)
    }
}

/// `(system, prompt) -> reply`, or nil if this host offers no AI. Lets a host
/// share its inference (an iPhone's on-device Apple Intelligence, or a Mac's
/// Ollama) with companions over the same link. Injected by the app layer.
public typealias HubAIAnswer = @Sendable (_ system: String, _ prompt: String) async -> String?

/// `(pubkey hex) -> allowed`. Paired-contact allowlist gate for NIP-42 AUTH: a
/// peer's signed kind-22242 is accepted ONLY if its pubkey is approved here
/// (SPEC §0 — "no one other than the intended recipients"). The radio
/// authenticates a valid signature, but signature ≠ trust: a STRANGER in radio
/// range can sign a fresh key and self-AUTH, then publish into the host's store
/// and spend its shared AI (audit C-5 / G1). Gating AUTH behind the host owner's
/// paired contacts closes that abuse/metadata/DoS hole. Injected by the app
/// layer; defaults to allow-all where unwired so the relay-only path is
/// unchanged.
public typealias HubAuthorize = @Sendable (_ pubkeyHex: String) -> Bool

// MARK: - Host

/// Hosts a relay (and optionally shares an AI) to nearby companions over a
/// `NearbyLink`. Wraps the existing `LocalRelaySimulator` engine — same
/// store-and-forward, replaceable-event, and kind-1059 anchor-relay privacy.
public actor NearbyRelayHost {
    private let link: any NearbyLink
    private let relay: LocalRelaySimulator
    private let randomSource: any RandomSource
    private let aiAnswer: HubAIAnswer?
    private let authorize: HubAuthorize

    private var started = false
    private var pumpTask: Task<Void, Never>?
    private var authedPubkey: [NearbyPeerID: String] = [:]
    private var challenges: [NearbyPeerID: String] = [:]
    /// (peer, subID) -> the live-stream pump task, so CLOSE/disconnect can cancel.
    private var subTasks: [String: Task<Void, Never>] = [:]

    public init(
        link: any NearbyLink, relay: LocalRelaySimulator,
        randomSource: any RandomSource = SystemRandomSource(), aiAnswer: HubAIAnswer? = nil,
        authorize: @escaping HubAuthorize = { _ in true }
    ) {
        self.link = link
        self.relay = relay
        self.randomSource = randomSource
        self.aiAnswer = aiAnswer
        self.authorize = authorize
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        try await link.start()
        let events = await link.events()
        pumpTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    public func stop() async {
        guard started else { return }
        started = false
        pumpTask?.cancel()
        subTasks.values.forEach { $0.cancel() }
        subTasks.removeAll()
        authedPubkey.removeAll()
        challenges.removeAll()
        await link.stop()
    }

    private func key(_ peer: NearbyPeerID, _ subID: String) -> String { "\(peer.raw)|\(subID)" }

    private func handle(_ event: NearbyLinkEvent) async {
        switch event {
        case .connected(let peer):
            // Announce we're a host, and start NIP-42 AUTH so the companion can
            // read gift-wraps addressed to it.
            let challenge = randomSource.bytes(16).hexString
            challenges[peer] = challenge
            await send(.init(kind: .hello), to: peer)
            await send(.init(kind: .authChallenge, challenge: challenge), to: peer)
        case .disconnected(let peer):
            for (k, task) in subTasks where k.hasPrefix("\(peer.raw)|") {
                task.cancel()
                subTasks[k] = nil
            }
            authedPubkey[peer] = nil
            challenges[peer] = nil
        case .data(let data, let peer):
            guard let frame = try? WireJSON.decoder().decode(RelayHubFrame.self, from: data) else {
                return
            }
            await handleFrame(frame, from: peer)
        }
    }

    private func handleFrame(_ frame: RelayHubFrame, from peer: NearbyPeerID) async {
        switch frame.kind {
        case .auth:
            guard let challenge = challenges[peer], let blob = frame.event,
                let authEvent = RelayHubFrame.decodeEvent(blob),
                authEvent.kind == 22242,
                authEvent.firstTagValue("challenge") == challenge,
                NostrKeypair.verify(authEvent),
                // Signature ≠ trust (C-5): a valid signature only proves the peer
                // holds *some* key. Accept AUTH only from a paired contact the host
                // owner approved, so a stranger in radio range can't self-AUTH.
                // Failure is a SILENT drop — no authOK, the peer stays un-authed,
                // and the publish / subscribe / AI guards below reject it.
                authorize(authEvent.pubkey)
            else { return }
            challenges[peer] = nil
            authedPubkey[peer] = authEvent.pubkey
            await send(.init(kind: .authOK), to: peer)
        case .event:
            guard let blob = frame.event, let ev = RelayHubFrame.decodeEvent(blob) else { return }
            // Gate publish behind AUTH (mirroring the `req` and `ai_request`
            // gates): an un-authed / un-allowlisted peer must not be able to push
            // events into the host's store (abuse / metadata / DoS — C-5). Authed
            // companions are unaffected.
            guard authedPubkey[peer] != nil else {
                await send(
                    .init(
                        kind: .ok, eventID: ev.id, accepted: false, message: "Authenticate first."),
                    to: peer)
                return
            }
            let ack = (try? await relay.handlePublish(ev))
                ?? PublishAck(eventID: ev.id, accepted: false, message: "relay error")
            await send(
                .init(kind: .ok, eventID: ack.eventID, accepted: ack.accepted, message: ack.message),
                to: peer)
        case .req:
            guard let subID = frame.subID, let blob = frame.filters,
                let filters = RelayHubFrame.decodeFilters(blob)
            else { return }
            let (backlog, live) = await relay.handleSubscribeSplit(
                filters: filters, authedPubkey: authedPubkey[peer])
            for ev in backlog {
                if let d = RelayHubFrame.encodeEvent(ev) {
                    await send(.init(kind: .event, subID: subID, event: d), to: peer)
                }
            }
            await send(.init(kind: .eose, subID: subID), to: peer)
            let task = Task { [weak self] in
                do {
                    for try await ev in live {
                        guard let self, let d = RelayHubFrame.encodeEvent(ev) else { continue }
                        await self.send(.init(kind: .event, subID: subID, event: d), to: peer)
                    }
                } catch {}
            }
            subTasks[key(peer, subID)] = task
        case .close:
            if let subID = frame.subID, let task = subTasks.removeValue(forKey: key(peer, subID)) {
                task.cancel()
            }
        case .aiRequest:
            guard let aiID = frame.aiID else { return }
            // Gate inference behind AUTH (mirroring the `req` gate): an
            // unauthenticated peer can't spam the host's model — compute/battery
            // DoS. Authed companions are unaffected.
            guard authedPubkey[peer] != nil else {
                await send(
                    .init(kind: .aiResponse, message: "Authenticate first.", aiID: aiID), to: peer)
                return
            }
            let reply = await aiAnswer?(frame.aiSystem ?? "", frame.aiPrompt ?? "")
            await send(
                .init(
                    kind: .aiResponse, message: reply == nil ? "This host isn't sharing an AI." : nil,
                    aiID: aiID, aiReply: reply),
                to: peer)
        case .hello, .authChallenge, .authOK, .eose, .ok, .aiResponse:
            break  // host never receives these
        }
    }

    private func send(_ frame: RelayHubFrame, to peer: NearbyPeerID) async {
        guard let data = try? WireJSON.encoder().encode(frame) else { return }
        try? await link.send(data, to: peer)
    }
}

// MARK: - Client

/// A `RelayTransport` whose relay is a nearby device hosting `NearbyRelayHost`
/// over a `NearbyLink`. Also carries the optional "use the host's AI" path
/// (`requestAI`). Everything above this is the normal messenger; it never learns
/// the relay is a phone in someone's pocket. All waits resolve to a sensible
/// fallback after a timeout so a missing/slow host never hangs a caller.
public actor MultipeerRelayClient: RelayTransport {
    private let link: any NearbyLink
    private let randomSource: any RandomSource
    private let hostTimeout: Double

    private var started = false
    private var pumpTask: Task<Void, Never>?
    private var hostPeer: NearbyPeerID?
    private var challenge: String?
    private var hostWaiters: [String: CheckedContinuation<NearbyPeerID?, Never>] = [:]
    private var challengeWaiters: [String: CheckedContinuation<String?, Never>] = [:]
    private var pendingPublish: [String: CheckedContinuation<PublishAck, Never>] = [:]
    private var pendingAI: [String: CheckedContinuation<String?, Never>] = [:]
    // Token-keyed (NOT a single slot): concurrent / reconnect re-auths must not
    // overwrite and LEAK each other's continuation (a debug trap, a release hang).
    private var authWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var subStreams: [String: AsyncThrowingStream<NostrEvent, Error>.Continuation] = [:]
    // Retained so the client SELF-HEALS after a radio drop: on reconnect the host
    // issues a FRESH challenge, and we re-AUTH + re-subscribe automatically —
    // otherwise the companion silently stops receiving (the crowded-place bug).
    private var authKeypair: NostrKeypair?
    private var authRandom: (any RandomSource)?
    private var subFilters: [String: [NostrFilter]] = [:]

    public init(
        link: any NearbyLink, randomSource: any RandomSource = SystemRandomSource(),
        hostTimeoutSeconds: Double = 12
    ) {
        self.link = link
        self.randomSource = randomSource
        self.hostTimeout = hostTimeoutSeconds
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        try await link.start()
        let events = await link.events()
        pumpTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    public func stop() async {
        guard started else { return }
        started = false
        pumpTask?.cancel()
        await link.stop()
        hostWaiters.values.forEach { $0.resume(returning: nil) }
        hostWaiters = [:]
        challengeWaiters.values.forEach { $0.resume(returning: nil) }
        challengeWaiters = [:]
        for (id, cont) in pendingPublish {
            cont.resume(returning: PublishAck(eventID: id, accepted: false, message: "disconnected"))
        }
        pendingPublish = [:]
        authWaiters.values.forEach { $0.resume(returning: false) }
        authWaiters = [:]
        pendingAI.values.forEach { $0.resume(returning: nil) }
        pendingAI = [:]
        subStreams.values.forEach { $0.finish() }
        subStreams = [:]
        subFilters = [:]
        authKeypair = nil
        authRandom = nil
    }

    // MARK: RelayTransport

    public func publish(_ event: NostrEvent) async throws -> PublishAck {
        guard let host = await awaitHost(), let d = RelayHubFrame.encodeEvent(event) else {
            return PublishAck(eventID: event.id, accepted: false, message: "no nearby relay host")
        }
        await send(.init(kind: .event, event: d), to: host)
        let id = event.id
        let timeout = hostTimeout
        return await withCheckedContinuation { (cont: CheckedContinuation<PublishAck, Never>) in
            pendingPublish[id] = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.resolvePublishTimeout(id)
            }
        }
    }

    public func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        let subID = randomSource.bytes(8).hexString
        let (stream, continuation) = AsyncThrowingStream<NostrEvent, Error>.makeStream()
        subStreams[subID] = continuation
        subFilters[subID] = filters  // remembered so we can re-send REQ after a reconnect
        continuation.onTermination = { [weak self] _ in Task { await self?.closeSub(subID) } }
        guard let host = await awaitHost(), let d = RelayHubFrame.encodeFilters(filters) else {
            continuation.finish(throwing: PQRCError.relayUnreachable)
            return stream
        }
        await send(.init(kind: .req, subID: subID, filters: d), to: host)
        return stream
    }

    public func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {
        // Retain so we can re-AUTH automatically after a radio reconnect.
        authKeypair = keypair
        authRandom = randomSource
        guard let challenge = await awaitChallenge() else { throw NostrError.notAuthenticated }
        guard await sendAuth(keypair, challenge: challenge, randomSource: randomSource) else {
            throw PQRCError.relayUnreachable
        }
        let timeout = hostTimeout
        let token = randomSource.bytes(8).hexString
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            authWaiters[token] = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.resolveAuthTimeout(token)
            }
        }
        guard ok else { throw NostrError.notAuthenticated }
    }

    public func currentStatus() async -> RelayStatus {
        hostPeer == nil ? .connecting : .connected
    }
    public func checkConnection() async -> RelayStatus {
        _ = await awaitHost()
        return await currentStatus()
    }
    /// The radio carries discrete payloads with no NIP-11 limit; report the same
    /// generous ceiling the in-process relay does so chunking stays large.
    public func maxContentLength() async -> Int? { 64 * 1024 * 1024 }

    /// Share-the-host's-AI path (the app's "Nearby hub AI" provider). Returns the
    /// host's reply, or nil if no host / no AI / timeout.
    public func requestAI(system: String, prompt: String) async -> String? {
        guard let host = await awaitHost() else { return nil }
        let aiID = randomSource.bytes(8).hexString
        await send(.init(kind: .aiRequest, aiID: aiID, aiSystem: system, aiPrompt: prompt), to: host)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            pendingAI[aiID] = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                await self?.resolveAITimeout(aiID)
            }
        }
    }

    // MARK: Pump

    private func handle(_ event: NearbyLinkEvent) async {
        switch event {
        case .connected:
            break  // wait for the host's `hello` to identify which peer is the relay
        case .disconnected(let peer):
            if hostPeer == peer {
                hostPeer = nil
                challenge = nil  // a fresh challenge is issued on reconnect; never reuse a stale one
            }
        case .data(let data, let peer):
            guard let frame = try? WireJSON.decoder().decode(RelayHubFrame.self, from: data) else {
                return
            }
            handleFrame(frame, from: peer)
        }
    }

    private func handleFrame(_ frame: RelayHubFrame, from peer: NearbyPeerID) {
        switch frame.kind {
        case .hello:
            hostPeer = peer
            let waiters = hostWaiters
            hostWaiters = [:]
            waiters.values.forEach { $0.resume(returning: peer) }
        case .authChallenge:
            challenge = frame.challenge
            let waiters = challengeWaiters
            challengeWaiters = [:]
            if waiters.isEmpty {
                // No pending authenticate() → the host RE-issued a challenge on
                // reconnect. Re-AUTH automatically against the fresh one, else the
                // host drops us and we silently stop receiving gift-wraps.
                if let kp = authKeypair, let random = authRandom, let c = frame.challenge {
                    Task { [weak self] in await self?.sendAuth(kp, challenge: c, randomSource: random) }
                }
            } else {
                waiters.values.forEach { $0.resume(returning: frame.challenge) }
            }
        case .authOK:
            if authWaiters.isEmpty {
                // An auto-reauth (reconnect) just succeeded → re-send our active
                // subscriptions so the host serves them again (incl. our wraps).
                Task { [weak self] in await self?.resubscribeAll() }
            } else {
                let waiters = authWaiters
                authWaiters = [:]
                waiters.values.forEach { $0.resume(returning: true) }
            }
        case .ok:
            if let id = frame.eventID, let cont = pendingPublish.removeValue(forKey: id) {
                cont.resume(
                    returning: PublishAck(
                        eventID: id, accepted: frame.accepted ?? false, message: frame.message))
            }
        case .event:
            if let subID = frame.subID, let blob = frame.event,
                let ev = RelayHubFrame.decodeEvent(blob)
            {
                subStreams[subID]?.yield(ev)
            }
        case .eose:
            break  // backlog boundary; the stream simply continues with live events
        case .aiResponse:
            if let aiID = frame.aiID, let cont = pendingAI.removeValue(forKey: aiID) {
                cont.resume(returning: frame.aiReply)
            }
        case .req, .close, .auth, .aiRequest:
            break  // client never receives these
        }
    }

    private func closeSub(_ subID: String) async {
        subStreams[subID] = nil
        subFilters[subID] = nil
        guard let host = hostPeer else { return }
        await send(.init(kind: .close, subID: subID), to: host)
    }

    // MARK: Awaiting (token-keyed continuations + a timeout fallback)

    private func awaitHost() async -> NearbyPeerID? {
        if let hostPeer { return hostPeer }
        let token = randomSource.bytes(8).hexString
        let timeout = hostTimeout
        return await withCheckedContinuation { (cont: CheckedContinuation<NearbyPeerID?, Never>) in
            hostWaiters[token] = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.resolveHostTimeout(token)
            }
        }
    }

    private func awaitChallenge() async -> String? {
        if let challenge { return challenge }
        let token = randomSource.bytes(8).hexString
        let timeout = hostTimeout
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            challengeWaiters[token] = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.resolveChallengeTimeout(token)
            }
        }
    }

    private func resolveHostTimeout(_ token: String) {
        hostWaiters.removeValue(forKey: token)?.resume(returning: nil)
    }
    private func resolveChallengeTimeout(_ token: String) {
        challengeWaiters.removeValue(forKey: token)?.resume(returning: nil)
    }
    private func resolvePublishTimeout(_ id: String) {
        pendingPublish.removeValue(forKey: id)?
            .resume(returning: PublishAck(eventID: id, accepted: false, message: "no relay ack"))
    }
    private func resolveAuthTimeout(_ token: String) {
        authWaiters.removeValue(forKey: token)?.resume(returning: false)
    }
    private func resolveAITimeout(_ aiID: String) {
        pendingAI.removeValue(forKey: aiID)?.resume(returning: nil)
    }

    /// Sign the host's challenge and send a kind-22242 AUTH. Used by both the
    /// first `authenticate()` and the automatic re-AUTH after a reconnect.
    @discardableResult
    private func sendAuth(
        _ keypair: NostrKeypair, challenge: String, randomSource: any RandomSource
    ) async -> Bool {
        guard let host = await awaitHost(),
            let authEvent = try? keypair.sign(
                NostrEvent(
                    pubkey: keypair.publicKeyHex, createdAt: 0, kind: 22242,
                    tags: [["relay", "nearby"], ["challenge", challenge]], content: ""),
                randomSource: randomSource),
            let d = RelayHubFrame.encodeEvent(authEvent)
        else { return false }
        await send(.init(kind: .auth, event: d), to: host)
        return true
    }

    /// Re-send REQ for every active subscription after a reconnect re-AUTH, so
    /// the host re-creates them and resumes delivery (including our gift-wraps).
    private func resubscribeAll() async {
        guard let host = hostPeer else { return }
        for (subID, filters) in subFilters {
            if let d = RelayHubFrame.encodeFilters(filters) {
                await send(.init(kind: .req, subID: subID, filters: d), to: host)
            }
        }
    }

    private func send(_ frame: RelayHubFrame, to peer: NearbyPeerID) async {
        guard let data = try? WireJSON.encoder().encode(frame) else { return }
        try? await link.send(data, to: peer)
    }
}
