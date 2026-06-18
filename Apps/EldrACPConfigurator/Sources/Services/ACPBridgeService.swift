import Foundation
import PQRCACP
import PQRCAgent
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

/// Drives the local `eldr-acp` agent for one prompt and returns its COMPLETE final
/// answer. Deliberately NON-streaming: per-recipient redaction (§10) must scrub a whole
/// message — a secret split across two streamed deltas could evade a naive scrubber.
protocol BridgeAgentRunner: Sendable {
    func run(prompt: String, workdir: String?) async throws -> String
}

/// Default until the agent binary is located/configured — driving fails closed.
struct UnavailableAgentRunner: BridgeAgentRunner {
    struct NotConfigured: Error {}
    func run(prompt: String, workdir: String?) async throws -> String { throw NotConfigured() }
}

/// Production runner: spawns `eldr-acp` through `ACPClientDriver`, with streaming OFF
/// (`ELDR_ACP_STREAM=0`) so the agent emits the whole answer in one piece, and collects
/// it. The agent's own permission-gated fs tools do any local file reads on the Mac;
/// the owner window governs *sending*, not local access (§11).
struct ACPDriverAgentRunner: BridgeAgentRunner {
    let executableURL: URL
    var environmentOverrides: [String: String] = [:]

    func run(prompt: String, workdir: String?) async throws -> String {
        let collected = AgentAnswerCollector()
        let handler = ACPClientHandler(
            onAgentMessageChunk: { await collected.append($0) })
        var env = environmentOverrides
        env["ELDR_ACP_STREAM"] = "0"  // need the complete message to scrub it (§10)
        let driver = ACPClientDriver(
            executableURL: executableURL, environmentOverrides: env, handler: handler)
        _ = try await driver.start(cwd: workdir)
        _ = try await driver.prompt(prompt)
        await driver.shutdown()
        return await collected.value
    }
}

/// Accumulates the agent's answer chunks into one complete string.
actor AgentAnswerCollector {
    private(set) var value = ""
    func append(_ s: String) { value += s }
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
        /// Member identity hexes for per-recipient fan-out (§9). Empty ⇒ a 1:1 chat,
        /// so the single recipient is `id`.
        var members: [String] = []
        /// Thread id when this conversation routes a shared AI thread; nil ⇒
        /// conversation scope (the owner's ai_window governs), set ⇒ the owner's
        /// ai_invite for this thread governs.
        var threadID: String? = nil

        /// The recipients to fan a message out to (the roster, or just the peer for 1:1).
        var recipients: [String] { members.isEmpty ? [id] : members }
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

    /// The PINNED OWNER's identity hex (Path 2 §7). The Mac agent acts autonomously
    /// ONLY while THIS identity holds a live, signed ai_window/ai_invite. Persisted in
    /// the config dir (authorization-relevant, not secret). No owner ⇒ the bridge fails
    /// closed (never "first peer wins").
    @Published private(set) var ownerIdentityHex: String?

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
    /// The owner-authority oracle: verifies owner-signed windows/invites and answers
    /// "is the owner authorizing right now". A `PQRCAgent.AgentEngine` in production
    /// (standing up the Mac's PQRC node is the runtime boundary — see the type doc
    /// above); nil ⇒ the gate fails closed. Injected via `setOwnerAuthority`.
    private var ownerEngine: AgentEngine?
    /// Drives the local agent for the watch-along flow. Injected via `setAgentRunner`.
    private var agentRunner: BridgeAgentRunner = UnavailableAgentRunner()
    /// Where the agent runs (project dir). nil ⇒ the runner's default.
    private var agentWorkdir: String?
    /// File holding the pinned owner hex (`<configDir>/owner`).
    private let ownerFilePath: String?

    private var keypair: NostrKeypair?
    private var link: MultipeerNearbyLink?
    private var eventsTask: Task<Void, Never>?

    init(
        keychain: KeychainBox = KeychainBox(),
        serviceType: String = MultipeerNearbyLink.bridgeServiceType,
        preferredRelay: String? = nil,
        messaging: BridgeMessaging = UnpairedMessaging(),
        configDir: String? = AgentConfig.defaultConfigDir(ProcessInfo.processInfo.environment)
    ) {
        self.keychain = keychain
        self.serviceType = serviceType
        self.preferredRelay = preferredRelay
        self.messaging = messaging
        self.ownerFilePath = configDir.map { ($0 as NSString).appendingPathComponent("owner") }
        self.ownerIdentityHex = Self.loadOwner(from: ownerFilePath)
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
        setOwnerIdentity(nil)  // forget the pinned owner (fail closed until re-pinned)
        bridgeState = .unpaired
    }

    /// Inject the production messaging implementation once a session is established.
    func setMessaging(_ messaging: BridgeMessaging) { self.messaging = messaging }

    /// Inject the owner-authority oracle (the Mac's `AgentEngine`) once the PQRC node
    /// is stood up. Until then the owner gate fails closed.
    func setOwnerAuthority(_ engine: AgentEngine) { self.ownerEngine = engine }

    /// Inject the agent runner + its working directory (e.g. the project the agent
    /// operates on).
    func setAgentRunner(_ runner: BridgeAgentRunner, workdir: String? = nil) {
        self.agentRunner = runner
        self.agentWorkdir = workdir
    }

    // MARK: Owner identity (Path 2 §7)

    /// Designate (or clear) the pinned owner and persist it. Clearing fails the gate
    /// closed until a new owner is chosen.
    func setOwnerIdentity(_ hex: String?) {
        let trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines)
        ownerIdentityHex = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveOwner()
    }

    private func saveOwner() {
        guard let ownerFilePath else { return }
        if let ownerIdentityHex {
            let dir = (ownerFilePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try? ownerIdentityHex.write(toFile: ownerFilePath, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: ownerFilePath)
        }
    }

    private static func loadOwner(from path: String?) -> String? {
        guard let path, let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Owner authority routing + gate (Path 2 §8)

    /// Route an inbound ai_window: accept ONLY when it's from the pinned owner, then
    /// forward to the engine (which re-verifies the owner signature and bounded
    /// duration before storing it). Any other sender is rejected — never "first peer
    /// wins". No owner pinned / no engine ⇒ dropped (fail closed).
    func receiveOwnerWindow(
        _ announcement: AIWindowAnnouncement, fromSenderIdentityHex sender: String
    ) async {
        guard let ownerIdentityHex, sender == ownerIdentityHex, let ownerEngine else {
            return  // not from the owner (or no owner/engine): ignore
        }
        try? await ownerEngine.receiveWindow(announcement, fromSenderIdentityHex: sender)
    }

    /// Route an inbound ai_context_grant from the pinned owner into the engine.
    func receiveOwnerContextGrant(
        _ grant: AIContextGrant, fromSenderIdentityHex sender: String
    ) async {
        guard let ownerIdentityHex, sender == ownerIdentityHex, let ownerEngine else { return }
        try? await ownerEngine.receiveContextGrant(grant, fromSenderIdentityHex: sender)
    }

    /// Whether the pinned owner currently authorizes autonomous sends for this scope.
    /// Fail closed: no owner pinned, no engine, or no live owner window/invite ⇒ false.
    func ownerAuthorized(threadID: String? = nil) async -> Bool {
        guard let ownerIdentityHex, let ownerEngine else { return false }
        return await ownerEngine.isAuthorizedForOwner(ownerIdentityHex, threadID: threadID)
    }

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

    // MARK: - Watch-along: owner-gated per-recipient fan-out (Path 2 §9, §11)

    /// The distinguishing feature: while the owner gate is open, treat an inbound human
    /// message as a prompt, drive the local agent to a COMPLETE answer (never streamed —
    /// §10), and fan it out so the OWNER sees the raw answer while every other member
    /// sees the credential-scrubbed copy. Fails closed if the owner isn't authorizing.
    func handleInboundPrompt(_ text: String, conversation: BridgeConversation) async {
        guard await ownerAuthorized(threadID: conversation.threadID) else { return }
        do {
            let answer = try await agentRunner.run(prompt: text, workdir: agentWorkdir)
            await broadcastAgentMessage(answer, conversation: conversation)
        } catch {
            bridgeState = .error("Agent run failed: \(error)")
        }
    }

    /// Per-recipient agent send (§9): confirm the owner gate is open, scrub once, then
    /// loop the roster sending the RAW text to the owner's session and the
    /// `‹redacted:…›` copy to everyone else. Each pairwise link is separately encrypted
    /// (PQXDH + Double Ratchet), so divergent bodies are natural and only the owner's
    /// session ever carries the secret, E2E-encrypted to the owner.
    func broadcastAgentMessage(_ text: String, conversation: BridgeConversation) async {
        guard await ownerAuthorized(threadID: conversation.threadID), let ownerIdentityHex
        else { return }  // fail closed — no live owner window ⇒ no send
        let redacted = CredentialRedactor.scrub(text)
        for member in conversation.recipients {
            let visible = member == ownerIdentityHex ? text : redacted
            let body = MessageBody(text: visible, sentAt: clock.now())
            do {
                try await messaging.send(body, to: member, participantType: .agent)
            } catch {
                bridgeState = .error("Send failed: \(error)")
            }
        }
    }
}
