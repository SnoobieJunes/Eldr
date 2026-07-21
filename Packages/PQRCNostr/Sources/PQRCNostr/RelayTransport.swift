// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// NIP-01 subscription filter (subset PQRC needs). Codable so it can ride a
/// `NearbyLink` REQ frame to a device-hosted relay (the Multipeer relay hub).
public struct NostrFilter: Sendable, Equatable, Codable {
    public var kinds: [Int]?
    public var authors: [String]?
    public var pTags: [String]?
    public var ids: [String]?
    public var since: Int64?

    enum CodingKeys: String, CodingKey {
        case kinds, authors
        case pTags = "p_tags"
        case ids, since
    }

    public init(
        kinds: [Int]? = nil, authors: [String]? = nil, pTags: [String]? = nil,
        ids: [String]? = nil, since: Int64? = nil
    ) {
        self.kinds = kinds
        self.authors = authors
        self.pTags = pTags
        self.ids = ids
        self.since = since
    }

    public func matches(_ event: NostrEvent) -> Bool {
        if let kinds, !kinds.contains(event.kind) { return false }
        if let authors, !authors.contains(event.pubkey) { return false }
        if let ids, !ids.contains(event.id) { return false }
        if let since, event.createdAt < since { return false }
        if let pTags {
            let eventPTags = event.tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1] }
            if !pTags.contains(where: eventPTags.contains) { return false }
        }
        return true
    }
}

/// Connection health for the Settings relay indicator. Reporting this never
/// changes delivery behavior (the messenger's outbox is the recovery path);
/// it only gives the user a green check / red x per configured server.
public enum RelayStatus: Sendable, Equatable {
    case connected
    case connecting
    case disconnected
    case failed(String)
}

/// Relay connection-lifecycle events, for diagnostics UIs (e.g. Huginn's Relay tab and
/// Inspector — B2). Purely observational, exactly like `RelayStatus`: nothing here ever
/// gates delivery, and nothing here ever carries event content or keys — only
/// protocol-level metadata (connect/disconnect/EOSE/AUTH), so a conformer can log/forward
/// it freely without touching the payload-privacy invariants (CLAUDE.md invariant 12).
public enum RelayTransportEvent: Sendable, Equatable {
    /// A dial attempt started.
    case connecting
    /// A frame arrived, proving the socket is live.
    case connected
    /// The socket went down. `reason` is nil for a caller-initiated `disconnect()`,
    /// non-nil (a short, user-facing description — never raw error internals) for a
    /// failure.
    case disconnected(reason: String?)
    /// The relay reported end-of-stored-events for one subscription.
    case eose(subscriptionID: String)
    /// The relay sent a NIP-42 AUTH challenge.
    case authChallenge
    /// A NIP-42 AUTH round-trip succeeded.
    case authenticated
    /// A NIP-42 AUTH round-trip was rejected or timed out.
    case authFailed(reason: String?)
    /// A transport-level error not already covered by `disconnected` (e.g. a send
    /// failure while otherwise connected).
    case error(String)
}

public struct PublishAck: Sendable, Equatable {
    public let eventID: String
    public let accepted: Bool
    public let message: String?

    public init(eventID: String, accepted: Bool, message: String? = nil) {
        self.eventID = eventID
        self.accepted = accepted
        self.message = message
    }
}

/// THE transport swap point (APP-SPEC §4): nothing above this protocol may
/// know whether the simulator or the real Nostr network is live. The
/// TEST-PLAN §7 conformance suite runs against any implementation; pointing it
/// at a real network client later is the acceptance gate.
public protocol RelayTransport: Sendable {
    /// Publish an event. Returns the relay's OK acknowledgement.
    func publish(_ event: NostrEvent) async throws -> PublishAck
    /// Subscribe: stored matching events first (EOSE semantics), then live ones.
    func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error>
    /// NIP-42 AUTH: sign the relay's challenge to unlock gated reads (kind 1059).
    func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws
    /// Last-known connection health, for the Settings indicator.
    func currentStatus() async -> RelayStatus
    /// Actively confirm reachability now (dials if needed), updating and
    /// returning the status. Used by the "Check now" control.
    func checkConnection() async -> RelayStatus
    /// The relay's NIP-11 `limitation.max_content_length` in bytes, if known.
    /// Drives adaptive chunk sizing: bigger chunks on relays that accept bigger
    /// events. nil means "unknown" → callers use the safe default.
    func maxContentLength() async -> Int?
    /// A live stream of connection-lifecycle events (B2 — diagnostics only, never a
    /// delivery gate). Default: an immediately-finished stream, so in-process/simulator
    /// transports (and every existing conformer) need no change; only
    /// `NostrWebSocketTransport` has anything real to report here. `async` (like
    /// `currentStatus()`/`checkConnection()`) so an actor conformer can implement it
    /// without crossing isolation.
    func transportEvents() async -> AsyncStream<RelayTransportEvent>
}

extension RelayTransport {
    /// In-process / simulator transports have no socket to drop — always healthy.
    public func currentStatus() async -> RelayStatus { .connected }
    public func checkConnection() async -> RelayStatus { await currentStatus() }
    /// In-process transports have no NIP-11 limit; nil → callers use the default.
    public func maxContentLength() async -> Int? { nil }
    /// In-process/simulator transports have no socket lifecycle to report.
    public func transportEvents() async -> AsyncStream<RelayTransportEvent> {
        AsyncStream { $0.finish() }
    }
}

/// Local-link transport seam (SPEC §10; stretch goal S1, implemented by
/// `MultipeerLinkTransport` over MultipeerConnectivity).
///
/// The unit shipped is the kind-13 SEAL event — the same rumor + seal layers
/// as the relay path, minus the outer kind-1059 gift wrap. SPEC §10: on a
/// point-to-point link there is no relay to hide the sender from, so the wrap
/// adds nothing; the seal stays because it carries sender authenticity and
/// keeps rumor metadata confidential even against a man-in-the-middle on the
/// radio link (MultipeerConnectivity's own encryption authenticates nobody).
/// See docs/DEVIATIONS.md S1 for why this seam ships seals, not bare rumors.
public protocol LocalLinkTransport: Sendable {
    /// Delivers one seal to the co-present peer that proved ownership of
    /// `peerIdentity` (the Ed25519 PQRC identity pubkey, raw 32 bytes).
    /// MUST throw `LocalLinkError.peerNotReachable` when that peer is not
    /// currently connected-and-verified — the messenger uses that signal to
    /// fall back to relay delivery automatically (SPEC §10).
    func send(_ seal: NostrEvent, to peerIdentity: Data) async throws
    /// Single-consumer stream of seals received from verified peers. The
    /// messenger unseals and feeds them through the same receive pipeline as
    /// relay-delivered envelopes.
    func incoming() async -> AsyncStream<NostrEvent>

    /// Advertise our own signed kind-10420 binding + prekey bundle to
    /// co-present peers, so they can verify and add us WITHOUT a relay
    /// (SPEC §10, gated by the app's Nearby setting). Both are
    /// signature-self-verifying, so the relay was never a trust anchor.
    func advertiseOwnBundle(bindingEvent: NostrEvent, prekeyBundle: PrekeyBundle) async

    /// Co-present peers whose binding verified in BOTH directions (invariant 7),
    /// paired with their prekey bundle — ready to establish a session with no
    /// relay. Identity-of-human is still confirmed out-of-band via the safety
    /// code, exactly as on the relay path.
    func discoveredContacts() async -> AsyncStream<DiscoveredContact>
}

/// A nearby peer discovered over the local link, already binding-verified.
public struct DiscoveredContact: Sendable {
    public let contact: VerifiedContact
    public let bundle: PrekeyBundle
    public init(contact: VerifiedContact, bundle: PrekeyBundle) {
        self.contact = contact
        self.bundle = bundle
    }
}

/// Default no-ops so a conformer that doesn't support nearby discovery (or a
/// test double) need not implement the bundle-exchange surface.
extension LocalLinkTransport {
    public func advertiseOwnBundle(bindingEvent: NostrEvent, prekeyBundle: PrekeyBundle) async {}
    public func discoveredContacts() async -> AsyncStream<DiscoveredContact> {
        AsyncStream { $0.finish() }
    }
}

/// Typed errors for the local-link path (CLAUDE.md conventions: typed errors,
/// no stringly failures).
public enum LocalLinkError: Error, Equatable, Sendable {
    /// No connected, identity-verified peer for the requested identity —
    /// the caller should fall back to relay delivery.
    case peerNotReachable
    /// The transport was asked to operate before `start()` / after `stop()`.
    case linkNotStarted
    /// A link payload could not be encoded/decoded.
    case malformedPayload
}

/// Content-addressed blob storage seam (SPEC §11): production Blossom later,
/// `LocalBlossomSimulator` now. Blobs are encrypted BEFORE upload.
public protocol BlobStore: Sendable {
    /// Stores a blob; returns its SHA-256 hex (the content address).
    func put(_ data: Data) async throws -> String
    func get(_ sha256Hex: String) async throws -> Data
}
