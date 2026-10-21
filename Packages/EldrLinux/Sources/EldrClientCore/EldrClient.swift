// SPDX-License-Identifier: Apache-2.0
import Crypto
import EldrKeystore
import Foundation
import PQRCCore
import PQRCNostr
import PQRCAgent

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum EldrClientError: Error, CustomStringConvertible {
    case notInitialized
    case alreadyInitialized
    case stateLocked(String)
    case badContactLink(String)
    case unknownContact(String)
    case ambiguousContact(String)
    case notARequest(String)
    case identityMismatch(expected: String, got: String)
    case stateUnreadable
    case notSponsored(String)
    case agentCannotSponsor
    case unknownSponsorship(String)
    case messageTooLarge
    case unknownGroup(String)
    case unknownThread(String)
    case badDuration
    case badProviderURL(String)
    case badSetting(String)
    case notAgentAccount
    case stateFromNewerBuild(found: Int, supported: Int)
    case bridgeGated(String)

    public var description: String {
        switch self {
        case .notInitialized: return "no identity here yet — run `eldr-chat init` first"
        case .alreadyInitialized: return "an identity already exists in this state directory"
        case .stateLocked(let p):
            return "state \(p) is in use by another eldr-chat (e.g. `listen`); use its outbox instead"
        case .badContactLink(let s): return "not a pqrc:add link, npub, or 64-hex pubkey: \(s)"
        case .unknownContact(let s): return "no contact matches '\(s)'"
        case .ambiguousContact(let s): return "'\(s)' matches more than one contact; be more specific"
        case .notARequest(let s): return "no pending request matches '\(s)'"
        case .notSponsored(let why):
            return "this is an AI account and has no live sponsorship from its owner (\(why)) — "
                + "ask the owner to sponsor it; nothing was sent"
        case .agentCannotSponsor: return "an AI account cannot sponsor, open AI windows or invites, or issue grants (agents cannot self-grant)"
        case .unknownSponsorship(let s): return "no sponsorship issued by you matches '\(s)'"
        case .unknownGroup(let s): return "no group matches '\(s)'"
        case .unknownThread(let s): return "no thread matches '\(s)'"
        case .badDuration: return "AI windows and invites last 1h, 8h or 24h"
        case .badProviderURL(let u): return "not an http(s) endpoint: \(u)"
        case .badSetting(let why): return why
        case .stateFromNewerBuild(let f, let sup):
            return "this state was written by a newer Eldr build (schema \(f); this build reads up to \(sup)). Refusing to open it so nothing is lost — run the newer build"
        case .notAgentAccount: return "the agent bridge only runs on an AI account (`eldr-chat agent-mode on --owner HEX`)"
        case .bridgeGated(let why): return "agent reply refused: \(why)"
        case .messageTooLarge: return "message is too large to send (over the chunk limit)"
        case .stateUnreadable:
            return "state.enc exists but cannot be decrypted/decoded — refusing to start (and "
                + "refusing to overwrite it). Restore it from a backup or move it aside."
        case .identityMismatch(let e, let g):
            return "binding identity \(g.prefix(12))… does not match expected \(e.prefix(12))…"
        }
    }
}

/// What the client surfaces to a front end (CLI, GTK, agent).
public enum ClientEvent: Sendable {
    case message(ContactRecord, ReceivedMessage, groupID: String? = nil)
    case request(nostrPubkeyHex: String, autoAccepted: Bool)
    case quarantined(wrapID: String, reason: String)
    case protocolViolation(senderIdentityHex: String, reason: String)
    case relayReconnected
    case saveFailed(String)
    /// The relay now publishes a validly signed binding for this contact's Nostr key that
    /// binds a DIFFERENT identity. The stored (old) identity stays trusted; the user must
    /// verify out-of-band before re-adding. Never adopted automatically.
    case bindingIdentityChanged(ContactRecord, newIdentityHex: String)
    /// Sponsorship lifecycle notices (received / refused / revoked), human-readable.
    case sponsorship(String)
    /// This contact reset and wants a new session; it needs the user's OK (AC166).
    /// `autoAccepted` is true when `approveReconnect` was given beforehand.
    case reconnectRequest(ContactRecord, autoAccepted: Bool)
    /// A group roster was created or changed (asserted by its sender).
    case groupChanged(GroupRecord)
    /// Someone added me to a group; nothing shows until I accept (AC220).
    case groupInvite(GroupRecord, from: ContactRecord)
    /// A window (conversation scope) or invite (thread scope) changed. `until` nil = ended.
    case aiWindow(identityHex: String, conversationID: String, until: Int64?)
    case aiInvite(identityHex: String, threadID: String, until: Int64?)
    case threadCreated(ThreadRecord)
    /// My AI posted (or failed: `error` set).
    case myAI(conversationID: String, threadID: String?, error: String?)
    case aiContextGrant(identityHex: String, conversationID: String, threadID: String?, axis: String, until: Int64?)
    /// I @-mentioned one of my AIs where it isn't live (no window, not solo): offer a
    /// private draft instead of posting (iOS decision #5).
    case aiMentionChoice(conversationID: String, aiName: String)
}

public typealias TransportFactory = @Sendable () async throws -> any RelayTransport

/// Default relay transport: SwiftNIO on Linux (URLSession WebSockets are unsupported by
/// Linux FoundationNetworking), URLSession where Network.framework exists.
public func defaultTransportFactory(url: String) -> TransportFactory {
    {
        guard let u = URL(string: url) else { throw EldrClientError.badContactLink(url) }
        #if canImport(Network)
        return await NostrWebSocketTransport(url: u).connect()
        #else
        return try await NIONostrTransport(url: u).connect()
        #endif
    }
}

/// Exclusive per-directory lock so two processes never advance the same ratchet
/// (a stale snapshot written by one would desync the session).
// @unchecked Sendable: `fd` is written only by init and by release(), which the owning
// EldrClient actor calls once from stop(); flock state itself lives in the kernel.
final class DirectoryLock: @unchecked Sendable {
    private var fd: Int32
    init(directory: URL) throws {
        let path = directory.appendingPathComponent(".lock").path
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            throw EldrClientError.stateLocked(directory.path)
        }
    }
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }
    deinit { release() }
}

/// The Linux client engine: one persona, its encrypted state, and a PQRCMessenger.
/// Every mutation (send, receive, accept, add) is followed by an encrypted save.
public actor EldrClient {
    public nonisolated let store: FileIdentityStore
    public let messenger: PQRCMessenger
    public nonisolated let identityHex: String
    public nonisolated let nostrPubkeyHex: String
    public internal(set) var state: ClientState
    let identity: PQRCIdentity
    /// Chunk reassembly buffers, keyed "<sender>:<chunk id>" (memory only, bounded).
    var chunkBuffers: [String: (template: MessageBody, total: Int, parts: [Int: String], order: Int)] = [:]
    var chunkCounter = 0
    let prekeyManager: PrekeyManager
    private let lock: DirectoryLock
    /// Requests from THIS Nostr key are accepted automatically (e.g. the owner), and only
    /// if its binding verifies (and matches `autoAcceptIdentityHex` when pinned).
    public private(set) var autoAcceptNostrHex: String?
    public private(set) var autoAcceptIdentityHex: String?
    private var started = false
    /// Identities refused by the auto-accept pin; their replayed messages never surface.
    private var rejectedIdentities: Set<String> = []
    private var pumpTask: Task<Void, Never>?
    /// SPEC §13 enforcement (windows, invites, loop guard, standing grants). Its only
    /// output path is `ClientAgentSink` → `post` (the recording guarantee).
    public let engine: AgentEngine
    let clock: any Clock
    let sinkRef: ClientRef
    /// In-flight AI turns (so `stop()` and tests can wait for them).
    var aiTasks: [Task<Void, Never>] = []
    /// Audit-2 L1: label-independent cap on my AI's AUTONOMOUS turns per scope.
    var autoTurnLimiter = AutoTurnLimiter()
    /// Test seam: overrides the configured OpenAI-compatible provider.
    var providerOverride: (any AgentProvider)?
    /// Test seam: providers for extra AIs by id.
    var aiOverrides: [String: any AgentProvider] = [:]
    /// AI-context marks that arrived before their message (message id → author, value).
    var pendingMarks: [String: (sender: String, value: Bool)] = [:]
    /// My AIs @-mentioned by my last send where they weren't live (for the CLI, which has no event stream).
    public internal(set) var lastMentionChoices: [String] = []
    /// The live relay transport, for the status panel (observational only).
    var relayTransport: (any RelayTransport)?
    var eventSink: AsyncStream<ClientEvent>.Continuation?

    static let keysAccount = "keys"
    static let stateAccount = "state"

    // MARK: - Lifecycle

    public static func exists(in store: FileIdentityStore) -> Bool {
        store.load(account: keysAccount) != nil
    }

    /// Creates a brand-new identity in an empty store.
    public static func initialize(store: FileIdentityStore, relays: [String]) throws {
        guard !exists(in: store) else { throw EldrClientError.alreadyInitialized }
        let r = SystemRandomSource()
        let keys = ClientKeys(
            nostrPrivateKey: try NostrKeypair(randomSource: r).privateKeyData,
            identitySeed: r.bytes(32), identityDH: r.bytes(32))
        try store.save(JSONEncoder().encode(keys), account: keysAccount)
        var st = ClientState()
        st.relays = relays
        st.schema = ClientState.currentSchema
        try store.save(JSONEncoder().encode(st), account: stateAccount)
    }

    /// Opens an existing identity: takes the directory lock, re-verifies every stored
    /// contact binding OFFLINE, restores sessions + seen IDs. Does not touch the network
    /// beyond dialing the transport.
    public init(
        store: FileIdentityStore, transport: TransportFactory, clock: any Clock = SystemClock()
    ) async throws {
        lock = try DirectoryLock(directory: store.directory)
        guard let kd = store.load(account: Self.keysAccount) else { throw EldrClientError.notInitialized }
        let keys = try JSONDecoder().decode(ClientKeys.self, from: kd)
        var st = ClientState()
        let stateFile = store.directory.appendingPathComponent("\(Self.stateAccount).enc")
        if FileManager.default.fileExists(atPath: stateFile.path) {
            // Fail closed: an unreadable state must never be replaced by an empty one
            // (that would silently drop every contact and ratchet session).
            guard let d = store.load(account: Self.stateAccount),
                let decoded = try? JSONDecoder().decode(ClientState.self, from: d)
            else { throw EldrClientError.stateUnreadable }
            let found = decoded.schema ?? 1
            guard found <= ClientState.currentSchema else {
                throw EldrClientError.stateFromNewerBuild(found: found, supported: ClientState.currentSchema)
            }
            st = decoded
        }
        let kp = try NostrKeypair(privateKey: keys.nostrPrivateKey)
        let identity = try PQRCIdentity(seed: keys.identitySeed)
        let pm = try st.prekeys.map {
            try PrekeyManager(identity: identity, randomSource: SystemRandomSource(), state: $0)
        } ?? PrekeyManager(identity: identity, randomSource: SystemRandomSource(), oneTimeCount: 16)
        if try await pm.replenish(to: 16) { st.publishedBundleStale = true }
        let liveTransport = try await transport()
        let m = try PQRCMessenger(
            identity: identity, nostrKeypair: kp, prekeyManager: pm,
            identityDH: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keys.identityDH),
            transports: [liveTransport], clock: clock,
            randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
        // Offline restore: a contact whose stored binding no longer verifies is DROPPED
        // (fail-closed), never trusted.
        var kept: [ContactRecord] = []
        for c in st.contacts {
            guard let vc = try? VerifiedContact(storedBindingEvent: c.bindingEvent),
                vc.identityHex == c.identityHex
            else { continue }
            await m.addContact(vc)
            if let snap = c.session { try? await m.restoreSession(with: vc, snapshot: snap) }
            kept.append(c)
        }
        st.contacts = kept
        await m.seedProcessedWrapIDs(Set(st.seenWrapIDs))
        self.store = store
        self.messenger = m
        self.relayTransport = liveTransport
        self.prekeyManager = pm
        self.identity = identity
        self.identityHex = identity.publicKeyData.hexString
        self.nostrPubkeyHex = kp.publicKeyHex
        self.state = st
        self.clock = clock
        let ref = ClientRef()
        self.sinkRef = ref
        self.engine = AgentEngine(
            myIdentity: identity, clock: clock, sink: ClientAgentSink(ref: ref),
            loopGuardLimit: st.settings?.loopGuardLimit ?? EldrClient.defaultLoopGuardLimit)
        try await persist()
        // Wire the engine's sink and replay signed AI state at OPEN, not at start():
        // one-shot CLI commands (ai-invite, thread send, ai-status) never call start(),
        // and without this their AI turns were dropped and live invites looked absent
        // (DEVIATIONS AC198).
        await ref.set(self)
        await replayAIState()
    }

    public func setAutoAccept(nostrPubkeyHex: String?, identityHex: String? = nil) {
        autoAcceptNostrHex = nostrPubkeyHex?.lowercased()
        autoAcceptIdentityHex = identityHex?.lowercased()
    }

    public var npub: String { Bech32.npub(nostrPubkeyHex) }
    public var pairingLink: PairingLink {
        PairingLink(nostrPubkeyHex: nostrPubkeyHex, relay: state.relays.first)
    }

    /// Publishes kind 10420 (binding), 10421 (prekey bundle), 10050 (relay list).
    public func announce(maxAttempts: Int = 10) async throws {
        try await messenger.announce(relayURLs: state.relays, maxAttempts: maxAttempts)
        state.publishedBundleStale = false
        try await persist()
    }

    /// Spent one-time prekeys must leave the PUBLISHED bundle promptly: a contact that
    /// reinstalls fetches it and picks an OTP at random, and a spent one is refused as a
    /// replay (AC165), so the reset contact stays silently unreachable. Refill and
    /// republish whenever a receive consumed one (best-effort, off the receive path).
    private func refreshBundleIfNeeded() async {
        if await prekeyManager.oneTimePrekeyCount < Self.otpTarget,
            (try? await prekeyManager.replenish(to: Self.otpTarget)) == true
        {
            state.publishedBundleStale = true
        }
        guard state.publishedBundleStale != false, !republishing else { return }
        republishing = true
        Task { [weak self] in
            try? await self?.announce(maxAttempts: 3)
            await self?.republishDone()
        }
    }
    private func republishDone() {
        republishing = false
        let w = bundleWaiters; bundleWaiters = []
        for c in w { c.resume() }
    }
    private var bundleWaiters: [CheckedContinuation<Void, Never>] = []

    /// True once every spent one-time prekey has been refilled AND republished (AC167).
    var publishedBundleIsFresh: Bool {
        get async {
            await prekeyManager.oneTimePrekeyCount >= Self.otpTarget && state.publishedBundleStale == false && !republishing
        }
    }

    /// Waits (event-driven, no polling) until the published bundle no longer lists a spent
    /// OTP, or one republish attempt has finished. Used by tests that pair a second contact
    /// right after a first: otherwise both initiators can draw the same OTP from the stale
    /// bundle and the second handshake is refused as a replay (the group-test flake).
    func waitForBundleRepublish() async {
        if await publishedBundleIsFresh { return }
        await refreshBundleIfNeeded()
        if !republishing { return }
        await withCheckedContinuation { bundleWaiters.append($0) }
    }
    private var republishing = false
    private var stopped = false
    private var bindingTask: Task<Void, Never>?
    static let otpTarget = 16
    static let maxRequests = 32

    // MARK: - Persistence

    /// Encrypted save of sessions, prekeys, contacts, requests and seen IDs.
    public func persist() async throws {
        // After stop() the lock is released; a late background task must not write.
        guard !stopped else { return }
        state.prekeys = await prekeyManager.snapshot()
        for i in state.contacts.indices {
            if let snap = await messenger.sessionSnapshot(peerIdentityHex: state.contacts[i].identityHex) {
                state.contacts[i].session = snap
            }
        }
        if state.seenWrapIDs.count > ClientState.maxSeen {
            state.seenWrapIDs.removeFirst(state.seenWrapIDs.count - ClientState.maxSeen)
        }
        state.schema = ClientState.currentSchema
        // Re-check after the awaits above (AC217): actor reentrancy let a persist that
        // passed the entry guard resume AFTER stop() released the lock and overwrite
        // state another process now owns (the flaky newerSchemaState test).
        guard !stopped else { return }
        try store.save(JSONEncoder().encode(state), account: Self.stateAccount)
    }

    // MARK: - Contacts

    public var contacts: [ContactRecord] { state.contacts }
    public var requests: [RequestRecord] { state.requests }

    /// Resolves a contact by name, identity hex / prefix, npub, or nostr hex / prefix.
    public func contact(matching q: String) throws -> ContactRecord {
        let s = q.trimmingCharacters(in: .whitespaces).lowercased()
        if let link = PairingLink.parse(q),
            let c = state.contacts.first(where: { $0.nostrPubkeyHex == link.nostrPubkeyHex })
        { return c }
        let hits = state.contacts.filter {
            $0.name?.lowercased() == s
                || (s.count >= 6 && ($0.identityHex.hasPrefix(s) || $0.nostrPubkeyHex.hasPrefix(s)))
        }
        if hits.count == 1 { return hits[0] }
        throw hits.isEmpty ? EldrClientError.unknownContact(q) : EldrClientError.ambiguousContact(q)
    }

    /// Fetches + verifies the peer's binding and prekeys from the relay and stores the
    /// contact (with its binding event). Optionally pins the expected identity hex.
    @discardableResult
    public func addContact(
        _ linkOrNpub: String, name: String? = nil, expectedIdentityHex: String? = nil
    ) async throws -> ContactRecord {
        guard let link = PairingLink.parse(linkOrNpub) else {
            throw EldrClientError.badContactLink(linkOrNpub)
        }
        let (vc, _) = try await messenger.fetchVerifiedPeer(
            nostrPubkeyHex: link.nostrPubkeyHex, timeout: .seconds(15))
        if let e = expectedIdentityHex?.lowercased(), e != vc.identityHex {
            throw EldrClientError.identityMismatch(expected: e, got: vc.identityHex)
        }
        return try await record(vc, name: name)
    }

    private func record(_ vc: VerifiedContact, name: String?) async throws -> ContactRecord {
        guard let event = await messenger.verifiedBindingEvent(nostrPubkeyHex: vc.nostrPubkeyHex)
        else { throw PQRCError.peerKeysNotPublished }
        let rec: ContactRecord
        if let i = state.contacts.firstIndex(where: { $0.nostrPubkeyHex == vc.nostrPubkeyHex }) {
            state.contacts[i].bindingEvent = event
            if let name { state.contacts[i].name = name }
            rec = state.contacts[i]
        } else {
            rec = ContactRecord(
                name: name, nostrPubkeyHex: vc.nostrPubkeyHex, identityHex: vc.identityHex,
                bindingEvent: event, session: nil, addedAt: Date())
            state.contacts.append(rec)
        }
        state.requests.removeAll { $0.nostrPubkeyHex == vc.nostrPubkeyHex }
        try await persist()
        return rec
    }

    /// Accepts a pending request (by npub / nostr hex prefix). If a listener is
    /// running in THIS process the held envelopes replay immediately; otherwise the
    /// relay re-delivers them the next time `start()` runs.
    @discardableResult
    public func accept(_ q: String, name: String? = nil) async throws -> ContactRecord {
        let s = PairingLink.parse(q)?.nostrPubkeyHex ?? q.lowercased()
        let hits = state.requests.filter { $0.nostrPubkeyHex.hasPrefix(s) }
        guard hits.count == 1, s.count >= 6 else { throw EldrClientError.notARequest(q) }
        let vc = try await messenger.acceptRequest(senderNostrPubkeyHex: hits[0].nostrPubkeyHex)
        return try await record(vc, name: name)
    }

    public func decline(_ q: String) async throws {
        let s = PairingLink.parse(q)?.nostrPubkeyHex ?? q.lowercased()
        guard let r = state.requests.first(where: { $0.nostrPubkeyHex.hasPrefix(s) }), s.count >= 6
        else { throw EldrClientError.notARequest(q) }
        await messenger.declineRequest(senderNostrPubkeyHex: r.nostrPubkeyHex)
        state.requests.removeAll { $0.nostrPubkeyHex == r.nostrPubkeyHex }
        try await persist()
    }

    // MARK: - Send

    /// Sends text to a contact, opening a PQXDH session first if none exists. Text over
    /// the relay's per-envelope budget is split into ordered chunks (inside the
    /// ciphertext) exactly like the iOS app does. In agent mode the message is labeled
    /// `agent` and carries this account's sponsorship; with no live sponsorship nothing
    /// is sent (checked on every send).
    @discardableResult
    public func send(_ text: String, to q: String) async throws -> DeliveryRoute {
        let c = try contact(matching: q)
        var body = MessageBody(
            text: text, sentAt: Int64(Date().timeIntervalSince1970), messageID: UUID().uuidString)
        let participant: ParticipantType = isAgent ? .agent : .human
        if isAgent { body.agentSponsorship = try liveSponsorship() }
        if participant == .human {
            let ms = resolveMentions(in: text)
            if !ms.isEmpty { body.mentions = ms }
        }
        var e = HistoryEntry(
            id: body.messageID ?? UUID().uuidString, peerIdentityHex: c.identityHex, outgoing: true,
            text: text, sentAt: body.sentAt, agent: isAgent, sponsorship: .human)
        if let s = body.agentSponsorship {
            e.sponsorship = .sponsored(sponsorIdentityHex: s.enabledBy.hexString, label: s.label, activeUntil: s.activeUntil)
        }
        let route: DeliveryRoute
        do {
            route = try await deliver(body, to: c, participant: participant)
        } catch {
            // Keep a "Not sent" row so the user can retry it (iOS localStatus .failed).
            e.failed = true
            appendHistory(e)
            try? await persist()
            throw error
        }
        appendHistory(e)
        try await persist()
        await afterMySend(text, conversationID: c.identityHex, threadID: nil)
        return route
    }

    /// Low-level delivery of one logical body (chunked if needed).
    func deliver(
        _ body: MessageBody, to c: ContactRecord, participant: ParticipantType,
        aiWindow: AIWindowAnnouncement? = nil
    ) async throws -> DeliveryRoute {
        if !(await messenger.hasSession(peerIdentityHex: c.identityHex)) {
            let (vc, bundle) = try await messenger.fetchVerifiedPeer(
                nostrPubkeyHex: c.nostrPubkeyHex, timeout: .seconds(15))
            guard vc.identityHex == c.identityHex else {
                throw EldrClientError.identityMismatch(expected: c.identityHex, got: vc.identityHex)
            }
            // The PQXDH handshake carries its first body human-labeled. A human,
            // single-envelope message rides it directly; an agent or chunked message
            // first opens the session with an empty opener (never rendered by this
            // client) so its label and chunks travel on ordinary ratchet messages.
            if participant == .human, aiWindow == nil,
                MessageChunker.split(body.text, budgetBytes: await messenger.chunkTextBudget()).count == 1
            {
                let r = try await messenger.establishSession(with: vc, bundle: bundle, firstMessage: body)
                try await persist()
                return r
            }
            let opener = MessageBody(text: "", sentAt: body.sentAt, messageID: UUID().uuidString)
            _ = try await messenger.establishSession(with: vc, bundle: bundle, firstMessage: opener)
        }
        let parts = MessageChunker.split(body.text, budgetBytes: await messenger.chunkTextBudget())
        guard parts.count <= PQRCConstants.maxChunksPerMessage else { throw EldrClientError.messageTooLarge }
        if parts.count == 1 {
            return try await messenger.send(body, to: c.identityHex, participantType: participant, aiWindow: aiWindow)
        }
        let id = UUID().uuidString
        let bodies = parts.enumerated().map { i, part -> MessageBody in
            var b = body
            b.text = part
            b.chunk = MessageChunk(id: id, index: i, total: parts.count)
            return b
        }
        return try await messenger.sendBatch(bodies, to: c.identityHex, participantType: participant, aiWindow: aiWindow)
    }

    // MARK: - Reconnect (AC166)

    /// Approves ONE reconnect from this contact: applied now if a request is
    /// pending in this process, otherwise remembered (encrypted) and applied to the
    /// next request that arrives. Returns true if a session was replaced now.
    @discardableResult
    public func approveReconnect(_ q: String) async throws -> Bool {
        let c = try contact(matching: q)
        if await messenger.acceptReconnect(peerIdentityHex: c.identityHex) {
            try await persist()
            return true
        }
        var a = state.approvedReconnects ?? []
        if !a.contains(c.identityHex) { a.append(c.identityHex) }
        state.approvedReconnects = a
        try await persist()
        return false
    }

    public func declineReconnect(_ q: String) async throws {
        let c = try contact(matching: q)
        await messenger.declineReconnect(peerIdentityHex: c.identityHex)
        state.approvedReconnects?.removeAll { $0 == c.identityHex }
        try await persist()
    }

    public func pendingReconnects() async -> [String] { await messenger.pendingReconnectPeers() }

    // MARK: - Receive

    /// Starts the receive pump. Messages are surfaced ONLY for verified contacts (the
    /// messenger holds everything else as a request); requests are recorded and, if
    /// they come from `autoAcceptIdentityHex`, accepted after the binding verifies.
    public func start() async throws -> AsyncStream<ClientEvent> {
        precondition(!started, "start() once per client")
        started = true
        await reapplyBlocks()
        let raw = try await messenger.start()
        await refreshBundleIfNeeded()
        let (stream, cont) = AsyncStream.makeStream(of: ClientEvent.self)
        eventSink = cont
        pumpTask = Task { [weak self] in
            for await ev in raw {
                guard let self else { break }
                for out in await self.handle(ev) { cont.yield(out) }
            }
            cont.finish()
        }
        // Background binding refresh (after the offline re-verify done at launch).
        bindingTask = Task { [weak self] in
            for ev in await self?.refreshBindings() ?? [] { cont.yield(ev) }
        }
        return stream
    }

    /// Re-fetches every contact's kind-10420 from the relay. Adopts a strictly newer,
    /// validly signed binding for the SAME identity; an identity change is reported and
    /// NOT adopted; forged / older / unreachable results change nothing.
    public func refreshBindings(timeout: Duration = .seconds(8)) async -> [ClientEvent] {
        var out: [ClientEvent] = []
        for c in state.contacts {
            switch await messenger.refreshContactBinding(stored: c.bindingEvent, timeout: timeout) {
            case .updated(let event):
                if let i = state.contacts.firstIndex(where: { $0.nostrPubkeyHex == c.nostrPubkeyHex }) {
                    state.contacts[i].bindingEvent = event
                }
            case .identityChanged(let newHex):
                out.append(.bindingIdentityChanged(c, newIdentityHex: newHex))
            case .unchanged, .invalid, .unavailable:
                break
            }
        }
        do { try await persist() } catch { out.append(.saveFailed("\(error)")) }
        return out
    }

    /// Stops receiving, saves, and releases the state-directory lock.
    public func stop() async {
        for t in aiTasks { await t.value }
        bindingTask?.cancel()
        await messenger.stop()
        pumpTask?.cancel()
        try? await persist()
        stopped = true
        lock.release()
    }

    func handle(_ ev: MessengerEvent) async -> [ClientEvent] {
        var out: [ClientEvent] = []
        switch ev {
        case .message(let msg):
            state.seenWrapIDs.append(msg.wrapEventID)
            var c = state.contacts.first(where: { $0.identityHex == msg.senderIdentityHex })
            // A request being accepted replays its held envelopes from INSIDE
            // `acceptRequest`, so (actor reentrancy) the message can land before
            // `accept()` records the contact. The messenger only emits messages for
            // verified contacts, so adopt that verified contact here rather than drop it.
            if c == nil, !rejectedIdentities.contains(msg.senderIdentityHex),
                let vc = await messenger.verifiedContact(identityHex: msg.senderIdentityHex) {
                c = try? await record(vc, name: nil)
            }
            if let c, let whole = reassemble(msg) {
                let full = ReceivedMessage(
                    senderIdentityHex: msg.senderIdentityHex, participantType: msg.participantType,
                    body: whole, contentPointer: msg.contentPointer, aiWindow: msg.aiWindow,
                    aiContextGrant: msg.aiContextGrant, wrapEventID: msg.wrapEventID)
                out.append(contentsOf: processControl(full))
                let status = sponsorshipStatus(of: full)
                let isControlOnly = full.body.text.isEmpty
                if let mark = full.body.aiContextMark { applyContextMark(mark, from: msg.senderIdentityHex) }
                let routed = routeGroup(full)
                if let g = routed.changed { out.append(.groupChanged(g)) }
                if let inv = routed.invite { out.append(.groupInvite(inv, from: c)) }
                if routed.drop { break }
                if routed.pending {
                    // Kept (hidden) so it shows if I accept; no AI, no notification.
                    if !isControlOnly {
                        var e = HistoryEntry(
                            id: whole.messageID ?? msg.wrapEventID, peerIdentityHex: c.identityHex,
                            outgoing: false, text: whole.text, sentAt: whole.sentAt,
                            agent: msg.participantType == .agent, sponsorship: status)
                        e.groupID = routed.groupID
                        appendHistory(e)
                    }
                    break
                }
                let conv = routed.groupID.map { UIConversation.group($0) } ?? c.identityHex
                let ai = await receiveAI(full, conversationID: conv)
                out.append(contentsOf: ai.events)
                if !isControlOnly {
                    var e = HistoryEntry(
                        id: whole.messageID ?? msg.wrapEventID, peerIdentityHex: c.identityHex,
                        outgoing: false, text: whole.text, sentAt: whole.sentAt,
                        agent: msg.participantType == .agent, sponsorship: status)
                    e.groupID = routed.groupID
                    e.threadID = ai.threadID
                    e.aiAuthorizedUntil = ai.authorizedUntil
                    e.aiContext = whole.aiContext == true ? true : nil
                    e.coauthored = whole.coauthored == true && msg.participantType == .agent ? true : nil
                    if whole.mentions?.contains(where: { $0.kind == "person" && $0.id == identityHex }) == true { e.mentionsMe = true }
                    applyPendingMark(to: &e)
                    appendHistory(e)
                    out.append(.message(c, full, groupID: routed.groupID))
                    scheduleMyAI(after: full, conversationID: conv, threadID: ai.threadID)
                }
            }
        case .messageRequest(let sender, _):
            let now = Date()
            if let i = state.requests.firstIndex(where: { $0.nostrPubkeyHex == sender }) {
                state.requests[i].lastSeen = now
                state.requests[i].count += 1
            } else {
                state.requests.append(
                    RequestRecord(nostrPubkeyHex: sender, firstSeen: now, lastSeen: now, count: 1))
                // Audit-2 R1: a flood of strangers must not grow persisted state without
                // bound. The messenger holds envelopes for only the newest 32 senders, so
                // older request records could never be accepted anyway.
                if state.requests.count > Self.maxRequests {
                    state.requests.sort { $0.lastSeen < $1.lastSeen }
                    state.requests.removeFirst(state.requests.count - Self.maxRequests)
                }
            }
            var accepted = false
            if sender == autoAcceptNostrHex,
                let vc = try? await messenger.acceptRequest(senderNostrPubkeyHex: sender)
            {
                if autoAcceptIdentityHex == nil || vc.identityHex == autoAcceptIdentityHex {
                    _ = try? await record(vc, name: nil)
                    accepted = true
                } else {
                    // The npub now binds a DIFFERENT identity than the pinned one: refuse.
                    rejectedIdentities.insert(vc.identityHex)
                    await messenger.setBlocked(vc.identityHex, blocked: true)
                }
            }
            out.append(.request(nostrPubkeyHex: sender, autoAccepted: accepted))
        case .quarantined(let w, let r): out.append(.quarantined(wrapID: w, reason: r))
        case .protocolViolation(let s, let r, _): out.append(.protocolViolation(senderIdentityHex: s, reason: r))
        case .relayReconnected: out.append(.relayReconnected)
        case .nearbyContact: break
        case .reconnectRequest(let sender):
            if let c = state.contacts.first(where: { $0.identityHex == sender }) {
                var approved = state.approvedReconnects ?? []
                var auto = false
                if approved.contains(sender) {
                    auto = await messenger.acceptReconnect(peerIdentityHex: sender)
                    if auto { approved.removeAll { $0 == sender } }
                    state.approvedReconnects = approved
                }
                out.append(.reconnectRequest(c, autoAccepted: auto))
            }
        }
        await refreshBundleIfNeeded()
        do { try await persist() } catch { out.append(.saveFailed("\(error)")) }
        return out
    }
}
