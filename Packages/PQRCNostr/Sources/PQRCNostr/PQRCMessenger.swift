import Crypto
import Foundation
import PQRCCore

/// A contact whose kind-10420 binding has been verified in both directions.
/// Only verified contacts can hold sessions (CLAUDE.md invariant 7).
public struct VerifiedContact: Sendable, Equatable {
    public let binding: VerifiedBinding
    /// The raw binding the verification ran against, kept so the app layer
    /// can persist it and re-verify on restore. Trust still flows only
    /// through `binding` (the `VerifiedBinding` type-state).
    public let raw: IdentityBinding?
    public var nostrPubkeyHex: String { binding.nostrPubkey.hexString }
    public var identityHex: String { binding.identityPubkey.hexString }

    public init(binding: VerifiedBinding, raw: IdentityBinding? = nil) {
        self.binding = binding
        self.raw = raw
    }
}

/// A decrypted, verified, displayable message.
public struct ReceivedMessage: Sendable {
    public let senderIdentityHex: String
    public let participantType: ParticipantType
    public let body: MessageBody
    public let contentPointer: ContentPointer?
    public let aiWindow: AIWindowAnnouncement?
    public let wrapEventID: String
}

/// Everything the engine surfaces to the app layer.
public enum MessengerEvent: Sendable {
    case message(ReceivedMessage)
    /// SPEC §13.4: e.g. a human label under an agent signature — render as a
    /// red protocol-violation system row, never as a normal message.
    case protocolViolation(senderIdentityHex: String, reason: String, wrapEventID: String)
    /// Handshake from a sender not in contacts: message-requests inbox (D12).
    case messageRequest(senderNostrPubkeyHex: String, wrapEventID: String)
    /// Out-of-order beyond MAX_SKIP or otherwise quarantined (APP-SPEC §13).
    case quarantined(wrapEventID: String, reason: String)
}

/// The client engine: send pipeline (encrypt → wrap → outbox → publish) and
/// receive pipeline (subscribe → dedupe → unwrap → blocklist → decrypt →
/// verify agent authenticity → emit). One instance per local persona.
public actor PQRCMessenger {
    // Identity material
    public let identity: PQRCIdentity
    public let nostrKeypair: NostrKeypair
    public let prekeyManager: PrekeyManager
    private let agentKey: Curve25519.Signing.PrivateKey
    private let identityDH: Curve25519.KeyAgreement.PrivateKey

    // Seams
    private let clock: any Clock
    private let randomSource: any RandomSource
    private let nonceSource: any NonceSource
    private var transports: [any RelayTransport]
    /// SPEC §10 local-first path. When set, every outgoing message tries the
    /// local link first and falls back to relay delivery automatically; set
    /// before `start()` so the receive pump covers it.
    private var localLink: (any LocalLinkTransport)?
    /// Blocklist check applied post-unseal (D8): the relay cannot filter by
    /// sender (the sender is hidden by design), so we drop on-device.
    private var blockedIdentityHexes: Set<String> = []

    // State
    private var contactsByNostrPub: [String: VerifiedContact] = [:]
    private var sessions: [String: PQRCSession] = [:]  // peer identity hex -> session
    private var processedWrapIDs: Set<String> = []
    private var pendingRetry: [GiftWrap.Unwrapped] = []
    /// Unknown-sender envelopes held for the message-request gate (D12),
    /// keyed by sender Nostr pubkey hex. Bounded both ways so a spray of
    /// strangers cannot grow memory: at most 32 pending senders, at most 16
    /// envelopes each (oldest evicted first).
    private var pendingRequests: [String: [GiftWrap.Unwrapped]] = [:]
    private var pendingRequestOrder: [String] = []
    private var pumpTasks: [Task<Void, Never>] = []

    // Output
    private var eventContinuation: AsyncStream<MessengerEvent>.Continuation?
    public private(set) var outboundRetryBaseMillis: Int

    public init(
        identity: PQRCIdentity,
        nostrKeypair: NostrKeypair,
        prekeyManager: PrekeyManager,
        identityDH: Curve25519.KeyAgreement.PrivateKey,
        transports: [any RelayTransport],
        clock: any Clock,
        randomSource: any RandomSource,
        nonceSource: any NonceSource,
        outboundRetryBaseMillis: Int = 50
    ) throws {
        self.identity = identity
        self.nostrKeypair = nostrKeypair
        self.prekeyManager = prekeyManager
        self.identityDH = identityDH
        self.transports = transports
        self.clock = clock
        self.randomSource = randomSource
        self.nonceSource = nonceSource
        self.agentKey = try AgentKeyDeriver.deriveAgentKey(from: identity)
        self.outboundRetryBaseMillis = outboundRetryBaseMillis
    }

    public var identityHex: String { identity.publicKeyData.hexString }

    // MARK: - Setup / announcement

    /// Publishes the kind 10420 binding, 10421 bundle and 10050 relay list.
    /// `maxAttempts` bounds the per-event retry: callers that publish at boot
    /// pass a small value so a down relay logs a few lines instead of flooding.
    public func announce(relayURLs: [String], maxAttempts: Int = 60) async throws {
        let now = clock.now()
        let binding = try IdentityBinding.make(
            identity: identity, nostrPubkey: Data(hexString: nostrKeypair.publicKeyHex) ?? Data())
        let bindingEvent = try PQRCEvents.bindingEvent(
            binding: binding, signer: nostrKeypair, createdAt: now, randomSource: randomSource)
        let bundle = try await prekeyManager.publicBundle()
        let bundleEvent = try PQRCEvents.prekeyBundleEvent(
            bundle: bundle, signer: nostrKeypair, createdAt: now, randomSource: randomSource)
        let relayList = try PQRCEvents.relayListEvent(
            relayURLs: relayURLs, signer: nostrKeypair, createdAt: now, randomSource: randomSource)
        for event in [bindingEvent, bundleEvent, relayList] {
            try await publishWithRetry(event, maxAttempts: maxAttempts)
        }
    }

    /// Fetches and verifies a peer's 10420 + 10421 from any connected relay.
    /// Verification is all-or-nothing: no keys come back unless BOTH the
    /// binding (both directions) and every prekey signature verify.
    public func fetchVerifiedPeer(
        nostrPubkeyHex: String
    ) async throws -> (contact: VerifiedContact, bundle: PrekeyBundle) {
        for transport in transports {
            let stream = await transport.subscribe([
                NostrFilter(
                    kinds: [PQRCConstants.bindingEventKind, PQRCConstants.prekeyBundleEventKind],
                    authors: [nostrPubkeyHex])
            ])
            var bindingEvent: NostrEvent?
            var bundleEvent: NostrEvent?
            for try await event in stream {
                if event.kind == PQRCConstants.bindingEventKind { bindingEvent = event }
                if event.kind == PQRCConstants.prekeyBundleEventKind { bundleEvent = event }
                if bindingEvent != nil && bundleEvent != nil { break }
            }
            guard let bindingEvent, let bundleEvent else { continue }
            let (verified, raw) = try PQRCEvents.verifyBindingEventWithRaw(bindingEvent)
            let bundle = try PQRCEvents.verifyPrekeyBundleEvent(
                bundleEvent, verifiedBinding: verified)
            let contact = VerifiedContact(binding: verified, raw: raw)
            contactsByNostrPub[contact.nostrPubkeyHex] = contact
            return (contact, bundle)
        }
        throw NostrError.invalidEvent
    }

    public func addContact(_ contact: VerifiedContact) {
        contactsByNostrPub[contact.nostrPubkeyHex] = contact
    }

    public func verifiedContact(identityHex: String) -> VerifiedContact? {
        contactsByNostrPub.values.first { $0.identityHex == identityHex }
    }

    /// Restores a persisted ratchet session (T2/persistence): the contact must
    /// already be added (its binding re-verified by the caller — invariant 7
    /// still gates every key through `BindingVerifier.verify`).
    public func restoreSession(
        with contact: VerifiedContact, snapshot: RatchetSnapshot,
        usedLastResortPrekey: Bool = false
    ) throws {
        sessions[contact.identityHex] = try PQRCSession(
            snapshot: snapshot,
            peerIdentityPubkey: contact.binding.identityPubkey,
            usedLastResortPrekey: usedLastResortPrekey,
            clock: clock, randomSource: randomSource)
    }

    // MARK: - Message requests (D12)

    /// Accepts a pending message request: fetches and fully verifies the
    /// sender's 10420/10421, adds the contact, then replays every held
    /// envelope through the normal pipeline (handshake → session → message).
    /// Returns the verified contact so the caller can persist it.
    public func acceptRequest(senderNostrPubkeyHex: String) async throws -> VerifiedContact {
        let (contact, _) = try await fetchVerifiedPeer(nostrPubkeyHex: senderNostrPubkeyHex)
        let held = pendingRequests.removeValue(forKey: senderNostrPubkeyHex) ?? []
        pendingRequestOrder.removeAll { $0 == senderNostrPubkeyHex }
        for unwrapped in held {
            await processUnwrapped(unwrapped)
        }
        return contact
    }

    /// Declines a pending request: held envelopes are dropped. The sender is
    /// NOT blocked (a later request may be accepted); use `setBlocked` for that.
    public func declineRequest(senderNostrPubkeyHex: String) {
        pendingRequests.removeValue(forKey: senderNostrPubkeyHex)
        pendingRequestOrder.removeAll { $0 == senderNostrPubkeyHex }
    }

    /// Attaches the local-first transport (SPEC §10). Must be called before
    /// `start()` — the local receive pump is wired up there.
    public func setLocalLink(_ link: any LocalLinkTransport) {
        localLink = link
    }

    /// Seeds the envelope-dedupe set from persistence. Must be called before
    /// `start()`: relays replay stored envelopes to every fresh subscription,
    /// and without the seed each relaunch re-processes history (the ratchet
    /// rejects it — keys are deleted — but it churns the retry queue).
    public func seedProcessedWrapIDs(_ ids: Set<String>) {
        processedWrapIDs.formUnion(ids)
    }

    public func setBlocked(_ identityHex: String, blocked: Bool) {
        if blocked {
            blockedIdentityHexes.insert(identityHex)
        } else {
            blockedIdentityHexes.remove(identityHex)
        }
    }

    // MARK: - Session establishment

    /// Initiator: PQXDH from a verified bundle; message #0 piggybacks (D10).
    public func establishSession(
        with contact: VerifiedContact, bundle: PrekeyBundle, firstMessage: MessageBody
    ) async throws {
        try bundle.verifySignatures(identityPubkey: contact.binding.identityPubkey)
        let initiation = try PQXDH.initiate(
            myIdentity: identity, myIdentityDH: identityDH, peerBundle: bundle,
            randomSource: randomSource)
        let session = try PQRCSession(
            initiation: initiation, peerIdentityPubkey: contact.binding.identityPubkey,
            clock: clock, randomSource: randomSource)
        sessions[contact.identityHex] = session
        let outgoing = try await session.encrypt(
            body: firstMessage, type: .handshake, participantType: .human,
            handshake: initiation.message)
        try await deliver(outgoing, to: contact)
    }

    // MARK: - Send

    public func send(
        _ body: MessageBody,
        to peerIdentityHex: String,
        participantType: ParticipantType = .human,
        contentPointer: ContentPointer? = nil,
        aiWindow: AIWindowAnnouncement? = nil
    ) async throws {
        guard let session = sessions[peerIdentityHex],
            let contact = contactsByNostrPub.values.first(where: { $0.identityHex == peerIdentityHex })
        else { throw PQRCError.sessionNotEstablished }
        var outgoing = try await session.encrypt(
            body: body, participantType: participantType,
            contentPointer: contentPointer, aiWindow: aiWindow)
        if participantType == .agent {
            // SPEC §13.4: every agent message carries the agent signature.
            let message = RumorContent.agentSignatureMessage(
                ciphertext: outgoing.rumor.ciphertext ?? Data())
            var rumor = outgoing.rumor
            rumor.agentSig = try agentKey.signature(for: message)
            outgoing = OutgoingMessage(rumor: rumor, fuzzedTimestamp: outgoing.fuzzedTimestamp)
        }
        try await deliver(outgoing, to: contact)
    }

    /// Group fan-out (APP-SPEC §7, D1): the same body, encrypted once per
    /// member session. Every pairwise link keeps full FS/PCS/PQ properties.
    public func sendToGroup(
        _ body: MessageBody, memberIdentityHexes: [String],
        participantType: ParticipantType = .human
    ) async throws {
        for member in memberIdentityHexes where member != identityHex {
            try await send(body, to: member, participantType: participantType)
        }
    }

    /// SPEC §10 routing: co-present peers get the seal directly over the local
    /// link (no relay, no internet, nothing for any relay to observe — also
    /// the privacy-maximizing order per SPEC §0); everyone else gets the full
    /// gift wrap via relays. Fallback is automatic and silent: ANY local-link
    /// failure (peer out of range, link down, send raced a disconnect) falls
    /// through to relay delivery, so a message is never lost to co-presence
    /// guesswork. The local attempt re-seals nothing on failure — the relay
    /// path builds its own envelope from the same `OutgoingMessage`, keeping
    /// the one-fuzzed-timestamp-per-message invariant (APP-SPEC §2) intact.
    private func deliver(_ outgoing: OutgoingMessage, to contact: VerifiedContact) async throws {
        if let localLink {
            do {
                let seal = try GiftWrap.seal(
                    rumor: outgoing.rumor,
                    sender: nostrKeypair,
                    recipientNostrPubkey: contact.nostrPubkeyHex,
                    fuzzedTimestamp: outgoing.fuzzedTimestamp,
                    randomSource: randomSource,
                    nonceSource: nonceSource)
                try await localLink.send(seal, to: contact.binding.identityPubkey)
                return
            } catch {
                // Not co-present (or the radio failed mid-send): relay path.
            }
        }
        try await wrapAndPublish(outgoing, to: contact)
    }

    private func wrapAndPublish(_ outgoing: OutgoingMessage, to contact: VerifiedContact) async throws {
        let wrap = try GiftWrap.wrap(
            rumor: outgoing.rumor,
            sender: nostrKeypair,
            recipientNostrPubkey: contact.nostrPubkeyHex,
            fuzzedTimestamp: outgoing.fuzzedTimestamp,
            randomSource: randomSource,
            nonceSource: nonceSource)
        try await publishWithRetry(wrap)
    }

    /// Outbox semantics: keep trying every transport with backoff until one
    /// healthy relay accepts (APP-SPEC §13). Chaos drops surface as thrown
    /// errors and are retried.
    private func publishWithRetry(_ event: NostrEvent, maxAttempts: Int = 60) async throws {
        var attempt = 0
        while attempt < maxAttempts {
            for transport in transports {
                if let ack = try? await transport.publish(event), ack.accepted {
                    return
                }
            }
            attempt += 1
            try? await Task.sleep(for: .milliseconds(outboundRetryBaseMillis * min(attempt, 8)))
        }
        throw NostrError.publishDropped
    }

    // MARK: - Receive

    /// Starts the receive pump: AUTH to each relay, subscribe to my envelopes,
    /// process forever. Returns the engine's event stream.
    public func start() async throws -> AsyncStream<MessengerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MessengerEvent.self)
        eventContinuation = continuation
        for transport in transports {
            // A down/unreachable relay must not block startup or onboarding:
            // skip it on auth failure (sends still redial via publishWithRetry,
            // and nothing here throws). Other transports keep running.
            do {
                try await transport.authenticate(keypair: nostrKeypair, randomSource: randomSource)
            } catch {
                continue
            }
            let filters = [
                NostrFilter(kinds: [PQRCConstants.giftWrapEventKind], pTags: [nostrKeypair.publicKeyHex])
            ]
            let events = await transport.subscribe(filters)
            let task = Task { [weak self] in
                do {
                    for try await event in events {
                        await self?.handleIncoming(event)
                    }
                } catch {
                    // Stream ended (relay gone); other transports keep running.
                }
            }
            pumpTasks.append(task)
        }
        if let localLink {
            // Local link pump: seals arrive without a wrap (SPEC §10) but join
            // the exact same pipeline right after the unwrap step, so dedupe,
            // blocklist, agent-integrity and retry behavior are identical on
            // both paths.
            let seals = await localLink.incoming()
            let task = Task { [weak self] in
                for await seal in seals {
                    await self?.handleIncomingSeal(seal)
                }
            }
            pumpTasks.append(task)
        }
        return stream
    }

    public func stop() {
        for task in pumpTasks { task.cancel() }
        pumpTasks.removeAll()
        eventContinuation?.finish()
    }

    private func handleIncoming(_ event: NostrEvent) async {
        // Dedupe by event id: duplicate envelopes processed once; replays of
        // already-consumed envelopes rejected here.
        guard !processedWrapIDs.contains(event.id) else { return }
        guard let unwrapped = try? GiftWrap.unwrap(event, recipient: nostrKeypair) else {
            return  // not for us / malformed: ignore silently (opaque to relays anyway)
        }
        processedWrapIDs.insert(event.id)
        await processUnwrapped(unwrapped)
    }

    /// Local-link receive entry point. `GiftWrap.unseal` performs the same
    /// verification chain as `unwrap` minus the wrap layer, and keys dedupe by
    /// a `local:`-prefixed seal id, so a replayed seal — whether re-sent on
    /// the radio or relayed later by an attacker — is processed at most once
    /// (with the ratchet's one-time message keys as the backstop beneath).
    private func handleIncomingSeal(_ seal: NostrEvent) async {
        guard let unwrapped = try? GiftWrap.unseal(seal, recipient: nostrKeypair) else {
            return  // not for us / tampered: drop silently, same as relay path
        }
        guard !processedWrapIDs.contains(unwrapped.wrapEventID) else { return }
        processedWrapIDs.insert(unwrapped.wrapEventID)
        await processUnwrapped(unwrapped)
    }

    private func processUnwrapped(_ unwrapped: GiftWrap.Unwrapped) async {
        // L-4: future-version traffic is rejected legibly here instead of
        // cycling the retry queue until "overflow" (AEAD would reject it
        // anyway — the receiver bakes "1" into the AD).
        guard unwrapped.rumor.version == PQRCConstants.version else {
            eventContinuation?.yield(
                .quarantined(
                    wrapEventID: unwrapped.wrapEventID,
                    reason: "unsupported pqrc_version \(unwrapped.rumor.version)"))
            return
        }
        guard let contact = contactsByNostrPub[unwrapped.senderNostrPubkey] else {
            // Unknown sender: message-request gate (D12). The envelope is held
            // (bounded) so accepting the request can replay it — nothing
            // renders as a conversation until the user accepts.
            holdForRequest(unwrapped)
            eventContinuation?.yield(
                .messageRequest(
                    senderNostrPubkeyHex: unwrapped.senderNostrPubkey,
                    wrapEventID: unwrapped.wrapEventID))
            return
        }
        // Blocklist: dropped post-unseal, no UI trace, no notification (D8).
        if blockedIdentityHexes.contains(contact.identityHex) {
            return
        }
        if unwrapped.rumor.type == .handshake {
            await processHandshake(unwrapped, from: contact)
            return
        }
        await decryptAndEmit(unwrapped, from: contact, isRetry: false)
    }

    private func processHandshake(_ unwrapped: GiftWrap.Unwrapped, from contact: VerifiedContact) async {
        guard let handshake = unwrapped.rumor.handshake,
            handshake.ik == contact.binding.identityPubkey
        else {
            eventContinuation?.yield(
                .protocolViolation(
                    senderIdentityHex: contact.identityHex,
                    reason: "handshake identity mismatch",
                    wrapEventID: unwrapped.wrapEventID))
            return
        }
        do {
            let consumed = try await prekeyManager.consume(
                spkUsed: handshake.spkUsed, otpUsed: handshake.otpUsed,
                otpPQUsed: handshake.otpPQUsed, lrpUsed: handshake.lrpUsed)
            let response = try PQXDH.respond(
                myIdentityPub: identity.publicKeyData, consumed: consumed, message: handshake)
            let session = PQRCSession(
                response: response, myKEMPrivate: consumed.otpPQ ?? consumed.pqpk,
                peerIdentityPubkey: contact.binding.identityPubkey,
                clock: clock, randomSource: randomSource)
            sessions[contact.identityHex] = session
            // Message #0 piggybacks on the handshake (D10).
            await decryptAndEmit(unwrapped, from: contact, isRetry: false)
        } catch {
            eventContinuation?.yield(
                .quarantined(wrapEventID: unwrapped.wrapEventID, reason: "handshake failed"))
        }
    }

    private func decryptAndEmit(
        _ unwrapped: GiftWrap.Unwrapped, from contact: VerifiedContact, isRetry: Bool
    ) async {
        guard let session = sessions[contact.identityHex] else {
            // Message raced ahead of its handshake: hold until the session exists.
            holdForRetry(unwrapped)
            return
        }
        do {
            let body = try await session.decrypt(
                rumor: unwrapped.rumor, fuzzedTimestamp: unwrapped.fuzzedTimestamp)
            guard verifyParticipantAuthenticity(unwrapped.rumor, contact: contact) else {
                eventContinuation?.yield(
                    .protocolViolation(
                        senderIdentityHex: contact.identityHex,
                        reason: "participant_type does not match signature evidence",
                        wrapEventID: unwrapped.wrapEventID))
                return
            }
            // SPEC §13.3 enforced at the protocol layer (review M-1): an
            // ai_window is dropped — and flagged — unless it is signed by the
            // sender's binding-verified HUMAN identity key. The AgentEngine
            // re-checks above (defense in depth), but no consumer of
            // `ReceivedMessage.aiWindow` can ever see a forgeable announcement.
            var aiWindow = unwrapped.rumor.aiWindow
            if let window = aiWindow,
                window.enabledBy != contact.binding.identityPubkey || !window.hasValidSignature()
            {
                aiWindow = nil
                eventContinuation?.yield(
                    .protocolViolation(
                        senderIdentityHex: contact.identityHex,
                        reason: "ai_window not signed by the sender's human identity key",
                        wrapEventID: unwrapped.wrapEventID))
            }
            eventContinuation?.yield(
                .message(
                    ReceivedMessage(
                        senderIdentityHex: contact.identityHex,
                        participantType: unwrapped.rumor.participantType,
                        body: body,
                        contentPointer: unwrapped.rumor.contentPointer,
                        aiWindow: aiWindow,
                        wrapEventID: unwrapped.wrapEventID)))
            if !isRetry { await retryPending() }
        } catch let error as PQRCError {
            switch error {
            case .skippedTooFar:
                eventContinuation?.yield(
                    .quarantined(
                        wrapEventID: unwrapped.wrapEventID,
                        reason: "message arrived too far out of order"))
            case .duplicateMessage:
                break  // replayed ratchet position: drop silently
            default:
                // Likely out-of-order across a pending rekey or a not-yet-
                // established session: hold and retry after later progress.
                holdForRetry(unwrapped)
            }
        } catch {
            holdForRetry(unwrapped)
        }
    }

    /// SPEC §8.2/§13.4 gate: agent label requires a valid agent signature from
    /// the bound agent key; a human label must not carry agent evidence.
    /// Public + pure so the agent suite and the app can apply the same gate.
    public static func validateParticipantAuthenticity(
        _ rumor: RumorContent, agentPubkey: Data
    ) -> Bool {
        let message = RumorContent.agentSignatureMessage(ciphertext: rumor.ciphertext ?? Data())
        switch rumor.participantType {
        case .agent:
            guard rumor.senderRole == .agent, let sig = rumor.agentSig else { return false }
            return PQRCIdentity.verify(signature: sig, message: message, publicKey: agentPubkey)
        case .human:
            // An agent signature under a human label is the §13.4 forgery case.
            if rumor.agentSig != nil { return false }
            return rumor.senderRole == .identity
        }
    }

    private func verifyParticipantAuthenticity(
        _ rumor: RumorContent, contact: VerifiedContact
    ) -> Bool {
        Self.validateParticipantAuthenticity(rumor, agentPubkey: contact.binding.agentPubkey)
    }

    private func holdForRequest(_ unwrapped: GiftWrap.Unwrapped) {
        let sender = unwrapped.senderNostrPubkey
        if pendingRequests[sender] == nil {
            if pendingRequestOrder.count >= 32, let evicted = pendingRequestOrder.first {
                pendingRequestOrder.removeFirst()
                pendingRequests.removeValue(forKey: evicted)
            }
            pendingRequestOrder.append(sender)
            pendingRequests[sender] = []
        }
        pendingRequests[sender]?.append(unwrapped)
        if let count = pendingRequests[sender]?.count, count > 16 {
            pendingRequests[sender]?.removeFirst()
        }
    }

    private func holdForRetry(_ unwrapped: GiftWrap.Unwrapped) {
        // No per-envelope attempt cap: an envelope legitimately waiting on one
        // delayed predecessor is retried on every unrelated success, so any
        // small cap quarantines healthy traffic under heavy chaos. The queue
        // bound below is the backstop for genuinely poisoned envelopes.
        pendingRetry.append(unwrapped)
        if pendingRetry.count > 256 {
            let evicted = pendingRetry.removeFirst()
            eventContinuation?.yield(
                .quarantined(wrapEventID: evicted.wrapEventID, reason: "retry queue overflow"))
        }
    }

    /// Re-presents held envelopes after each successful decrypt; loops until a
    /// pass makes no progress.
    private func retryPending() async {
        var progressed = true
        while progressed && !pendingRetry.isEmpty {
            let batch = pendingRetry
            pendingRetry.removeAll()
            for unwrapped in batch {
                guard let contact = contactsByNostrPub[unwrapped.senderNostrPubkey] else {
                    holdForRetry(unwrapped)
                    continue
                }
                if unwrapped.rumor.type == .handshake, !sessions.keys.contains(contact.identityHex) {
                    await processHandshake(unwrapped, from: contact)
                } else {
                    await decryptAndEmit(unwrapped, from: contact, isRetry: true)
                }
            }
            // decryptAndEmit re-holds failures; progress = anything cleared.
            progressed = pendingRetry.count < batch.count
        }
    }

    // MARK: - Introspection (tests, persistence)

    public func sessionSnapshot(peerIdentityHex: String) async -> RatchetSnapshot? {
        await sessions[peerIdentityHex]?.snapshot()
    }

    public func hasSession(peerIdentityHex: String) -> Bool {
        sessions[peerIdentityHex] != nil
    }

    public func pendingRetryCount() -> Int { pendingRetry.count }

    public var agentPublicKeyData: Data { agentKey.publicKey.rawRepresentation }

    /// Signs as the agent (used by the AgentEngine layer).
    public func agentSign(_ message: Data) throws -> Data {
        try agentKey.signature(for: message)
    }
}
