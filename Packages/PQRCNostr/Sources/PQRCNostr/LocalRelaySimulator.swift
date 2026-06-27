import Foundation
import PQRCCore

/// Chaos injection knobs for the TEST-PLAN §7 matrix. Deterministic via seed.
public struct ChaosOptions: Sendable {
    /// Max artificial delivery delay in milliseconds (0 = none).
    public var latencyJitterMillis: Int
    /// Probability [0,1] that a publish is dropped (no OK; outbox must retry).
    public var dropRate: Double
    /// Probability [0,1] that a delivered event is duplicated.
    public var duplicateRate: Double
    /// Deliveries are buffered and released in shuffled batches of this size.
    public var reorderWindow: Int
    public var seed: UInt64

    public init(
        latencyJitterMillis: Int = 0, dropRate: Double = 0, duplicateRate: Double = 0,
        reorderWindow: Int = 0, seed: UInt64 = 1
    ) {
        self.latencyJitterMillis = latencyJitterMillis
        self.dropRate = dropRate
        self.duplicateRate = duplicateRate
        self.reorderWindow = reorderWindow
        self.seed = seed
    }

    public static let none = ChaosOptions()
}

/// In-process Nostr relay (APP-SPEC §4): NIP-01 subset (EVENT/REQ/EOSE/OK),
/// NIP-42 AUTH, replaceable-event semantics, store-and-forward, anchor-relay
/// behavior (kind-1059 served ONLY to the AUTHed p-tagged recipient), and
/// configurable chaos.
///
/// One simulator instance = one relay. Each client obtains its own
/// `connect()`-ed `LocalRelayConnection` (the `RelayTransport`).
public actor LocalRelaySimulator {
    public let url: String
    private var chaos: ChaosOptions
    private let chaosRandom: SeededRandomSource
    /// Anchor-relay privacy gate (SPEC §9.1): when true (default), kind-1059
    /// envelopes are served ONLY to the AUTHed, p-tagged recipient. A PUBLIC
    /// relay sets this false and serves kind-1059 by filter match alone — the
    /// model ephemeral receiving keys (SPEC §9.3) rely on, since a recipient
    /// cannot AUTH as an X25519 routing sub-key (it is not a Nostr keypair).
    private let anchorGating: Bool

    private var events: [NostrEvent] = []
    private var knownEventIDs: Set<String> = []
    /// kind -> pubkey -> index into `events` for replaceable kinds.
    private var replaceableIndex: [Int: [String: Int]] = [:]

    struct Subscriber {
        let id: UUID
        let filters: [NostrFilter]
        let authedPubkey: String?
        let continuation: AsyncThrowingStream<NostrEvent, Error>.Continuation
    }
    private var subscribers: [Subscriber] = []
    private var reorderBuffer: [(subscriberID: UUID, event: NostrEvent)] = []
    private var challenges: [String: String] = [:]  // connectionID -> challenge

    public init(
        url: String = "local://relay", chaos: ChaosOptions = .none, anchorGating: Bool = true
    ) {
        self.url = url
        self.chaos = chaos
        self.chaosRandom = SeededRandomSource(seed: chaos.seed)
        self.anchorGating = anchorGating
    }

    public func setChaos(_ newChaos: ChaosOptions) {
        chaos = newChaos
    }

    public func connect() -> LocalRelayConnection {
        LocalRelayConnection(relay: self)
    }

    // MARK: - AUTH (NIP-42)

    func issueChallenge(connectionID: String) -> String {
        let challenge = chaosRandom.bytes(16).hexString
        challenges[connectionID] = challenge
        return challenge
    }

    /// Verifies a kind-22242 AUTH event signed by the client.
    func verifyAuth(connectionID: String, authEvent: NostrEvent) -> Bool {
        guard let challenge = challenges[connectionID],
            authEvent.kind == 22242,
            authEvent.firstTagValue("challenge") == challenge,
            NostrKeypair.verify(authEvent)
        else { return false }
        challenges[connectionID] = nil
        return true
    }

    // MARK: - Publish

    private func isReplaceable(_ kind: Int) -> Bool {
        kind == 0 || kind == 3 || (10000..<20000).contains(kind)
    }

    func handlePublish(_ event: NostrEvent) throws -> PublishAck {
        // Chaos: simulated network drop — the relay never saw it, no OK.
        if chaos.dropRate > 0, chance(chaos.dropRate) {
            throw NostrError.publishDropped
        }
        guard event.hasValidID(), NostrKeypair.verify(event) else {
            return PublishAck(eventID: event.id, accepted: false, message: "invalid: bad sig")
        }
        // Dedupe: duplicate envelope stored once.
        if knownEventIDs.contains(event.id) {
            return PublishAck(eventID: event.id, accepted: true, message: "duplicate: already have it")
        }
        knownEventIDs.insert(event.id)

        if isReplaceable(event.kind) {
            if let existing = replaceableIndex[event.kind]?[event.pubkey] {
                // Latest wins; older replaceable events vanish.
                if events[existing].createdAt <= event.createdAt {
                    events[existing] = event
                } else {
                    return PublishAck(eventID: event.id, accepted: true, message: "replaced by newer")
                }
            } else {
                events.append(event)
                replaceableIndex[event.kind, default: [:]][event.pubkey] = events.count - 1
            }
        } else {
            events.append(event)
        }
        fanOut(event)
        return PublishAck(eventID: event.id, accepted: true)
    }

    // MARK: - Subscribe

    func handleSubscribe(
        filters: [NostrFilter], authedPubkey: String?
    ) -> AsyncThrowingStream<NostrEvent, Error> {
        AsyncThrowingStream { continuation in
            let subscriber = Subscriber(
                id: UUID(), filters: filters, authedPubkey: authedPubkey,
                continuation: continuation)
            // Store-and-forward backlog first (EOSE semantics), then live.
            for event in self.events where self.visible(event, to: subscriber) {
                continuation.yield(event)
            }
            self.subscribers.append(subscriber)
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(subscriber.id) }
            }
        }
    }

    /// Subscribe with the backlog/live boundary made explicit, for frontends
    /// that must emit a NIP-01 EOSE marker between the two (`NostrRelayServer`).
    /// Atomic inside the actor: events published after this call land in
    /// `live`, never duplicated into nor missing from `backlog`.
    func handleSubscribeSplit(
        filters: [NostrFilter], authedPubkey: String?
    ) -> (backlog: [NostrEvent], live: AsyncThrowingStream<NostrEvent, Error>) {
        let (stream, continuation) = AsyncThrowingStream<NostrEvent, Error>.makeStream()
        let subscriber = Subscriber(
            id: UUID(), filters: filters, authedPubkey: authedPubkey,
            continuation: continuation)
        let backlog = events.filter { visible($0, to: subscriber) }
        subscribers.append(subscriber)
        continuation.onTermination = { _ in
            Task { await self.removeSubscriber(subscriber.id) }
        }
        return (backlog, stream)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeAll { $0.id == id }
    }

    /// Anchor-relay privacy rule (SPEC §9.1): kind-1059 envelopes are served
    /// ONLY to the authenticated, p-tagged recipient. Unauthenticated or
    /// wrong-key clients get nothing — not even existence.
    private func visible(_ event: NostrEvent, to subscriber: Subscriber) -> Bool {
        guard subscriber.filters.contains(where: { $0.matches(event) }) else { return false }
        if anchorGating, event.kind == PQRCConstants.giftWrapEventKind {
            guard let authed = subscriber.authedPubkey,
                event.firstTagValue("p") == authed
            else { return false }
        }
        return true
    }

    private func fanOut(_ event: NostrEvent) {
        for subscriber in subscribers where visible(event, to: subscriber) {
            scheduleDelivery(event, to: subscriber)
            if chaos.duplicateRate > 0, chance(chaos.duplicateRate) {
                scheduleDelivery(event, to: subscriber)
            }
        }
    }

    private func scheduleDelivery(_ event: NostrEvent, to subscriber: Subscriber) {
        if chaos.reorderWindow > 1 {
            reorderBuffer.append((subscriber.id, event))
            if reorderBuffer.count >= chaos.reorderWindow {
                flushReorderBuffer()
            }
            return
        }
        deliver(event, to: subscriber)
    }

    /// Releases the reorder buffer in a seeded shuffle.
    public func flushReorderBuffer() {
        var pending = reorderBuffer
        reorderBuffer.removeAll()
        // Fisher-Yates with the seeded stream.
        for i in stride(from: pending.count - 1, to: 0, by: -1) {
            let roll = chaosRandom.bytes(4).uint32BE(at: 0) ?? 0
            pending.swapAt(i, Int(roll % UInt32(i + 1)))
        }
        for (subscriberID, event) in pending {
            if let subscriber = subscribers.first(where: { $0.id == subscriberID }) {
                deliver(event, to: subscriber)
            }
        }
    }

    private func deliver(_ event: NostrEvent, to subscriber: Subscriber) {
        if chaos.latencyJitterMillis > 0 {
            let delay = Int((chaosRandom.bytes(4).uint32BE(at: 0) ?? 0)
                % UInt32(chaos.latencyJitterMillis + 1))
            let continuation = subscriber.continuation
            Task {
                try? await Task.sleep(for: .milliseconds(delay))
                continuation.yield(event)
            }
        } else {
            subscriber.continuation.yield(event)
        }
    }

    private func chance(_ probability: Double) -> Bool {
        let roll = Double(chaosRandom.bytes(4).uint32BE(at: 0) ?? 0) / Double(UInt32.max)
        return roll < probability
    }

    // MARK: - Test introspection

    public var storedEventCount: Int { events.count }

    public func storedEvents(kind: Int? = nil) -> [NostrEvent] {
        guard let kind else { return events }
        return events.filter { $0.kind == kind }
    }
}

/// One client's connection to a `LocalRelaySimulator`. Holds per-connection
/// NIP-42 auth state. This is the object the app injects as `RelayTransport`.
public actor LocalRelayConnection: RelayTransport {
    private let relay: LocalRelaySimulator
    private let connectionID = UUID().uuidString
    private var authedPubkey: String?

    init(relay: LocalRelaySimulator) {
        self.relay = relay
    }

    public func publish(_ event: NostrEvent) async throws -> PublishAck {
        try await relay.handlePublish(event)
    }

    public func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        await relay.handleSubscribe(filters: filters, authedPubkey: authedPubkey)
    }

    public func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {
        let challenge = await relay.issueChallenge(connectionID: connectionID)
        let authEvent = try keypair.sign(
            NostrEvent(
                pubkey: keypair.publicKeyHex,
                createdAt: 0,
                kind: 22242,
                tags: [["relay", relay.url], ["challenge", challenge]],
                content: ""
            ), randomSource: randomSource)
        guard await relay.verifyAuth(connectionID: connectionID, authEvent: authEvent) else {
            throw NostrError.notAuthenticated
        }
        authedPubkey = keypair.publicKeyHex
    }

    /// The in-process / offline relay (`local` in Settings) has no wire content
    /// limit, so it reports a generous one — adaptive chunking then uses the
    /// largest padding bucket (64 KB, the §11 inline ceiling). When `local` is
    /// the ONLY server, delivery is Nearby (Bluetooth/Wi-Fi Direct), which has
    /// no size limit either; if it's mixed with a real relay, that relay's
    /// smaller limit still wins (`chunkTextBudget` takes the minimum).
    public func maxContentLength() async -> Int? { 64 * 1024 * 1024 }
}
