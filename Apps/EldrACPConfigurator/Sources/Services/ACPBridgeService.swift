import Foundation
import PQRCCore
import PQRCNostr

// MARK: - Pure, testable bridge pieces

/// The QR pairing payload EldrChat scans to add the coding agent as a contact:
/// the agent's Nostr pubkey (hex) and an optional preferred relay. JSON so it's
/// trivially scannable and forward-compatible.
struct PairingPayload: Codable, Equatable, Sendable {
    let pubkey: String
    let relay: String?

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func decode(_ string: String) -> PairingPayload? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PairingPayload.self, from: data)
    }
}

/// Formats an ACP activity into the human-readable text the agent sends as an
/// EldrChat message. Pure (no truncation — SPEC §7 chunking handles large payloads
/// inside the messenger), so it's unit-testable.
enum AgentActivity {
    static func toolCall(name: String, argsJSON: String, result: String, isError: Bool) -> String {
        let status = isError ? "⚠️ failed" : "ran"
        return "🔧 \(status): \(name)\n\(argsJSON)\n→ \(result)"
    }

    static func buildResult(command: String, exitCode: Int, output: String) -> String {
        let verdict = exitCode == 0 ? "✅ build succeeded" : "❌ build failed (exit \(exitCode))"
        return "\(verdict)\n$ \(command)\n\(output)"
    }

    static func sessionSummary(summary: String, filesChanged: Int) -> String {
        "📝 Session summary (\(filesChanged) file(s) changed):\n\(summary)"
    }
}

/// The seam to the PQRC ratchet session. The agent's reports are sent as ordinary
/// PQRC messages with `participant_type: .agent` (invariant 8) over the existing
/// PQXDH + Double Ratchet + gift-wrap stack.
///
/// Standing up a full PQRC node in the Configurator (identity + prekeys published to
/// a relay, then a live PQXDH pairing handshake with EldrChat over Multipeer) is the
/// runtime integration boundary — it needs a second peer and the app's identity
/// stack, so it can't be exercised headlessly (see docs/DEVIATIONS.md). Production
/// wires a `PQRCMessenger`-backed implementation here; until paired, sends throw.
protocol BridgeMessaging: Sendable {
    func send(_ body: MessageBody, to peerIdentityHex: String, participantType: ParticipantType)
        async throws
}

struct UnpairedMessaging: BridgeMessaging {
    struct NotPaired: Error {}
    func send(_ body: MessageBody, to peerIdentityHex: String, participantType: ParticipantType)
        async throws
    { throw NotPaired() }
}

// MARK: - Service

@MainActor
final class ACPBridgeService: ObservableObject {

    enum BridgeState: Equatable {
        case unpaired
        case advertising
        case paired(contactName: String)
        case error(String)
    }

    /// One EldrChat conversation the agent can report into, with the user's opt-in.
    struct BridgeConversation: Identifiable, Equatable {
        let id: String  // peer identity hex / group id
        var name: String
        var enabled: Bool
    }

    @Published private(set) var bridgeState: BridgeState = .unpaired
    /// JSON for the QR code shown while advertising; nil when the bridge is off.
    @Published private(set) var pairingPayloadJSON: String?
    /// The `pqrc:add?npub=…` deep link EldrChat understands — what the QR encodes
    /// and what "Copy pairing link" / "Open in EldrChat" use. A bare JSON blob (the
    /// old QR payload) is read as plain text by the Camera, which "helpfully" web-
    /// searches it; a registered URL scheme deep-links straight into the app, and
    /// also lets you pair on the SAME Mac (no second device to scan with). nil off.
    @Published private(set) var pairingLink: String?
    @Published var activeConversations: [BridgeConversation] = []
    /// Inbound messages the group sent back (instructions/context), newest last.
    @Published private(set) var inbound: [String] = []

    // Per-message-type opt-in — OFF by default (the user chooses to share).
    @Published var shareToolCalls = false
    @Published var shareBuildResults = false
    @Published var shareFileDiffs = false
    @Published var shareSessionSummary = false

    private let keychain: KeychainBox
    private let keyAccount = "bridge-nostr-identity"
    private let serviceType: String
    private let preferredRelay: String?
    private let clock: any Clock = SystemClock()
    private var messaging: BridgeMessaging

    private var keypair: NostrKeypair?
    private var link: MultipeerNearbyLink?
    private var eventsTask: Task<Void, Never>?

    init(
        keychain: KeychainBox = KeychainBox(),
        serviceType: String = MultipeerNearbyLink.bridgeServiceType,
        preferredRelay: String? = nil,
        messaging: BridgeMessaging = UnpairedMessaging()
    ) {
        self.keychain = keychain
        self.serviceType = serviceType
        self.preferredRelay = preferredRelay
        self.messaging = messaging
    }

    /// True once the agent has a stored Nostr identity (whether or not advertising).
    var hasIdentity: Bool { keypair != nil || keychain.load(account: keyAccount) != nil }

    // MARK: Identity

    /// Load the stored Nostr identity, generating + persisting one on first use.
    /// SPEC §3.1 access rules are enforced by KeychainBox.
    @discardableResult
    func loadOrCreateKeypair() throws -> NostrKeypair {
        if let keypair { return keypair }
        if let data = keychain.load(account: keyAccount) {
            let kp = try NostrKeypair(privateKey: data)
            keypair = kp
            return kp
        }
        let kp = try NostrKeypair(randomSource: SystemRandomSource())
        try keychain.save(kp.privateKeyData, account: keyAccount)
        keypair = kp
        return kp
    }

    // MARK: Lifecycle

    /// Generate/load the identity, publish the QR payload, and start advertising over
    /// Multipeer so a nearby EldrChat can discover the agent.
    func enable() {
        // Tear down any prior advertiser first so re-enabling (e.g. retrying from the
        // `.error` state, where the Enable button is still shown) can't orphan a live
        // MultipeerNearbyLink + its events Task. Idempotent.
        if link != nil || eventsTask != nil { disable() }
        do {
            let kp = try loadOrCreateKeypair()
            pairingPayloadJSON = PairingPayload(pubkey: kp.publicKeyHex, relay: preferredRelay)
                .jsonString()
            pairingLink = Self.deepLink(pubkeyHex: kp.publicKeyHex, relay: preferredRelay)
            let link = MultipeerNearbyLink(serviceType: serviceType)
            self.link = link
            bridgeState = .advertising
            eventsTask = Task { [weak self] in
                do {
                    try await link.start()
                    for await event in await link.events() {
                        await self?.handle(linkEvent: event)
                    }
                } catch {
                    await MainActor.run { self?.bridgeState = .error("\(error)") }
                }
            }
        } catch {
            bridgeState = .error("Could not create the agent identity: \(error)")
        }
    }

    /// Stop advertising (keeps the identity).
    func disable() {
        eventsTask?.cancel()
        eventsTask = nil
        let link = self.link
        self.link = nil
        Task { await link?.stop() }
        pairingPayloadJSON = nil
        pairingLink = nil
        if case .error = bridgeState {} else { bridgeState = .unpaired }
    }

    /// Build the `pqrc:add?npub=…` deep link EldrChat's `handleDeepLink` parses.
    /// The pubkey is bech32-encoded to `npub1…` (what the app's New-conversation
    /// scan expects); a preferred relay rides along as a forward-compatible query
    /// item the app ignores until it wires relay hints in.
    nonisolated static func deepLink(pubkeyHex: String, relay: String?) -> String {
        var link = "pqrc:add?npub=\(Bech32.npub(pubkeyHex))"
        if let relay, !relay.isEmpty,
            let encoded = relay.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        {
            link += "&relay=\(encoded)"
        }
        return link
    }

    /// Revoke pairing: stop, delete the identity key, and forget conversations.
    func unpair() {
        disable()
        keychain.delete(account: keyAccount)
        keypair = nil
        activeConversations.removeAll()
        inbound.removeAll()
        bridgeState = .unpaired
    }

    /// Inject the production messaging implementation once a session is established.
    func setMessaging(_ messaging: BridgeMessaging) { self.messaging = messaging }

    private func handle(linkEvent: NearbyLinkEvent) {
        // The full PQXDH pairing handshake is the runtime boundary; here we only
        // reflect link-level connectivity so the UI isn't silent.
        switch linkEvent {
        case .connected:
            if case .advertising = bridgeState {
                bridgeState = .paired(contactName: "EldrChat")
            }
        case .disconnected:
            if case .paired = bridgeState { bridgeState = .advertising }
        case .data:
            break  // inbound PQRC payloads are decoded by the messenger seam
        }
    }

    // MARK: Reporting ACP activity (gated by the per-type toggles)

    func reportToolCall(name: String, argsJSON: String, result: String, isError: Bool) async {
        guard shareToolCalls else { return }
        await broadcast(AgentActivity.toolCall(
            name: name, argsJSON: argsJSON, result: result, isError: isError))
    }

    func reportBuildResult(command: String, exitCode: Int, output: String) async {
        guard shareBuildResults else { return }
        await broadcast(AgentActivity.buildResult(
            command: command, exitCode: exitCode, output: output))
    }

    func reportSessionSummary(summary: String, filesChanged: Int) async {
        guard shareSessionSummary else { return }
        await broadcast(AgentActivity.sessionSummary(
            summary: summary, filesChanged: filesChanged))
    }

    /// Send a formatted report to every enabled conversation as an agent message.
    private func broadcast(_ text: String) async {
        let body = MessageBody(text: text, sentAt: clock.now())
        for conversation in activeConversations where conversation.enabled {
            do {
                try await messaging.send(body, to: conversation.id, participantType: .agent)
            } catch {
                // Surface but don't crash the coding session over a delivery hiccup.
                bridgeState = .error("Send failed: \(error)")
            }
        }
    }
}
