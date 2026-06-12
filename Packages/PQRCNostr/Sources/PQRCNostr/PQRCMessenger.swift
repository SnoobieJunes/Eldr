import Crypto
import Foundation
import PQRCCore

/// A contact whose kind-10420 binding has been verified in both directions.
/// Only verified contacts can hold sessions (CLAUDE.md invariant 7).
public struct VerifiedContact: Sendable, Equatable {
    public let binding: VerifiedBinding
    public var nostrPubkeyHex: String { binding.nostrPubkey.hexString }
    public var identityHex: String { binding.identityPubkey.hexString }

    public init(binding: VerifiedBinding) {
        self.binding = binding
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
    /// Blocklist check applied post-unseal (D8): the relay cannot filter by
    /// sender (the sender is hidden by design), so we drop on-device.
    private var blockedIdentityHexes: Set<String> = []

    // State
    private var contactsByNostrPub: [String: VerifiedContact] = [:]
    private var sessions: [String: PQRCSession] = [:]  // peer identity hex -> session
    private var processedWrapIDs: Set<String> = []
    private var pendingRetry: [GiftWrap.Unwrapped] = []
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
    public func announce(relayURLs: [String]) async throws {
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
            try await publishWithRetry(event)
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
            let verified = try PQRCEvents.verifyBindingEvent(bindingEvent)
            let bundle = try PQRCEvents.verifyPrekeyBundleEvent(
                bundleEvent, verifiedBinding: verified)
            let contact = VerifiedContact(binding: verified)
            contactsByNostrPub[contact.nostrPubkeyHex] = contact
            return (contact, bundle)
        }
        throw NostrError.invalidEvent
    }

    public func addContact(_ contact: VerifiedContact) {
        contactsByNostrPub[contact.nostrPubkeyHex] = contact
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
        try await wrapAndPublish(outgoing, to: contact)
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
        try await wrapAndPublish(outgoing, to: contact)
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
            try await transport.authenticate(keypair: nostrKeypair, randomSource: randomSource)
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

    private func processUnwrapped(_ unwrapped: GiftWrap.Unwrapped) async {
        guard let contact = contactsByNostrPub[unwrapped.senderNostrPubkey] else {
            // Unknown sender: message-request gate (D12). Nothing renders as a
            // conversation until the user accepts.
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
            eventContinuation?.yield(
                .message(
                    ReceivedMessage(
                        senderIdentityHex: contact.identityHex,
                        participantType: unwrapped.rumor.participantType,
                        body: body,
                        contentPointer: unwrapped.rumor.contentPointer,
                        aiWindow: unwrapped.rumor.aiWindow,
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
