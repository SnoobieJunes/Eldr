// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// A human member's client for a Buzz workspace (WS-BM1).
///
/// Buzz publishes a compatibility contract for exactly this — *"Buzz is a Nostr
/// relay that speaks NIP-29 natively. Third-party Nostr clients connect directly
/// to `buzz-relay` using NIP-29 and NIP-42 authentication"* (`buzz/NOSTR.md`) —
/// so nothing here asks Buzz to change, and nothing here is Buzz-specific
/// beyond kind numbers already in their published registry.
///
/// Sibling to `EldrBuzzGateway`, deliberately not merged with it: the gateway is
/// an *agent* holding its own key on a Mac/Linux daemon; this is a *person* on a
/// phone. They share `BuzzEvents`, `NIP44`, `NIPOA` and the transport.
///
/// ## Three things this type refuses to get wrong
///
/// 1. **Every REQ enumerates `kinds` explicitly.** Buzz rejects a subscription
///    that could match a p-gated kind (44100/44101/1059) unless every `#p` is
///    the authenticated pubkey — and omitting `kinds` trips that gate.
/// 2. **Content is never silently truncated.** Over-long text throws; splitting
///    a message across several kind:9s is a product decision, not a transport one
///    (Buzz has no PQRC chunk reassembly — `RelayFraming` means nothing there).
/// 3. **Nothing it returns is trusted.** Every value came from a relay we do not
///    control. Anything routed onward to an agent goes through
///    `UntrustedDataEnvelope` first — that is the whole premise of NIP-C1.
///
/// ## What it does NOT do
///
/// This is the plaintext workspace plane. Messages sent here are readable by the
/// workspace's relay operator, because Buzz channels are signed but not
/// end-to-end encrypted. Eldr's own PQ-ratcheted traffic is a separate plane
/// (kind:1059) that a Buzz relay will happily carry — see WS-BM4. Any UI built on
/// this type owes the user that distinction, in the same visible way the
/// `ai_window` banner is owed.
public actor BuzzWorkspaceClient {
    public struct Configuration: Sendable {
        /// `wss://…` — identifies the community (Buzz resolves the tenant from
        /// the Host header before AUTH), so it is half of every address.
        public var relayURL: String
        /// Max stored messages pulled per channel backfill.
        public var backfillLimit: Int
        /// How long to wait for a relay that never sends EOSE before returning
        /// whatever arrived. Only reached on a non-conforming relay.
        public var storedEventTimeout: Duration

        public init(
            relayURL: String, backfillLimit: Int = 200,
            storedEventTimeout: Duration = .seconds(10)
        ) {
            self.relayURL = relayURL
            self.backfillLimit = backfillLimit
            self.storedEventTimeout = storedEventTimeout
        }
    }

    private let transport: any RelayTransport
    private let keypair: NostrKeypair
    private let randomSource: any RandomSource
    private let configuration: Configuration
    private var authenticated = false

    public init(
        transport: any RelayTransport, keypair: NostrKeypair, randomSource: any RandomSource,
        configuration: Configuration
    ) {
        self.transport = transport
        self.keypair = keypair
        self.randomSource = randomSource
        self.configuration = configuration
    }

    /// Our Buzz-facing pubkey. Not necessarily the Eldr identity key — the
    /// recommended shape is a per-workspace key (see `BuzzInviteClient`).
    public nonisolated var pubkeyHex: String { keypair.publicKeyHex }

    public nonisolated var relayURL: String { configuration.relayURL }

    // MARK: - Session

    /// NIP-42 AUTH. Required before anything: Buzz gates reads on the
    /// authenticated pubkey, and membership is checked per connection.
    public func connect() async throws {
        try await transport.authenticate(keypair: keypair, randomSource: randomSource)
        authenticated = true
    }

    /// Publish our workspace profile (kind:0).
    ///
    /// `existing` MUST be passed when a profile is already published: kind:0 is
    /// absolute state on Buzz — *"fields present are set; fields absent are
    /// cleared"* — so building a fresh object silently drops anything another
    /// client (or a later Eldr feature) put there.
    @discardableResult
    public func publishProfile(
        displayName: String?, name: String? = nil, about: String? = nil, picture: String? = nil,
        existing: BuzzProfile? = nil, extraFields: [String: String?] = [:]
    ) async throws -> NostrEvent {
        let content: String
        if let existing {
            var fields: [String: String?] = extraFields
            fields["display_name"] = displayName
            if name != nil { fields["name"] = name }
            if about != nil { fields["about"] = about }
            if picture != nil { fields["picture"] = picture }
            content = existing.mergedContent(setting: fields)
        } else {
            let base = BuzzEvents.profile(
                pubkey: keypair.publicKeyHex, displayName: displayName, name: name, about: about,
                picture: picture)
            content = BuzzProfile(
                pubkey: keypair.publicKeyHex, displayName: nil, name: nil, about: nil,
                picture: nil, nip05: nil, rawContent: base.content
            ).mergedContent(setting: extraFields)
        }
        let event = NostrEvent(
            pubkey: keypair.publicKeyHex, createdAt: Int64(Date().timeIntervalSince1970),
            kind: BuzzEvents.Kind.profile, tags: [], content: content)
        return try await publish(event)
    }

    // MARK: - Discovery (relay-signed group state)

    /// Every channel this member can see. Buzz stores discovery events
    /// channel-scoped, so a *live* global subscription never receives them —
    /// they must be fetched with a historical REQ, which is what this is.
    public func channels() async throws -> [BuzzChannel] {
        let events = try await collectStored([
            NostrFilter(kinds: [BuzzEvents.Kind.groupMetadata])
        ])
        return
            newestPerAddressableKey(events)
            .compactMap(BuzzChannel.from(metadataEvent:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// One channel's admins + members.
    public func roster(channelID: String) async throws -> BuzzRoster {
        let events = try await collectStored([
            NostrFilter(
                kinds: [BuzzEvents.Kind.groupAdmins, BuzzEvents.Kind.groupMembers],
                dTags: [channelID])
        ])
        var roster = BuzzRoster(channelID: channelID)
        for event in newestPerAddressableKey(events) {
            if let admins = BuzzRoster.admins(from: event) { roster = roster.merging(admins) }
            if let members = BuzzRoster.members(from: event) { roster = roster.merging(members) }
        }
        return roster
    }

    /// kind:0 profiles for a set of members, for rendering names and avatars.
    public func profiles(of pubkeys: [String]) async throws -> [String: BuzzProfile] {
        guard !pubkeys.isEmpty else { return [:] }
        let events = try await collectStored([
            NostrFilter(kinds: [BuzzEvents.Kind.profile], authors: pubkeys.map { $0.lowercased() })
        ])
        var newest: [String: NostrEvent] = [:]
        for event in events where (newest[event.pubkey]?.createdAt ?? -1) < event.createdAt {
            newest[event.pubkey] = event
        }
        return newest.compactMapValues(BuzzProfile.from)
    }

    // MARK: - Timeline

    /// One screen of channel history, oldest-first.
    public func history(channelID: String, limit: Int? = nil) async throws -> [BuzzMessage] {
        let events = try await collectStored([
            NostrFilter(
                kinds: BuzzEvents.Kind.timelineKinds, hTags: [channelID],
                limit: limit ?? configuration.backfillLimit)
        ])
        return
            events
            .compactMap(BuzzMessage.from)
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Live channel traffic. Stored events replay first (NIP-01 semantics), so
    /// pass `since` to avoid re-reading history already loaded.
    public func timeline(channelID: String, since: Int64? = nil) async
        -> AsyncThrowingStream<BuzzWorkspaceEvent, Error>
    {
        let filters = [
            NostrFilter(kinds: BuzzEvents.Kind.timelineKinds, hTags: [channelID], since: since)
        ]
        return await mapped(await transport.subscribe(filters))
    }

    /// Relay-signed membership notifications for *us*.
    ///
    /// The `#p` filter is mandatory, not an optimisation: 44100/44101 are
    /// p-gated and Buzz rejects a subscription whose `#p` values are not all the
    /// authenticated pubkey — that is what stops one member watching another's
    /// membership changes.
    public func membershipChanges() async -> AsyncThrowingStream<BuzzWorkspaceEvent, Error> {
        let filters = [
            NostrFilter(
                kinds: [BuzzEvents.Kind.memberAdded, BuzzEvents.Kind.memberRemoved],
                pTags: [keypair.publicKeyHex])
        ]
        return await mapped(await transport.subscribe(filters))
    }

    // MARK: - Writes

    /// Post a message to a channel. Returns the signed event so a UI can echo it
    /// optimistically with the real id.
    @discardableResult
    public func send(
        _ text: String, to channelID: String, replyTo: String? = nil, threadRoot: String? = nil,
        mentions: [String] = []
    ) async throws -> NostrEvent {
        let event = BuzzEvents.streamMessage(
            pubkey: keypair.publicKeyHex, channelId: channelID, content: text, mentions: mentions,
            replyToEventId: replyTo, rootEventId: threadRoot)
        return try await publish(event)
    }

    @discardableResult
    public func react(
        to messageID: String, in channelID: String, emoji: String = "+",
        messageAuthor: String? = nil
    ) async throws -> NostrEvent {
        try await publish(
            BuzzEvents.reaction(
                pubkey: keypair.publicKeyHex, channelId: channelID, targetEventId: messageID,
                targetAuthorPubkey: messageAuthor, emoji: emoji))
    }

    /// Delete one of *our own* messages. Buzz validates author-match; deleting
    /// someone else's is an admin action (kind:9005) this client does not send.
    @discardableResult
    public func deleteMessage(_ messageID: String, in channelID: String, reason: String = "")
        async throws -> NostrEvent
    {
        try await publish(
            BuzzEvents.deleteMessage(
                pubkey: keypair.publicKeyHex, channelId: channelID, targetEventId: messageID,
                reason: reason))
    }

    /// Join an **open** channel. Private channels reject this at ingest — there
    /// an owner or admin must add you.
    @discardableResult
    public func join(channelID: String, reason: String = "") async throws -> NostrEvent {
        try await publish(
            BuzzEvents.joinRequest(
                pubkey: keypair.publicKeyHex, channelId: channelID, reason: reason))
    }

    @discardableResult
    public func leave(channelID: String) async throws -> NostrEvent {
        try await publish(
            BuzzEvents.leaveRequest(pubkey: keypair.publicKeyHex, channelId: channelID))
    }

    /// Ephemeral typing indicator. Best-effort by design: a rejection is not an
    /// error worth surfacing, so this one swallows failures.
    public func sendTypingIndicator(in channelID: String) async {
        let event = BuzzEvents.typingIndicator(
            pubkey: keypair.publicKeyHex, channelId: channelID)
        guard let signed = try? keypair.sign(event, randomSource: randomSource) else { return }
        _ = try? await transport.publish(signed)
    }

    // MARK: - Internals

    @discardableResult
    private func publish(_ unsigned: NostrEvent) async throws -> NostrEvent {
        if let limit = await transport.maxContentLength(),
            unsigned.content.utf8.count > limit
        {
            throw BuzzWorkspaceError.contentTooLong(
                bytes: unsigned.content.utf8.count, limit: limit)
        }
        let signed = try keypair.sign(unsigned, randomSource: randomSource)
        let ack = try await transport.publish(signed)
        guard ack.accepted else {
            throw BuzzWorkspaceError.rejected(reason: ack.message ?? "relay rejected the event")
        }
        return signed
    }

    /// Read a bounded question: everything the relay has stored, then stop.
    ///
    /// Terminates on the NIP-01 EOSE boundary. The timeout is the backstop for a
    /// transport that cannot report one — it yields whatever arrived rather than
    /// hanging, and never claims the result is complete.
    private func collectStored(_ filters: [NostrFilter]) async throws -> [NostrEvent] {
        let frames = await transport.subscribeFrames(filters)
        let collector = StoredEventCollector()
        let consume = Task {
            for try await frame in frames {
                switch frame {
                case .event(let event): await collector.append(event)
                case .endOfStoredEvents: return
                }
            }
        }
        let deadline = Task { [timeout = configuration.storedEventTimeout] in
            try await Task.sleep(for: timeout)
            consume.cancel()
        }
        _ = try? await consume.value
        deadline.cancel()
        return await collector.events
    }

    private func mapped(_ upstream: AsyncThrowingStream<NostrEvent, Error>) async
        -> AsyncThrowingStream<BuzzWorkspaceEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        continuation.yield(BuzzWorkspaceEvent(event))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Replaceable events (39000/39001/39002) can arrive more than once; keep the
    /// newest per `(kind, d)`.
    private func newestPerAddressableKey(_ events: [NostrEvent]) -> [NostrEvent] {
        var newest: [String: NostrEvent] = [:]
        for event in events {
            let key = "\(event.kind):\(event.firstTagValue("d") ?? event.pubkey)"
            if (newest[key]?.createdAt ?? -1) < event.createdAt { newest[key] = event }
        }
        return Array(newest.values)
    }
}

/// Accumulator for `collectStored`, so a timed-out collection still returns the
/// events that did arrive.
private actor StoredEventCollector {
    private(set) var events: [NostrEvent] = []
    func append(_ event: NostrEvent) { events.append(event) }
}

// MARK: - Stream events

/// One decoded thing off a workspace subscription. Unknown kinds are surfaced
/// rather than dropped — Buzz ships kinds we do not model (canvases, workflows,
/// huddles) and a client that treats an unknown kind as an error is a client
/// that breaks on their next release.
public enum BuzzWorkspaceEvent: Sendable, Equatable {
    case message(BuzzMessage)
    case reaction(messageID: String, emoji: String, byPubkey: String)
    case deletion(messageID: String, byPubkey: String)
    case channelUpdated(BuzzChannel)
    case rosterUpdated(BuzzRoster)
    case membership(BuzzMembershipChange)
    case unhandled(kind: Int, eventID: String)

    init(_ event: NostrEvent) {
        if let message = BuzzMessage.from(event) {
            self = .message(message)
        } else if event.kind == BuzzEvents.Kind.reaction, let target = event.firstTagValue("e") {
            self = .reaction(messageID: target, emoji: event.content, byPubkey: event.pubkey)
        } else if event.kind == BuzzEvents.Kind.deletion, let target = event.firstTagValue("e") {
            self = .deletion(messageID: target, byPubkey: event.pubkey)
        } else if let channel = BuzzChannel.from(metadataEvent: event) {
            self = .channelUpdated(channel)
        } else if let admins = BuzzRoster.admins(from: event) {
            self = .rosterUpdated(admins)
        } else if let members = BuzzRoster.members(from: event) {
            self = .rosterUpdated(members)
        } else if let change = BuzzMembershipChange.from(event) {
            self = .membership(change)
        } else {
            self = .unhandled(kind: event.kind, eventID: event.id)
        }
    }
}

public enum BuzzWorkspaceError: Error, Equatable, Sendable {
    /// The relay refused the event. `reason` is its verbatim message — useful
    /// ones include `invalid: channel-scoped events must include an h tag` and
    /// `restricted: unknown event kind`.
    case rejected(reason: String)
    /// Over the relay's NIP-11 content limit. Never truncate: splitting a
    /// message is the caller's decision to make visibly.
    case contentTooLong(bytes: Int, limit: Int)
}
