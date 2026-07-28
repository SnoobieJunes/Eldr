// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// Read models for a Buzz workspace — the relay-signed group state, the
/// timeline, and the profile record.
///
/// Every parser here is TOLERANT: an event that does not fit returns nil rather
/// than throwing, and unknown tags/fields are ignored, never fatal (SPEC §12
/// forward compatibility). Buzz ships kinds we do not model yet — canvases,
/// workflows, forum posts, huddles — and a workspace client must not fall over
/// when one arrives.
///
/// **Everything in here is untrusted input.** These types describe what a relay
/// we do not control said; nothing is authoritative for an Eldr trust decision,
/// and any of it that can reach an agent must first go through
/// `UntrustedDataEnvelope`.

// MARK: - Channel (kind:39000, relay-signed)

public struct BuzzChannel: Sendable, Equatable, Identifiable {
    /// The channel UUID (the `d` tag, and the `h` tag every message carries).
    public let id: String
    public let name: String
    public let about: String?
    /// NIP-29 `closed`. Buzz emits it on *every* channel by convention — it
    /// describes the membership model, not runtime access — so it is a poor
    /// signal for "can I post here". Treat it as advisory.
    public let isClosed: Bool
    public let isPrivate: Bool
    /// Buzz marks its DM channels `hidden` so clients keep them out of the
    /// channel rail. These are Buzz's *server-side* DMs — visible to the relay
    /// operator, and not to be confused with an Eldr encrypted conversation.
    public let isHidden: Bool

    public init(
        id: String, name: String, about: String? = nil, isClosed: Bool = false,
        isPrivate: Bool = false, isHidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.about = about
        self.isClosed = isClosed
        self.isPrivate = isPrivate
        self.isHidden = isHidden
    }

    public static func from(metadataEvent event: NostrEvent) -> BuzzChannel? {
        guard event.kind == BuzzEvents.Kind.groupMetadata,
            let id = event.firstTagValue("d"), !id.isEmpty
        else { return nil }
        let flags = Set(event.tags.compactMap { $0.first })
        return BuzzChannel(
            id: id,
            name: event.firstTagValue("name") ?? id,
            about: event.firstTagValue("about"),
            isClosed: flags.contains("closed"),
            isPrivate: flags.contains("private"),
            isHidden: flags.contains("hidden"))
    }
}

// MARK: - Roster (kinds 39001 / 39002, relay-signed)

/// A channel's membership as the relay reports it. Admins come from 39001
/// (`p` tags carrying a role label), members from 39002.
public struct BuzzRoster: Sendable, Equatable {
    public let channelID: String
    /// pubkey hex → role (`owner` / `admin`).
    public let admins: [String: String]
    public let members: [String]

    public init(channelID: String, admins: [String: String] = [:], members: [String] = []) {
        self.channelID = channelID
        self.admins = admins
        self.members = members
    }

    public static func admins(from event: NostrEvent) -> BuzzRoster? {
        guard event.kind == BuzzEvents.Kind.groupAdmins, let id = event.firstTagValue("d")
        else { return nil }
        var admins: [String: String] = [:]
        for tag in event.tags where tag.count >= 2 && tag[0] == "p" {
            admins[tag[1].lowercased()] = tag.count >= 3 ? tag[2] : "admin"
        }
        return BuzzRoster(channelID: id, admins: admins)
    }

    public static func members(from event: NostrEvent) -> BuzzRoster? {
        guard event.kind == BuzzEvents.Kind.groupMembers, let id = event.firstTagValue("d")
        else { return nil }
        let members = event.tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1].lowercased() }
        return BuzzRoster(channelID: id, members: members)
    }

    /// Fold a newer partial roster into this one, keeping whichever half the
    /// incoming event did not carry.
    public func merging(_ other: BuzzRoster) -> BuzzRoster {
        BuzzRoster(
            channelID: channelID,
            admins: other.admins.isEmpty ? admins : other.admins,
            members: other.members.isEmpty ? members : other.members)
    }
}

// MARK: - Message (kinds 9 / 40002 / 40003 / 40099)

public struct BuzzMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let channelID: String
    public let authorPubkey: String
    public let createdAt: Int64
    /// Plain text. kind:40002 (Buzz's "rich content") carries the same plain
    /// `content` as kind:9 — verified against Buzz's own renderer — so there is
    /// no separate decode path.
    public let content: String
    /// `p` (notify) and `mention` (reference-only) tags, both rendered as
    /// mentions by Buzz's clients.
    public let mentions: [String]
    public let replyToEventID: String?
    public let threadRootEventID: String?
    /// True for kind:40099, the relay's own join/leave/rename narration.
    public let isSystem: Bool
    /// The originating kind, kept so a client can badge Buzz-only variants.
    public let kind: Int

    public init(
        id: String, channelID: String, authorPubkey: String, createdAt: Int64, content: String,
        mentions: [String] = [], replyToEventID: String? = nil, threadRootEventID: String? = nil,
        isSystem: Bool = false, kind: Int = BuzzEvents.Kind.streamMessage
    ) {
        self.id = id
        self.channelID = channelID
        self.authorPubkey = authorPubkey
        self.createdAt = createdAt
        self.content = content
        self.mentions = mentions
        self.replyToEventID = replyToEventID
        self.threadRootEventID = threadRootEventID
        self.isSystem = isSystem
        self.kind = kind
    }

    public static func from(_ event: NostrEvent) -> BuzzMessage? {
        let renderable = [
            BuzzEvents.Kind.streamMessage, BuzzEvents.Kind.streamMessageV2,
            BuzzEvents.Kind.systemMessage,
        ]
        guard renderable.contains(event.kind), let channelID = event.firstTagValue("h")
        else { return nil }
        let thread = ThreadReference(tags: event.tags)
        return BuzzMessage(
            id: event.id, channelID: channelID, authorPubkey: event.pubkey,
            createdAt: event.createdAt, content: event.content,
            mentions: event.tags
                .filter { $0.count >= 2 && ($0[0] == "p" || $0[0] == "mention") }
                .map { $0[1].lowercased() },
            replyToEventID: thread.replyTo, threadRootEventID: thread.root,
            isSystem: event.kind == BuzzEvents.Kind.systemMessage, kind: event.kind)
    }
}

/// NIP-10 `e`-tag reference resolution: prefer explicit `root`/`reply` markers,
/// fall back to the deprecated positional form (first `e` is root, last is reply).
struct ThreadReference {
    let root: String?
    let replyTo: String?

    init(tags: [[String]]) {
        let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
        let marked = { (marker: String) -> String? in
            eTags.first { $0.count >= 4 && $0[3] == marker }?[1]
        }
        if let reply = marked("reply") {
            replyTo = reply
            root = marked("root") ?? reply
        } else if let root = marked("root") {
            self.root = root
            replyTo = root
        } else if eTags.count >= 2 {
            root = eTags.first?[1]
            replyTo = eTags.last?[1]
        } else if let only = eTags.first?[1] {
            root = only
            replyTo = only
        } else {
            root = nil
            replyTo = nil
        }
    }
}

// MARK: - Membership notification (kinds 44100 / 44101, relay-signed)

public struct BuzzMembershipChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case added
        case removed
    }

    public let change: Kind
    public let pubkey: String
    public let channelID: String?

    public static func from(_ event: NostrEvent) -> BuzzMembershipChange? {
        let change: Kind
        switch event.kind {
        case BuzzEvents.Kind.memberAdded: change = .added
        case BuzzEvents.Kind.memberRemoved: change = .removed
        default: return nil
        }
        guard let pubkey = event.firstTagValue("p") else { return nil }
        return BuzzMembershipChange(
            change: change, pubkey: pubkey.lowercased(), channelID: event.firstTagValue("h"))
    }
}

// MARK: - Profile (kind:0)

/// A member's kind:0 profile, with the raw content preserved.
///
/// Preserving `rawContent` is not tidiness — it is load-bearing. kind:0 is an
/// **absolute-state** replaceable event on Buzz ("fields present are set; fields
/// absent are cleared"), and Buzz's relay validates only that the content is
/// valid JSON, storing it verbatim and ignoring fields it does not know. That is
/// what makes kind:0 a viable carrier for an Eldr prekey bundle (WS-BM4) — and it
/// is also why a naive republish would clobber whatever another client wrote.
/// `merging(into:)` is the safe way to change one field.
public struct BuzzProfile: Sendable, Equatable {
    public let pubkey: String
    public let displayName: String?
    public let name: String?
    public let about: String?
    public let picture: String?
    public let nip05: String?
    /// The exact JSON string the relay served.
    public let rawContent: String

    public var bestName: String {
        displayName ?? name ?? String(pubkey.prefix(8))
    }

    public static func from(_ event: NostrEvent) -> BuzzProfile? {
        guard event.kind == BuzzEvents.Kind.profile else { return nil }
        let object =
            (try? JSONSerialization.jsonObject(with: Data(event.content.utf8))) as? [String: Any]
            ?? [:]
        let string = { (key: String) -> String? in
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return BuzzProfile(
            pubkey: event.pubkey, displayName: string("display_name"), name: string("name"),
            about: string("about"), picture: string("picture") ?? string("image"),
            nip05: string("nip05"), rawContent: event.content)
    }

    /// Read a non-standard field — the accessor for anything Eldr parks in the
    /// profile that Buzz neither knows nor touches.
    public func field(_ key: String) -> String? {
        let object =
            (try? JSONSerialization.jsonObject(with: Data(rawContent.utf8))) as? [String: Any] ?? [:]
        return object[key] as? String
    }

    /// Produce new kind:0 content with `fields` set, preserving every other key
    /// already present. Passing a nil value removes that key.
    ///
    /// Use this — never a fresh object — when updating a profile that may carry
    /// state written by Buzz's own clients or by us.
    public func mergedContent(setting fields: [String: String?]) -> String {
        var object =
            (try? JSONSerialization.jsonObject(with: Data(rawContent.utf8))) as? [String: Any] ?? [:]
        for (key, value) in fields {
            if let value { object[key] = value } else { object.removeValue(forKey: key) }
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return rawContent }
        return String(decoding: data, as: UTF8.self)
    }
}
