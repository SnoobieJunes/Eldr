#if canImport(MultipeerConnectivity)

import Foundation
import MultipeerConnectivity
import PQRCCore
import Synchronization

/// Production `NearbyLink` over MultipeerConnectivity (SPEC §10, stretch goal
/// S1). MC was chosen over raw CoreBluetooth because one Apple API covers
/// AWDL, Wi-Fi (peer-to-peer and infrastructure), and Bluetooth transparently.
///
/// Privacy posture (SPEC §0 — every tie resolves toward privacy):
/// - The advertised `MCPeerID` display name is RANDOM per process, carrying no
///   identity, username, or device name; `discoveryInfo` is nil. A passive
///   local observer learns only "some PQRC user is nearby", never who. The
///   residual co-presence leak is documented in docs/THREAT_MODEL.md.
/// - `encryptionPreference: .required` encrypts the link, but MC peers are
///   anonymous, so this resists only passive observers. All real guarantees
///   come from the seal + ratchet payloads carried on top (see
///   `MultipeerLinkTransport`'s trust model).
///
/// App-target integration requires two Info.plist entries (TESTFLIGHT-GUIDE
/// §A6 — Debug builds only, compiled out of Release):
/// - `NSLocalNetworkUsageDescription` — user-facing rationale string.
/// - `NSBonjourServices` — `["_pqrc-local._tcp", "_pqrc-local._udp"]`.
///
/// This adapter is the one deliberately untested-by-unit-tests shim in the
/// local-link stack (it needs real radios); everything above it runs against
/// `LocalLinkSimulator`. Verify on hardware per docs/SETUP-GUIDE.md.
public final class MultipeerNearbyLink: NSObject, NearbyLink, Sendable {
    /// Bonjour service type: 1–15 chars, lowercase/digits/hyphen per Apple's
    /// rules. Changing it is a wire-visible break for local discovery.
    public static let serviceType = "pqrc-local"

    /// MCSession is not marked Sendable, but Apple documents its methods as
    /// callable from any thread, and PQRC assigns its delegate exactly once at
    /// creation. Boxing it lets the send path and the invitation handler share
    /// the one session across concurrency regions without holding `state`
    /// locked around network calls.
    /// @unchecked Sendable justification: wraps a thread-safe-by-contract
    /// framework object behind an immutable reference; no mutable state here.
    private final class SessionBox: @unchecked Sendable {
        let session: MCSession
        init(_ session: MCSession) { self.session = session }
    }

    /// Mutable + non-Sendable framework objects, guarded by `state`. Peer
    /// bookkeeping stores only display-name strings: the `MCPeerID` objects
    /// handed to delegate callbacks stay in their caller's concurrency region
    /// and live peers are re-resolved from `session.connectedPeers` instead,
    /// which is what lets the compiler prove this class Sendable.
    private struct State {
        var sessionBox: SessionBox?
        var advertiser: MCNearbyServiceAdvertiser?
        var browser: MCNearbyServiceBrowser?
        /// Display names (`NearbyPeerID.raw`) of currently connected peers.
        var connectedNames: Set<String> = []
    }

    /// Our random ephemeral display name (see privacy posture above).
    private let displayName: String
    private let state: Mutex<State>
    private let stream: AsyncStream<NearbyLinkEvent>
    private let continuation: AsyncStream<NearbyLinkEvent>.Continuation

    /// `randomSource` feeds the ephemeral display name; production passes
    /// `SystemRandomSource()`. 16 hex chars keeps collisions negligible while
    /// staying within MCPeerID's 63-byte UTF-8 limit.
    public init(randomSource: any RandomSource = SystemRandomSource()) {
        self.displayName = randomSource.bytes(8).hexString
        self.state = Mutex(State())
        (self.stream, self.continuation) = AsyncStream.makeStream(of: NearbyLinkEvent.self)
        super.init()
    }

    // MARK: NearbyLink

    public func start() async throws {
        state.withLock { state in
            guard state.sessionBox == nil else { return }
            // One session hosts every nearby peer (MC supports 8); peers join
            // and leave it as they come into range.
            let peerID = MCPeerID(displayName: displayName)
            let session = MCSession(
                peer: peerID, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
            advertiser.delegate = self
            let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            browser.delegate = self
            state.sessionBox = SessionBox(session)
            state.advertiser = advertiser
            state.browser = browser
            advertiser.startAdvertisingPeer()
            browser.startBrowsingForPeers()
        }
    }

    public func stop() async {
        state.withLock { state in
            state.advertiser?.stopAdvertisingPeer()
            state.browser?.stopBrowsingForPeers()
            state.sessionBox?.session.disconnect()
            state.advertiser = nil
            state.browser = nil
            state.sessionBox = nil
            state.connectedNames.removeAll()
        }
        continuation.finish()
    }

    public func events() async -> AsyncStream<NearbyLinkEvent> {
        stream
    }

    public func send(_ data: Data, to peer: NearbyPeerID) async throws {
        // Resolve the live MCPeerID from the session itself (not a stored
        // copy — see the State doc comment), with no lock held during the
        // actual network call.
        guard let box = state.withLock({ $0.sessionBox }),
            let mcPeer = box.session.connectedPeers.first(where: { $0.displayName == peer.raw })
        else { throw LocalLinkError.peerNotReachable }
        do {
            // .reliable gives in-order, retransmitted delivery — matching the
            // seam's contract and the relay path's store-and-forward
            // semantics as closely as a radio can.
            try box.session.send(data, toPeers: [mcPeer], with: .reliable)
        } catch {
            throw LocalLinkError.peerNotReachable
        }
    }
}

// MARK: - MCSessionDelegate

extension MultipeerNearbyLink: MCSessionDelegate {
    public func session(
        _ session: MCSession, peer peerID: MCPeerID, didChange newState: MCSessionState
    ) {
        let event: NearbyLinkEvent? = state.withLock { state in
            switch newState {
            case .connected:
                state.connectedNames.insert(peerID.displayName)
                return .connected(NearbyPeerID(peerID.displayName))
            case .notConnected:
                guard state.connectedNames.remove(peerID.displayName) != nil else {
                    return nil  // a failed connection attempt, never connected
                }
                return .disconnected(NearbyPeerID(peerID.displayName))
            case .connecting:
                return nil
            @unknown default:
                return nil
            }
        }
        if let event { continuation.yield(event) }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        continuation.yield(.data(data, from: NearbyPeerID(peerID.displayName)))
    }

    // PQRC ships discrete payloads only; the stream/resource channels are
    // unused and ignored (a misbehaving peer cannot reach any code through them).
    public func session(
        _ session: MCSession, didReceive stream: InputStream, withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    public func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, with progress: Progress
    ) {}

    public func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
    ) {}
}

// MARK: - Discovery delegates

extension MultipeerNearbyLink: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    public func browser(
        _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        // Both sides advertise AND browse, so both discover each other.
        // Tie-break: only the lexicographically smaller display name invites;
        // the other side accepts. Exactly one session handshake per pair.
        guard displayName < peerID.displayName,
            let box = state.withLock({ $0.sessionBox })
        else { return }
        browser.invitePeer(peerID, to: box.session, withContext: nil, timeout: 30)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Session-level .notConnected handles the disconnect event.
    }

    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // Mirror of the invite tie-break above. Accepting is harmless even
        // from strangers: an unproven peer can never receive or inject message
        // traffic (see MultipeerLinkTransport), and auto-accept is what makes
        // co-present delivery zero-touch.
        guard peerID.displayName < displayName,
            let box = state.withLock({ $0.sessionBox })
        else {
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, box.session)
    }
}

#endif
