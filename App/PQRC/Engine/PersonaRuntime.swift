import Crypto
import Foundation
import PQRCAgent
import PQRCCore
import PQRCNostr
import SwiftData

/// Events the runtime surfaces to the UI layer (already persisted).
enum RuntimeEvent: Sendable {
    case messageAdded(StoredMessage)
    case conversationChanged(String)
    case messageRequest(senderNostrPubkeyHex: String)
    case protocolViolation(conversationID: String, reason: String)
    case aiWindowChanged(conversationID: String, identityHex: String, activeUntil: Int64?)
    case aiInviteChanged(threadID: String, identityHex: String, activeUntil: Int64?)
    case threadCreated(conversationID: String, threadID: String, title: String)
    case loopGuardChanged(threadID: String, paused: Bool)
    case safetyCodeChanged(identityHex: String)
}

/// One local persona: identity + messenger + agent engine + encrypted store.
/// The app has one; the Local Universe runs several over a shared relay.
actor PersonaRuntime {
    let displayName: String
    let keychain: KeychainStore

    private(set) var identity: PQRCIdentity!
    private(set) var nostrKeypair: NostrKeypair!
    private var messenger: PQRCMessenger!
    private var engine: AgentEngine!
    private var provider: any AgentProvider
    private let clock: any Clock
    private let randomSource: any RandomSource
    private let nonceSource: any NonceSource
    private let transports: [any RelayTransport]
    private let blobStore: any BlobStore
    /// SPEC §10 / S1: when enabled, co-present peers exchange seals directly
    /// over MultipeerConnectivity, with automatic relay fallback. Debug-only
    /// at the app layer (TESTFLIGHT-GUIDE §A6).
    private let enableLocalLink: Bool
    private var localLink: MultipeerLinkTransport?

    private var store: SwiftDataMessageStore!
    private var crypter: EncryptedStore!

    /// Contacts by identity hex with display names.
    private(set) var contacts: [String: (contact: VerifiedContact, nickname: String)] = [:]
    /// 1:1 conversation id == peer identity hex; groups use the group UUID.
    private var groupRosters: [String: GroupRoster] = [:]
    private var threadConversations: [String: String] = [:]  // threadID -> conversationID
    private var threadTitles: [String: String] = [:]
    /// Conversation my active ai_window was started in (window replies route here).
    private var myWindowConversationID: String?
    private var pumpTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RuntimeEvent>.Continuation?
    private var localSentAtBase: Int64 { clock.now() }

    init(
        displayName: String,
        transports: [any RelayTransport],
        blobStore: any BlobStore,
        provider: any AgentProvider,
        clock: any Clock = SystemClock(),
        randomSource: any RandomSource = SystemRandomSource(),
        nonceSource: any NonceSource = SystemNonceSource(),
        keychainService: String,
        enableLocalLink: Bool = false
    ) {
        self.displayName = displayName
        self.transports = transports
        self.blobStore = blobStore
        self.provider = provider
        self.clock = clock
        self.randomSource = randomSource
        self.nonceSource = nonceSource
        self.keychain = KeychainStore(service: keychainService)
        self.enableLocalLink = enableLocalLink
    }

    var identityHex: String { identity.publicKeyData.hexString }
    var npub: String { nostrKeypair.npub }

    func setProvider(_ newProvider: any AgentProvider) {
        provider = newProvider
    }

    // MARK: - Bootstrap

    /// Creates or restores the identity and starts everything.
    /// First launch generates keys (SPEC §3.1) and publishes 10420/10421/10050.
    func bootstrap(
        inMemoryStore: Bool, storeURL: URL? = nil, relayURLs: [String] = ["local://relay"]
    ) async throws -> AsyncStream<RuntimeEvent> {
        // Keys: load from Keychain or generate.
        if let seed = keychain.loadIfPresent(account: "identity-seed") {
            identity = try PQRCIdentity(seed: seed)
        } else {
            identity = try PQRCIdentity(randomSource: randomSource)
            try keychain.save(identity.privateKey.rawRepresentation, account: "identity-seed")
        }
        if let nostrPriv = keychain.loadIfPresent(account: "nostr-key") {
            nostrKeypair = try NostrKeypair(privateKey: nostrPriv)
        } else {
            nostrKeypair = try NostrKeypair(randomSource: randomSource)
            try keychain.save(nostrKeypair.privateKeyData, account: "nostr-key")
        }
        let identityDH: Curve25519.KeyAgreement.PrivateKey
        if let dhSeed = keychain.loadIfPresent(account: "identity-dh") {
            identityDH = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhSeed)
        } else {
            identityDH = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: randomSource.bytes(32))
            try keychain.save(identityDH.rawRepresentation, account: "identity-dh")
        }

        // Master storage key: unwrap via Secure Enclave or create fresh.
        let wrapper = SecureEnclaveKeyWrapper(keychain: keychain)
        if let wrapped = keychain.loadIfPresent(account: "wrapped-master-key"),
            let masterKey = try? wrapper.unwrap(wrapped: wrapped)
        {
            crypter = EncryptedStore(masterKey: masterKey, nonceSource: nonceSource)
        } else {
            crypter = EncryptedStore(randomSource: randomSource, nonceSource: nonceSource)
            try keychain.save(try crypter.wrappedMasterKey(using: wrapper), account: "wrapped-master-key")
        }

        let container = try SwiftDataMessageStore.makeContainer(inMemory: inMemoryStore, url: storeURL)
        store = SwiftDataMessageStore(modelContainer: container)
        await store.configure(crypter: crypter)

        let prekeyManager = try PrekeyManager(
            identity: identity, randomSource: randomSource, oneTimeCount: 16)
        messenger = try PQRCMessenger(
            identity: identity, nostrKeypair: nostrKeypair, prekeyManager: prekeyManager,
            identityDH: identityDH, transports: transports, clock: clock,
            randomSource: randomSource, nonceSource: nonceSource)
        engine = AgentEngine(myIdentity: identity, clock: clock, sink: RuntimeSink(runtime: self))

        // S1 local-first transport: constructed here because the hello proof
        // needs the (just-loaded) identity key, started before the messenger
        // so its receive pump catches every early connection.
        if enableLocalLink {
            let link = MultipeerLinkTransport(
                identity: identity,
                link: MultipeerNearbyLink(randomSource: randomSource),
                randomSource: randomSource)
            localLink = link
            await messenger.setLocalLink(link)
            try await link.start()
        }

        try await messenger.announce(relayURLs: relayURLs)
        let messengerEvents = try await messenger.start()
        let (stream, continuation) = AsyncStream.makeStream(of: RuntimeEvent.self)
        eventContinuation = continuation
        pumpTask = Task { [weak self] in
            for await event in messengerEvents {
                await self?.handle(event)
            }
        }
        return stream
    }

    func shutdown() async {
        pumpTask?.cancel()
        await localLink?.stop()
        await messenger?.stop()
        eventContinuation?.finish()
    }

    /// Settings → wipe identity (double-confirmed in UI): destroys keys + store.
    func wipeIdentity() async throws {
        try await store.wipeAll()
        keychain.deleteAll()
        await shutdown()
    }

    // MARK: - Contacts & sessions

    func addVerifiedPeer(_ runtimePeer: PersonaRuntime) async throws {
        let binding = try IdentityBinding.make(
            identity: await runtimePeer.identity,
            nostrPubkey: hexToData(await runtimePeer.nostrKeypair.publicKeyHex))
        let contact = VerifiedContact(
            binding: try BindingVerifier.verify(binding, outerSignatureValid: true))
        contacts[contact.identityHex] = (contact, await runtimePeer.displayName)
        await messenger.addContact(contact)
    }

    /// New chat by npub: fetch 10420/10421 from relays, verify BOTH directions,
    /// verify prekey signatures, then PQXDH with message #0 (D10).
    func startConversation(npub: String, firstMessage: String) async throws -> String {
        guard let nostrHex = Bech32.pubkeyHex(fromNpub: npub) else {
            throw PQRCError.handshakeMalformed
        }
        let (contact, bundle) = try await messenger.fetchVerifiedPeer(nostrPubkeyHex: nostrHex)
        contacts[contact.identityHex] = (contact, "Contact \(String(contact.identityHex.prefix(8)))")
        let body = MessageBody(text: firstMessage, sentAt: clock.now())
        try await messenger.establishSession(with: contact, bundle: bundle, firstMessage: body)
        let message = StoredMessage(
            id: UUID().uuidString, conversationID: contact.identityHex,
            senderIdentity: identityHex, participantType: .human, text: firstMessage,
            sentAt: clock.now(), localStatus: "sent")
        try await store.save(message)
        eventContinuation?.yield(.messageAdded(message))
        return contact.identityHex
    }

    /// Direct establishment between Local Universe personas (no QR scan).
    func establishWith(_ peer: PersonaRuntime, firstMessage: String) async throws {
        let peerIdentityHex = await peer.identityHex
        guard let (contact, _) = contacts[peerIdentityHex] else { throw PQRCError.sessionNotEstablished }
        let bundle = try await peer.publicBundle()
        try bundle.verifySignatures(identityPubkey: contact.binding.identityPubkey)
        let body = MessageBody(text: firstMessage, sentAt: clock.now())
        try await messenger.establishSession(with: contact, bundle: bundle, firstMessage: body)
        let message = StoredMessage(
            id: UUID().uuidString, conversationID: peerIdentityHex,
            senderIdentity: identityHex, participantType: .human, text: firstMessage,
            sentAt: clock.now(), localStatus: "sent")
        try await store.save(message)
        eventContinuation?.yield(.messageAdded(message))
    }

    func publicBundle() async throws -> PrekeyBundle {
        try await messenger.prekeyManager.publicBundle()
    }

    func oneTimePrekeyCount() async -> Int {
        await messenger.prekeyManager.oneTimePrekeyCount
    }

    func setBlocked(_ identityHex: String, blocked: Bool) async {
        await messenger.setBlocked(identityHex, blocked: blocked)
    }

    // MARK: - Message requests (D12)

    /// Accepts a pending request: the messenger fetches + verifies the
    /// sender's binding (both directions), registers the contact, and replays
    /// the held handshake so message #0 materializes. Returns the new
    /// conversation id so the UI can navigate into it.
    func acceptMessageRequest(senderNostrPubkeyHex: String) async throws -> String {
        let contact = try await messenger.acceptRequest(senderNostrPubkeyHex: senderNostrPubkeyHex)
        contacts[contact.identityHex] = (contact, "Contact \(String(contact.identityHex.prefix(8)))")
        eventContinuation?.yield(.conversationChanged(contact.identityHex))
        return contact.identityHex
    }

    func declineMessageRequest(senderNostrPubkeyHex: String) async {
        await messenger.declineRequest(senderNostrPubkeyHex: senderNostrPubkeyHex)
    }

    // MARK: - Sending

    /// Sends a human (or agent) message into a conversation, fanning out for
    /// groups. >64 KB content takes the blob path automatically (SPEC §11).
    func sendMessage(
        _ text: String, conversationID: String, participantType: ParticipantType = .human,
        threadID: String? = nil, isContext: Bool = false,
        aiWindow: AIWindowAnnouncement? = nil, aiInvite: AIInvite? = nil,
        threadCreate: ThreadCreate? = nil, groupCreate: GroupCreate? = nil
    ) async throws {
        let recipients = recipientsFor(conversationID: conversationID)
        guard !recipients.isEmpty else { throw PQRCError.sessionNotEstablished }

        var body = MessageBody(
            text: text, sentAt: clock.now(),
            group: groupRosters[conversationID].map { _ in RumorContent.GroupRef(id: conversationID) },
            thread: threadID.map { RumorContent.ThreadRef(id: $0) },
            groupCreate: groupCreate, threadCreate: threadCreate, aiInvite: aiInvite,
            isContext: isContext ? true : nil)

        var pointer: ContentPointer?
        if text.utf8.count > PQRCConstants.inlineSizeLimit {
            // Blob path: encrypt, upload, send the pointer; preview text inline.
            pointer = try await BlobCipher.encryptAndStore(
                Data(text.utf8), store: blobStore,
                randomSource: randomSource, nonceSource: nonceSource)
            body.text = "[Encrypted attachment · \(text.utf8.count / 1024) KB]"
        }

        for recipient in recipients {
            try await messenger.send(
                body, to: recipient, participantType: participantType,
                contentPointer: pointer, aiWindow: aiWindow)
        }

        let message = StoredMessage(
            id: UUID().uuidString, conversationID: conversationID,
            senderIdentity: identityHex, participantType: participantType,
            text: body.text, sentAt: body.sentAt, threadID: threadID,
            isContext: isContext, localStatus: "sent")
        try await store.save(message)
        if let threadID {
            await engine.recordThreadMessage(threadID: threadID, participantType: participantType)
            eventContinuation?.yield(
                .loopGuardChanged(
                    threadID: threadID, paused: await engine.loopGuardActive(threadID: threadID)))
        }
        eventContinuation?.yield(.messageAdded(message))
    }

    private func recipientsFor(conversationID: String) -> [String] {
        if let roster = groupRosters[conversationID] {
            return roster.members.filter { $0 != identityHex && contacts[$0] != nil }
        }
        return contacts[conversationID] != nil ? [conversationID] : []
    }

    // MARK: - Groups (D1)

    func createGroup(name: String, memberIdentityHexes: [String]) async throws -> String {
        let groupID = UUID().uuidString
        let members = [identityHex] + memberIdentityHexes
        let create = GroupCreate(groupID: groupID, name: name, members: members, revision: 1)
        groupRosters[groupID] = GroupRoster(create: create, assertedBy: identityHex)
        try await sendMessage(
            "created the group \"\(name)\"", conversationID: groupID, groupCreate: create)
        eventContinuation?.yield(.conversationChanged(groupID))
        return groupID
    }

    func groupRoster(_ groupID: String) -> GroupRoster? {
        groupRosters[groupID]
    }

    func reviseRoster(groupID: String, name: String, members: [String]) async throws {
        guard let roster = groupRosters[groupID] else { return }
        let create = GroupCreate(
            groupID: groupID, name: name, members: members, revision: roster.revision + 1)
        var updated = roster
        _ = updated.apply(create, assertedBy: identityHex)
        groupRosters[groupID] = updated
        // Announce to the union of old and new members so removed members learn.
        let union = Set(roster.members + members).filter { $0 != identityHex && contacts[$0] != nil }
        let body = MessageBody(
            text: "updated the group", sentAt: clock.now(),
            group: RumorContent.GroupRef(id: groupID), groupCreate: create)
        for member in union {
            try await messenger.send(body, to: member, participantType: .human)
        }
        eventContinuation?.yield(.conversationChanged(groupID))
    }

    // MARK: - Threads & AI (SPEC §13, APP-SPEC §8–9)

    func createThread(conversationID: String, title: String) async throws -> String {
        let threadID = UUID().uuidString
        threadConversations[threadID] = conversationID
        threadTitles[threadID] = title
        let create = ThreadCreate(
            threadID: threadID, title: title, anchorMessageID: nil, createdBy: identityHex)
        try await sendMessage(
            "started the thread \"\(title)\"", conversationID: conversationID,
            threadID: threadID, threadCreate: create)
        eventContinuation?.yield(
            .threadCreated(conversationID: conversationID, threadID: threadID, title: title))
        return threadID
    }

    func draftReply(conversationID: String, threadID: String? = nil) async throws -> Draft {
        try await engine.draft(
            provider: provider, context: await agentContext(conversationID: conversationID, threadID: threadID))
    }

    func startAIWindow(conversationID: String, durationSeconds: Int64) async throws {
        let announcement = try await engine.startMyWindow(durationSeconds: durationSeconds)
        myWindowConversationID = conversationID
        try await sendMessage(
            "enabled always-on AI", conversationID: conversationID, aiWindow: announcement)
        eventContinuation?.yield(
            .aiWindowChanged(
                conversationID: conversationID, identityHex: identityHex,
                activeUntil: announcement.activeUntil))
    }

    func inviteMyAI(threadID: String, durationSeconds: Int64) async throws {
        guard let conversationID = threadConversations[threadID] else { return }
        let invite = try await engine.startMyInvite(
            threadID: threadID, durationSeconds: durationSeconds)
        try await sendMessage(
            "invited their AI to the thread", conversationID: conversationID,
            threadID: threadID, aiInvite: invite)
        eventContinuation?.yield(
            .aiInviteChanged(
                threadID: threadID, identityHex: identityHex, activeUntil: invite.activeUntil))
        // My agent may open the thread conversation immediately.
        await takeAgentThreadTurn(threadID: threadID)
    }

    func withdrawMyAI(threadID: String) async {
        await engine.withdrawMyInvite(threadID: threadID)
        eventContinuation?.yield(
            .aiInviteChanged(threadID: threadID, identityHex: identityHex, activeUntil: nil))
    }

    func sendAsMyAI(_ text: String, conversationID: String) async throws {
        try await sendMessage(text, conversationID: conversationID, participantType: .agent)
    }

    private func agentContext(conversationID: String, threadID: String?) async -> AgentContext {
        let stored = (try? await (threadID != nil
            ? store.messages(threadID: threadID!)
            : store.messages(conversationID: conversationID))) ?? []
        let transcript = stored.suffix(20).map { message in
            TranscriptEntry(
                senderIdentityHex: message.senderIdentity,
                senderDisplayName: message.senderIdentity == identityHex
                    ? displayName : (contacts[message.senderIdentity]?.nickname ?? "Contact"),
                participantType: message.participantType,
                text: message.text,
                isContext: message.isContext)
        }
        return AgentContext(
            myIdentityHex: identityHex, myDisplayName: displayName,
            transcript: Array(transcript), threadID: threadID,
            threadTitle: threadID.flatMap { threadTitles[$0] })
    }

    /// Runs my agent's turn in a thread (gated entirely by the engine).
    func takeAgentThreadTurn(threadID: String) async {
        let conversationID = threadConversations[threadID] ?? ""
        guard !conversationID.isEmpty else { return }
        _ = await engine.runThreadTurn(
            provider: provider,
            context: await agentContext(conversationID: conversationID, threadID: threadID),
            threadID: threadID)
        eventContinuation?.yield(
            .loopGuardChanged(
                threadID: threadID, paused: await engine.loopGuardActive(threadID: threadID)))
    }

    func engineActiveWindow(identityHex: String) async -> Int64? {
        await engine.activeWindow(for: identityHex)
    }

    func engineActiveInvite(threadID: String, identityHex: String) async -> Int64? {
        await engine.activeInvite(threadID: threadID, identityHex: identityHex)
    }

    // MARK: - Receive pipeline

    private func handle(_ event: MessengerEvent) async {
        switch event {
        case .message(let received):
            await handleReceived(received)
        case .messageRequest(let sender, _):
            eventContinuation?.yield(.messageRequest(senderNostrPubkeyHex: sender))
        case .protocolViolation(let sender, let reason, _):
            // Red system row (SPEC §13.4) — persisted so it renders in place.
            let row = StoredMessage(
                id: UUID().uuidString, conversationID: sender,
                senderIdentity: sender, participantType: .human,
                text: "⚠️ Protocol violation: \(reason)", sentAt: clock.now(),
                localStatus: "violation")
            try? await store.save(row)
            eventContinuation?.yield(.protocolViolation(conversationID: sender, reason: reason))
            eventContinuation?.yield(.messageAdded(row))
        case .quarantined(_, let reason):
            Log.engine.info("envelope quarantined: \(reason, privacy: .public)")
        }
    }

    private func handleReceived(_ received: ReceivedMessage) async {
        let senderHex = received.senderIdentityHex
        var conversationID = senderHex
        let body = received.body

        // Group routing/roster (D1).
        if let create = body.groupCreate {
            var roster = groupRosters[create.groupID]
                ?? GroupRoster(create: create, assertedBy: senderHex)
            _ = roster.apply(create, assertedBy: senderHex)
            groupRosters[create.groupID] = roster
            conversationID = create.groupID
            eventContinuation?.yield(.conversationChanged(create.groupID))
        } else if let group = body.group {
            conversationID = group.id
        }

        // Thread bookkeeping (D7).
        if let create = body.threadCreate {
            threadConversations[create.threadID] = conversationID
            threadTitles[create.threadID] = create.title
            eventContinuation?.yield(
                .threadCreated(
                    conversationID: conversationID, threadID: create.threadID, title: create.title))
        }

        // ai_window announcements: engine-validated; invalid ones are dropped
        // (agents cannot self-activate, SPEC §13.3).
        if let window = received.aiWindow {
            if (try? await engine.receiveWindow(window, fromSenderIdentityHex: senderHex)) != nil {
                eventContinuation?.yield(
                    .aiWindowChanged(
                        conversationID: conversationID, identityHex: senderHex,
                        activeUntil: window.activeUntil))
            }
        }
        if let invite = body.aiInvite {
            if (try? await engine.receiveInvite(invite, fromSenderIdentityHex: senderHex)) != nil {
                eventContinuation?.yield(
                    .aiInviteChanged(
                        threadID: invite.thread.id, identityHex: senderHex,
                        activeUntil: invite.activeUntil))
            }
        }

        // Blob path: resolve the pointer to the real content (SPEC §11).
        // Large content is stored as a bounded preview — rendering hundreds of
        // KB inline produces a six-figure-point bubble that breaks the list.
        var text = body.text
        if let pointer = received.contentPointer,
            let blob = try? await BlobCipher.fetchAndDecrypt(pointer, store: blobStore)
        {
            let full = String(decoding: blob, as: UTF8.self)
            if full.utf8.count > 4096 {
                text = full.prefix(600)
                    + "\n… [\(pointer.sizeBytes / 1024) KB encrypted attachment]"
            } else {
                text = full
            }
        }

        let message = StoredMessage(
            id: UUID().uuidString, conversationID: conversationID,
            senderIdentity: senderHex, participantType: received.participantType,
            text: text, sentAt: body.sentAt, threadID: body.thread?.id,
            isContext: body.isContext ?? false, localStatus: "received")
        try? await store.save(message)
        eventContinuation?.yield(.messageAdded(message))

        // Agent reactions — every gate lives in the engine (fail closed).
        if let threadID = body.thread?.id {
            await engine.recordThreadMessage(
                threadID: threadID, participantType: received.participantType)
            eventContinuation?.yield(
                .loopGuardChanged(
                    threadID: threadID, paused: await engine.loopGuardActive(threadID: threadID)))
            await takeAgentThreadTurn(threadID: threadID)
        } else if received.participantType == .human, senderHex != identityHex {
            // Conversation scope: only during MY active ai_window.
            _ = await engine.runWindowReply(
                provider: provider,
                context: await agentContext(conversationID: conversationID, threadID: nil))
        }
    }

    // MARK: - Store access for the UI

    func messages(conversationID: String) async -> [StoredMessage] {
        (try? await store.messages(conversationID: conversationID)) ?? []
    }

    func messages(threadID: String) async -> [StoredMessage] {
        (try? await store.messages(threadID: threadID)) ?? []
    }

    func threadInfo(threadID: String) -> (conversationID: String, title: String)? {
        guard let conversation = threadConversations[threadID] else { return nil }
        return (conversation, threadTitles[threadID] ?? "Thread")
    }

    func contactName(_ identityHex: String) -> String {
        identityHex == self.identityHex ? displayName : (contacts[identityHex]?.nickname ?? "Contact")
    }

    /// 60-digit safety code in 12 groups (APP-SPEC §6.4, D13).
    func safetyCode(with peerIdentityHex: String) -> String {
        guard let (contact, _) = contacts[peerIdentityHex] else { return "" }
        let keys = [identity.publicKeyData, contact.binding.identityPubkey]
            .sorted { $0.hexString < $1.hexString }
        var digest = sha256(keys[0] + keys[1])
        // Stretch to 60 decimal digits from repeated hashing (display encoding only).
        var digits = ""
        while digits.count < 60 {
            for byte in digest where digits.count < 60 {
                digits += String(byte % 10)
            }
            digest = sha256(digest)
        }
        return stride(from: 0, to: 60, by: 5).map {
            String(digits.dropFirst($0).prefix(5))
        }.joined(separator: " ")
    }
}

/// The engine's only output path, bound to the runtime (recording guarantee).
private struct RuntimeSink: AgentMessageSink {
    let runtime: PersonaRuntime

    func postAgentMessage(_ body: MessageBody, threadID: String) async throws {
        guard let info = await runtime.threadInfo(threadID: threadID) else {
            throw PQRCError.sessionNotEstablished
        }
        try await runtime.sendMessage(
            body.text, conversationID: info.conversationID, participantType: .agent,
            threadID: threadID, isContext: body.isContext ?? false)
    }

    func postAgentReply(_ body: MessageBody) async throws {
        // The engine only calls this during MY active window; the reply goes to
        // the conversation the window was started in (single scope in v1).
        guard let conversationID = await runtime.windowConversation() else { return }
        try await runtime.sendMessage(
            body.text, conversationID: conversationID, participantType: .agent)
    }
}

extension PersonaRuntime {
    func windowConversation() -> String? {
        myWindowConversationID
    }
}

func hexToData(_ hex: String) -> Data {
    Data(hexString: hex) ?? Data()
}
