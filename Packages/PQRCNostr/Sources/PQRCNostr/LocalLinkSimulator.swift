import Foundation
import PQRCCore

/// In-process stand-in for the MultipeerConnectivity radio layer (the
/// `NearbyLink` counterpart of `LocalRelaySimulator`): a hub that connects
/// simulated peers, models co-presence, and offers the test hooks the
/// TEST-PLAN determinism rules require — no unit test touches real radios.
///
/// Co-presence model: every STARTED link sees every other started link,
/// unless the pair has been explicitly partitioned with `setCoPresent`.
/// Partitioning emits `.disconnected` (peers walked out of range); rejoining
/// emits `.connected` — exactly the signals MultipeerConnectivity produces.
public actor LocalLinkSimulator {
    private var continuations: [NearbyPeerID: AsyncStream<NearbyLinkEvent>.Continuation] = [:]
    /// Canonically keyed pairs that are NOT co-present.
    private var partitions: Set<String> = []
    /// Every routed payload, for frame-level assertions and replay tests.
    private var payloadLog: [(from: NearbyPeerID, to: NearbyPeerID, data: Data)] = []

    public init() {}

    /// Vends a link endpoint for one simulated device. Inactive until `start()`.
    public func makeLink(name: String) -> SimulatedNearbyLink {
        SimulatedNearbyLink(peerID: NearbyPeerID(name), hub: self)
    }

    // MARK: Co-presence control (tests)

    /// Moves a pair into/out of radio range, emitting the same connect or
    /// disconnect events the real link would.
    public func setCoPresent(_ a: NearbyPeerID, _ b: NearbyPeerID, _ coPresent: Bool) {
        let key = pairKey(a, b)
        let wasCoPresent = !partitions.contains(key)
        guard wasCoPresent != coPresent else { return }
        if coPresent {
            partitions.remove(key)
            if let ca = continuations[a], let cb = continuations[b] {
                ca.yield(.connected(b))
                cb.yield(.connected(a))
            }
        } else {
            partitions.insert(key)
            if let ca = continuations[a], let cb = continuations[b] {
                ca.yield(.disconnected(b))
                cb.yield(.disconnected(a))
            }
        }
    }

    // MARK: Test introspection / fault injection

    /// All payloads routed so far, optionally filtered by direction.
    public func payloads(
        from: NearbyPeerID? = nil, to: NearbyPeerID? = nil
    ) -> [Data] {
        payloadLog
            .filter { (from == nil || $0.from == from) && (to == nil || $0.to == to) }
            .map(\.data)
    }

    /// Delivers raw bytes as if `from` had sent them — the hook for replay,
    /// tampering, and forged-sender tests. Bypasses the co-presence check on
    /// purpose: an attacker's radio does not honor our topology.
    public func inject(_ data: Data, from: NearbyPeerID, to: NearbyPeerID) {
        continuations[to]?.yield(.data(data, from: from))
    }

    // MARK: Hub internals (called by SimulatedNearbyLink)

    func join(_ peer: NearbyPeerID, continuation: AsyncStream<NearbyLinkEvent>.Continuation) {
        continuations[peer] = continuation
        for (other, otherContinuation) in continuations where other != peer {
            guard !partitions.contains(pairKey(peer, other)) else { continue }
            continuation.yield(.connected(other))
            otherContinuation.yield(.connected(peer))
        }
    }

    func leave(_ peer: NearbyPeerID) {
        guard continuations.removeValue(forKey: peer) != nil else { return }
        for (other, otherContinuation) in continuations {
            guard !partitions.contains(pairKey(peer, other)) else { continue }
            otherContinuation.yield(.disconnected(peer))
        }
    }

    func route(_ data: Data, from: NearbyPeerID, to: NearbyPeerID) throws {
        guard continuations[from] != nil, let target = continuations[to],
            !partitions.contains(pairKey(from, to))
        else { throw LocalLinkError.peerNotReachable }
        payloadLog.append((from: from, to: to, data: data))
        target.yield(.data(data, from: from))
    }

    private func pairKey(_ a: NearbyPeerID, _ b: NearbyPeerID) -> String {
        a.raw < b.raw ? "\(a.raw)|\(b.raw)" : "\(b.raw)|\(a.raw)"
    }
}

/// One simulated device's endpoint. All state lives in the hub actor; this
/// type only carries the (Sendable) stream pair, so plain `Sendable` holds.
public final class SimulatedNearbyLink: NearbyLink, Sendable {
    public let peerID: NearbyPeerID
    private let hub: LocalLinkSimulator
    private let stream: AsyncStream<NearbyLinkEvent>
    private let continuation: AsyncStream<NearbyLinkEvent>.Continuation

    init(peerID: NearbyPeerID, hub: LocalLinkSimulator) {
        self.peerID = peerID
        self.hub = hub
        (self.stream, self.continuation) = AsyncStream.makeStream(of: NearbyLinkEvent.self)
    }

    public func start() async throws {
        await hub.join(peerID, continuation: continuation)
    }

    public func stop() async {
        await hub.leave(peerID)
    }

    public func events() async -> AsyncStream<NearbyLinkEvent> {
        stream
    }

    public func send(_ data: Data, to peer: NearbyPeerID) async throws {
        try await hub.route(data, from: peerID, to: peer)
    }
}
