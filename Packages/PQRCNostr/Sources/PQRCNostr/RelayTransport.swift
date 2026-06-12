import Foundation
import PQRCCore

/// NIP-01 subscription filter (subset PQRC needs).
public struct NostrFilter: Sendable, Equatable {
    public var kinds: [Int]?
    public var authors: [String]?
    public var pTags: [String]?
    public var ids: [String]?
    public var since: Int64?

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
