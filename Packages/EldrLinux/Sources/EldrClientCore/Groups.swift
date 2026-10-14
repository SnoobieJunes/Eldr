// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr

// Group chats (APP-SPEC §7 D1; WS-N1, DEVIATIONS AC173). These match the iOS
// PersonaRuntime wire behaviour: `group_create` carries the roster (revision-ordered,
// asserted by whoever sent it), and every group message carries `group: {id}`. Fan-out
// is pairwise, so each member link keeps full FS/PCS/PQ. Linux is stricter than iOS
// on receive: a `group:` message is filed under the group only if the sender is on our
// copy of the roster. Otherwise it is filed as a 1:1 message, so a non-member can't
// make its message look like a group post.

extension EldrClient {
    public var groups: [GroupRecord] { state.groups ?? [] }

    public func group(matching q: String) throws -> GroupRecord {
        let ql = q.lowercased()
        if let g = groups.first(where: { $0.groupID.lowercased() == ql }) { return g }
        let hits = groups.filter {
            $0.name.lowercased() == ql || $0.groupID.lowercased().hasPrefix(ql)
        }
        guard !hits.isEmpty else { throw EldrClientError.unknownGroup(q) }
        guard hits.count == 1 else { throw EldrClientError.ambiguousContact(q) }
        return hits[0]
    }

    public func groupHistory(_ groupID: String) -> [HistoryEntry] {
        history.filter { $0.groupID == groupID && $0.threadID == nil }
    }

    /// Creates a group with me plus the given contacts and announces it to each of them.
    /// Returns the group and how many members the announcement actually reached.
    @discardableResult
    public func createGroup(name: String, members qs: [String]) async throws -> (GroupRecord, Int) {
        let contacts = try qs.map { try contact(matching: $0) }
        var memberHexes = [identityHex]
        for h in contacts.map(\.identityHex) where !memberHexes.contains(h) { memberHexes.append(h) }
        let create = GroupCreate(groupID: UUID().uuidString, name: name, members: memberHexes, revision: 1)
        let rec = GroupRecord(GroupRoster(create: create, assertedBy: identityHex))
        upsert(rec)
        let reached = try await fanOut(
            text: "created the group \"\(name)\"", group: rec, groupCreate: create,
            to: contacts, record: true)
        return (rec, reached)
    }

    /// Adds/removes members (a new roster revision sent to the union of old and new).
    public func reviseGroup(_ q: String, add: [String] = [], remove: [String] = [], rename: String? = nil) async throws -> GroupRecord {
        let g = try group(matching: q)
        let addHex = try add.map { try contact(matching: $0).identityHex }
        let removeHex = Set(try remove.map { try contact(matching: $0).identityHex })
        var members = g.members.filter { !removeHex.contains($0) || $0 == identityHex }
        for h in addHex where !members.contains(h) { members.append(h) }
        let newName = rename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? g.name
        guard !newName.isEmpty, newName.count <= 100 else { throw EldrClientError.badSetting("group names are 1–100 characters") }
        let create = GroupCreate(groupID: g.groupID, name: newName, members: members, revision: g.revision + 1)
        var roster = g.roster
        _ = roster.apply(create, assertedBy: identityHex)
        let rec = GroupRecord(roster)
        upsert(rec)
        let union = Set(g.members + members).subtracting([identityHex])
        let targets = state.contacts.filter { union.contains($0.identityHex) }
        let note = rename != nil && newName != g.name ? "renamed the group to \"\(newName)\"" : "updated the group"
        _ = try await fanOut(text: note, group: rec, groupCreate: create, to: targets, record: true)
        return rec
    }

    /// Leaves a group: tells the other members (a roster revision without me), then
    /// forgets the roster locally. History is kept.
    public func leaveGroup(_ q: String) async throws {
        let g = try group(matching: q)
        let members = g.members.filter { $0 != identityHex }
        let create = GroupCreate(groupID: g.groupID, name: g.name, members: members, revision: g.revision + 1)
        let targets = state.contacts.filter { members.contains($0.identityHex) }
        _ = try? await fanOut(text: "left the group", group: g, groupCreate: create, to: targets, record: true)
        state.groups = groups.filter { $0.groupID != g.groupID }
        if myWindowConversation == UIConversation.group(g.groupID) { try? await endAIWindow() }
        try await persist()
    }

    /// Sends text to every group member who is also my verified contact. Returns how
    /// many members it reached. Members I have no contact for are skipped and counted.
    @discardableResult
    public func sendToGroup(_ text: String, group q: String) async throws -> (reached: Int, skipped: Int) {
        let g = try group(matching: q)
        // The shared send path: mentions, "Not sent" rows, then solo replies / @AI routing.
        let conv = UIConversation.group(g.groupID)
        let r = try await post(text, conversationID: conv)
        await afterMySend(text, conversationID: conv, threadID: nil)
        return r
    }

    private func fanOut(
        text: String, group g: GroupRecord, groupCreate: GroupCreate?, to targets: [ContactRecord],
        record: Bool
    ) async throws -> Int {
        var body = MessageBody(
            text: text, sentAt: Int64(Date().timeIntervalSince1970), messageID: UUID().uuidString,
            group: RumorContent.GroupRef(id: g.groupID), groupCreate: groupCreate)
        let participant: ParticipantType = isAgent ? .agent : .human
        if isAgent { body.agentSponsorship = try liveSponsorship() }
        var reached = 0
        var lastError: Error?
        for c in targets {
            do {
                _ = try await deliver(body, to: c, participant: participant)
                reached += 1
            } catch { lastError = error }
        }
        if record {
            var e = HistoryEntry(
                id: body.messageID ?? UUID().uuidString, peerIdentityHex: identityHex, outgoing: true,
                text: text, sentAt: body.sentAt, agent: isAgent, sponsorship: .human)
            if let s = body.agentSponsorship {
                e.sponsorship = .sponsored(
                    sponsorIdentityHex: s.enabledBy.hexString, label: s.label, activeUntil: s.activeUntil)
            }
            e.groupID = g.groupID
            appendHistory(e)
        }
        try await persist()
        if reached == 0, let lastError, !targets.isEmpty { throw lastError }
        return reached
    }

    func upsert(_ rec: GroupRecord) {
        var gs = state.groups ?? []
        if let i = gs.firstIndex(where: { $0.groupID == rec.groupID }) { gs[i] = rec } else { gs.append(rec) }
        state.groups = gs
    }

    /// Receive-side routing. Applies a carried roster, then returns the group id to
    /// file this message under (nil = 1:1).
    func routeGroup(_ m: ReceivedMessage) -> (groupID: String?, changed: GroupRecord?) {
        let sender = m.senderIdentityHex
        if let create = m.body.groupCreate {
            // Only a member of the asserted roster may assert it, and it must include me.
            guard create.members.contains(sender), create.members.contains(identityHex) else {
                // A roster that drops me is still applied if I already have the group,
                // so a removal is visible; otherwise it's ignored.
                if let g = groups.first(where: { $0.groupID == create.groupID }),
                    g.members.contains(sender)
                {
                    var r = g.roster
                    if r.apply(create, assertedBy: sender) {
                        let rec = GroupRecord(r)
                        upsert(rec)
                        return (create.members.contains(identityHex) ? create.groupID : nil, rec)
                    }
                }
                return (nil, nil)
            }
            if let g = groups.first(where: { $0.groupID == create.groupID }) {
                guard g.members.contains(sender) else { return (nil, nil) }
                var r = g.roster
                let changed = r.apply(create, assertedBy: sender)
                let rec = GroupRecord(r)
                if changed { upsert(rec) }
                return (create.groupID, changed ? rec : nil)
            }
            let rec = GroupRecord(GroupRoster(create: create, assertedBy: sender))
            upsert(rec)
            return (create.groupID, rec)
        }
        if let ref = m.body.group, let g = groups.first(where: { $0.groupID == ref.id }),
            g.members.contains(sender), g.members.contains(identityHex)
        {
            return (g.groupID, nil)
        }
        return (nil, nil)
    }
}
