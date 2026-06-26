import Crypto
import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr
import Testing

@testable import EldrNodeCore

// Headless test scaffolding for `EldrNodeCore.serve`, mirroring PQRCNostr's
// `RelayCarriedACPE2ETests` (the proven full relay path) but for THIS package: two real
// `PQRCMessenger`s over one `LocalRelaySimulator`, a verified session, and a scripted
// `LLMClient`. No real network, no real clock, no real Keychain.

// MARK: - Tags

extension Tag {
    @Tag static var transport: Tag
    @Tag static var security: Tag
}

// MARK: - Persona (local copy — TestSupport.Persona lives in PQRCNostr's own test target)

func nodeHex(_ hex: String) -> Data { Data(hexString: hex) ?? Data() }

/// A complete local persona: identity, nostr key, prekeys, messenger — built off a seed
/// so the whole run is deterministic and offline.
struct NodePersona {
    let name: String
    let identity: PQRCIdentity
    let nostrKeypair: NostrKeypair
    let prekeyManager: PrekeyManager
    let identityDH: Curve25519.KeyAgreement.PrivateKey
    let messenger: PQRCMessenger

    var identityHex: String { identity.publicKeyData.hexString }

    static func make(
        name: String, seedByte: String, seed: UInt64, transports: [any RelayTransport]
    ) async throws -> NodePersona {
        let identity = try PQRCIdentity(seed: nodeHex(String(repeating: seedByte, count: 32)))
        let random = SeededRandomSource(seed: seed)
        let nostrKeypair = try NostrKeypair(randomSource: random)
        let identityDH = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: random.bytes(32))
        let prekeyManager = try PrekeyManager(identity: identity, randomSource: random, oneTimeCount: 8)
        let messenger = try PQRCMessenger(
            identity: identity, nostrKeypair: nostrKeypair, prekeyManager: prekeyManager,
            identityDH: identityDH, transports: transports, clock: FixedClock(),
            randomSource: random, nonceSource: SeededRandomSource(seed: seed &+ 77),
            outboundRetryBaseMillis: 2)
        return NodePersona(
            name: name, identity: identity, nostrKeypair: nostrKeypair,
            prekeyManager: prekeyManager, identityDH: identityDH, messenger: messenger)
    }

    /// Verified-contact view of another persona (as if fetched + verified both ways).
    func asContact() throws -> VerifiedContact {
        let binding = try IdentityBinding.make(
            identity: identity, nostrPubkey: nodeHex(nostrKeypair.publicKeyHex))
        return VerifiedContact(binding: try BindingVerifier.verify(binding, outerSignatureValid: true))
    }
}

// MARK: - Scripted LLM (in-package mock; no network)

/// A scripted LLM: returns queued responses in order, then a terminal "done". `stream`
/// uses the protocol default (one-shot `complete`), matching the node's
/// `streamingEnabled: false` path. Mirrors the PQRCACP harness's ScriptedLLM.
actor ScriptedLLM: LLMClient {
    private var queue: [LLMResponse]
    init(_ responses: [LLMResponse]) { self.queue = responses }
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
    }
}

/// Counts agent-side completions so the C-3 control can assert "a dropped frame produces
/// NO turn" vs "an owner frame DOES".
actor TurnCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// A scripted LLM that records every completion on a `TurnCounter` — used by the C-3 test
/// to prove a non-owner frame never reaches the agent's turn loop.
actor CountingLLM: LLMClient {
    private var queue: [LLMResponse]
    private let counter: TurnCounter
    init(_ responses: [LLMResponse], counter: TurnCounter) {
        self.queue = responses
        self.counter = counter
    }
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        await counter.bump()
        return queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
    }
}

// MARK: - Owner-side stream consumer (tap that routes the node's reply frames)

/// Drains the OWNER messenger's single `start()` stream. Records messages (for handshake
/// waits) and forwards the NODE's ACP reply frames into the phone's `RelayACPTransport`.
/// The node side needs no tap here: `EldrNodeCore.serve` is the node's SOLE consumer (and
/// the place the C-3 gate runs).
actor OwnerTap {
    private var messages: [ReceivedMessage] = []
    private var task: Task<Void, Never>?
    private var route: (@Sendable (String) async -> Void)?
    private var acceptFrom: @Sendable (String) -> Bool = { _ in false }

    func attach(_ stream: AsyncStream<MessengerEvent>) {
        task = Task {
            for await event in stream {
                guard case .message(let m) = event else { continue }
                await self.handle(m)
            }
        }
    }

    /// Wire the ACP route + the sender gate (the owner accepts ACP frames FROM the node).
    func wireACPRoute(
        acceptFrom: @escaping @Sendable (String) -> Bool,
        route: @escaping @Sendable (String) async -> Void
    ) {
        self.acceptFrom = acceptFrom
        self.route = route
    }

    private func handle(_ m: ReceivedMessage) async {
        messages.append(m)
        guard RelayACPTransport.isACPFrame(m.body.text) else { return }
        guard acceptFrom(m.senderIdentityHex), let route else { return }
        await route(m.body.text)
    }

    /// Poll until ≥ the given plain texts arrived.
    func waitForTexts(_ texts: Set<String>, timeoutMillis: Int = 10_000) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if texts.isSubset(of: Set(messages.map(\.body.text))) { return true }
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return texts.isSubset(of: Set(messages.map(\.body.text)))
    }

    /// Give the relay a beat to deliver the owner→node handshake so the node's serve loop
    /// builds its responder session before the ACP client drives a turn through it. The
    /// node has no tap here (serve owns its stream), so this is a deterministic settle
    /// rather than an observed event. Always returns true.
    func waitForHandshakeSettled(millis: Int = 400) async -> Bool {
        try? await Task.sleep(for: .milliseconds(millis))
        return true
    }

    func stop() { task?.cancel() }
}

// MARK: - UI-event collector (the owner ACPClient's typed events)

/// Drains an `ACPClient.events` stream into an inspectable buffer, with the helpers the
/// e2e asserts use. Mirrors `RelayCarriedACPE2ETests.ACPUIEventCollector`.
actor NodeUIEventCollector {
    private var events: [ACPUIEvent] = []
    private var task: Task<Void, Never>?

    func attach(_ stream: AsyncStream<ACPUIEvent>) {
        task = Task { for await event in stream { self.append(event) } }
    }
    private func append(_ event: ACPUIEvent) { events.append(event) }

    private func assistantText() -> String {
        events.compactMap { if case .assistantText(let t) = $0 { return t } else { return nil } }
            .joined()
    }

    func assistantTextJoined(containing marker: String, timeoutMillis: Int = 5_000) async -> String {
        var waited = 0
        while !assistantText().contains(marker) && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return assistantText()
    }

    func sawToolCall(timeoutMillis: Int = 5_000) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if events.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return false
    }

    func stop() { task?.cancel() }
}

// MARK: - Timeout helper

struct NodeTimedOut: Error { let what: String }

@discardableResult
func withNodeTimeout<T: Sendable>(
    _ seconds: Double, _ what: String, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NodeTimedOut(what: what)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Bumps `sentAt` so each carried frame is a distinct ratchet message.
actor NodeSeq {
    private var n: Int64 = 100
    func next() -> Int64 { n += 1; return n }
}

// MARK: - Scriptable NodeMessenger double (for the bootstrap policy unit test)

/// A minimal `NodeMessenger` that scripts `acceptRequest` so the owner-bootstrap policy
/// (`EldrNodeCore.bootstrapOwnerFromRequest`) can be tested in isolation — no relay, no
/// crypto. `start`/`sendFramed` are unused by the policy helper (it never streams or
/// sends), so they return an empty stream / no-op. Records the calls the policy makes.
actor ScriptedNodeMessenger: NodeMessenger {
    /// Maps a request's Nostr pubkey → the identity hex `acceptRequest` resolves to.
    /// A missing key ⇒ `acceptRequest` throws (an unverifiable / unreachable sender).
    private let acceptIdentityByPubkey: [String: String]
    private(set) var accepted: [String] = []
    private(set) var declined: [String] = []

    init(acceptIdentityByPubkey: [String: String]) {
        self.acceptIdentityByPubkey = acceptIdentityByPubkey
    }

    nonisolated func start() async throws -> AsyncStream<MessengerEvent> {
        AsyncStream { $0.finish() }
    }
    nonisolated func sendFramed(_ framed: String, to peerIdentityHex: String) async throws {}

    func acceptRequest(senderNostrPubkeyHex: String) async throws -> String {
        accepted.append(senderNostrPubkeyHex)
        guard let identity = acceptIdentityByPubkey[senderNostrPubkeyHex] else {
            throw NodeMessengerError.requestsUnsupported  // stands in for "could not verify"
        }
        return identity
    }

    func declineRequest(senderNostrPubkeyHex: String) async {
        declined.append(senderNostrPubkeyHex)
    }
}

/// A node working directory (the C-2 jail root), canonicalized so the jail's
/// `resolvingSymlinksInPath` root matches what the tools resolve (macOS /var path).
func makeNodeWorkdir(_ tag: String) throws -> String {
    let dir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("eldr-node-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return (dir as NSString).resolvingSymlinksInPath
}
