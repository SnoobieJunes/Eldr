// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr

/// Milestone 2: sponsored agent identities (DEVIATIONS AC162).
///
/// - A persona in **agent mode** is an AI account. Every send is labeled `agent`
///   (agent-key signed by the engine) and carries the owner's sponsorship; with no
///   live sponsorship the send is refused before anything leaves the box.
/// - The agent accepts a sponsorship ONLY from its pinned owner identity.
/// - A human persona can sponsor a contact for 1–7 days and revoke it; revocation
///   is effective on receipt, both at the agent and in the sponsor's own view.
/// - Every received agent message is checked on its own: signature, agent ==
///   sender, ≤7 days, unexpired, unrevoked.
extension EldrClient {
    public static let sponsorshipDayChoices = [1, 7]
    /// Total bytes held for incomplete chunked messages (AC214).
    public static let maxBufferedChunkBytes = 48 * 1024 * 1024

    var agentState: AgentState {
        get { state.agent ?? AgentState() }
        set { state.agent = newValue }
    }

    public var isAgent: Bool { agentState.agentMode == true }
    public var ownerIdentityHex: String? { agentState.ownerIdentityHex }
    public var mySponsorship: AgentSponsorship? { agentState.mySponsorship }
    public var issuedSponsorships: [IssuedSponsorship] { agentState.issued ?? [] }
    public var history: [HistoryEntry] { agentState.history ?? [] }
    /// The seq the next history entry will get.
    var nextHistorySeq: Int { agentState.nextSeq ?? 1 }
    public func history(with peerIdentityHex: String) -> [HistoryEntry] {
        history.filter { $0.peerIdentityHex == peerIdentityHex && $0.groupID == nil && $0.threadID == nil }
    }

    public static var nowSeconds: Int64 { Int64(Date().timeIntervalSince1970) }

    /// Turns agent mode on/off and pins the owner (64-hex identity). Turning it on
    /// without an owner is refused: an AI account must name who answers for it.
    public func setAgentMode(_ on: Bool, ownerIdentityHex owner: String?) async throws {
        var a = agentState
        if on {
            guard let o = owner?.lowercased(), o.count == 64, Data(hexString: o)?.count == 32,
                o != identityHex
            else { throw EldrClientError.notSponsored("agent mode needs the owner's 64-hex identity") }
            if a.ownerIdentityHex != o { a.mySponsorship = nil }
            a.ownerIdentityHex = o
        }
        a.agentMode = on
        agentState = a
        try await persist()
    }

    /// The sponsorship this agent may present right now, or why not.
    public func liveSponsorship(now: Int64 = EldrClient.nowSeconds) throws -> AgentSponsorship {
        guard let s = agentState.mySponsorship else { throw EldrClientError.notSponsored("none received") }
        guard s.enabledBy.hexString == agentState.ownerIdentityHex else {
            throw EldrClientError.notSponsored("sponsor is not the pinned owner")
        }
        guard s.agent == identityHex else { throw EldrClientError.notSponsored("names another agent") }
        do { try s.verify(presentedBy: identityHex, now: now) } catch {
            throw EldrClientError.notSponsored("\(error)")
        }
        guard !isRevoked(s) else { throw EldrClientError.notSponsored("revoked") }
        return s
    }

    func isRevoked(_ s: AgentSponsorship) -> Bool {
        // My own revocations come from `issued` too, so revocation traffic from others
        // can never evict them (AC212).
        if (agentState.issued ?? []).contains(where: {
            $0.revokedAt != nil && $0.sponsorship.sponsorshipID == s.sponsorshipID
                && $0.sponsorship.enabledBy == s.enabledBy
        }) { return true }
        return (agentState.revoked ?? []).contains("\(s.enabledBy.hexString):\(s.sponsorshipID)")
    }

    // MARK: Sponsor side (human)

    /// Signs and sends a sponsorship for contact `q` (must be a human persona).
    @discardableResult
    public func sponsor(_ q: String, days: Int, label: String? = nil) async throws -> AgentSponsorship {
        guard !isAgent else { throw EldrClientError.agentCannotSponsor }
        guard (1...7).contains(days) else {
            throw EldrClientError.notSponsored("duration must be 1–7 days")
        }
        let c = try contact(matching: q)
        let now = Self.nowSeconds
        // Only an explicit label goes on the wire: the contact's local name is mine and
        // must not ride along to the agent and every third party it talks to (SPEC §0).
        let label = label.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let sp = try AgentSponsorship.make(
            sponsorshipID: UUID().uuidString.lowercased(), agent: c.identityHex, label: label,
            issuedAt: now, activeUntil: now + Int64(days) * 86_400, identity: identity)
        var body = MessageBody(
            text: "🛡 I sponsor this AI account\(label.map { " (\($0))" } ?? "") for \(days) day\(days == 1 ? "" : "s"). "
                + "I can revoke it at any time.",
            sentAt: now, messageID: UUID().uuidString)
        body.agentSponsorship = sp
        _ = try await deliver(body, to: c, participant: .human)
        var a = agentState
        a.issued = (a.issued ?? []) + [IssuedSponsorship(sponsorship: sp, revokedAt: nil)]
        agentState = a
        appendHistory(HistoryEntry(
            id: body.messageID!, peerIdentityHex: c.identityHex, outgoing: true, text: body.text,
            sentAt: now, agent: false, sponsorship: .human))
        try await persist()
        return sp
    }

    /// Revokes a sponsorship I issued (by id prefix, or every live one for a contact).
    /// Effective locally at once; the agent stops on receipt. `alsoNotify` contacts get
    /// the signed revocation too, so their clients stop showing the badge immediately.
    @discardableResult
    public func revokeSponsorship(_ q: String, alsoNotify: [String] = []) async throws -> [String] {
        let s = q.lowercased()
        var a = agentState
        let targets = (a.issued ?? []).enumerated().filter { _, i in
            i.revokedAt == nil
                && ((s.count >= 6 && i.sponsorship.sponsorshipID.hasPrefix(s))
                    || (try? contact(matching: q).identityHex) == i.sponsorship.agent)
        }
        guard !targets.isEmpty else { throw EldrClientError.unknownSponsorship(q) }
        let now = Self.nowSeconds
        var revokedIDs: [String] = []
        var firstError: Error?
        for (idx, issued) in targets {
            let r = try AgentSponsorshipRevocation.make(
                sponsorshipID: issued.sponsorship.sponsorshipID, revokedAt: now, identity: identity)
            // Close it locally FIRST so a failed send can never leave it open here.
            a.issued![idx].revokedAt = now
            var rv = a.revoked ?? []
            RevocationSet.remember("\(identityHex):\(r.sponsorshipID)", into: &rv, max: AgentState.maxRevoked)
            a.revoked = rv
            agentState = a
            try await persist()
            revokedIDs.append(r.sponsorshipID)
            var body = MessageBody(
                text: "🛡 I revoked my sponsorship of this AI account.", sentAt: now,
                messageID: UUID().uuidString)
            body.agentSponsorshipRevocation = r
            let recipients = [issued.sponsorship.agent] + alsoNotify.compactMap { try? contact(matching: $0).identityHex }
            for rid in Set(recipients) {
                guard let c = state.contacts.first(where: { $0.identityHex == rid }) else { continue }
                do { _ = try await deliver(body, to: c, participant: .human) } catch { firstError = firstError ?? error }
            }
            a = agentState
        }
        try await persist()
        if let firstError { throw firstError }
        return revokedIDs
    }

    // MARK: Receive side

    /// Handles control objects in a received body. Called once per logical message.
    func processControl(_ m: ReceivedMessage) -> [ClientEvent] {
        var out: [ClientEvent] = []
        let sender = m.senderIdentityHex
        if let r = m.body.agentSponsorshipRevocation {
            if (try? r.verify(presentedBy: sender)) != nil {
                var a = agentState
                // Per-sponsor quota: one contact's junk revocations can't evict others' (AC212).
                var rv = a.revoked ?? []
                RevocationSet.remember("\(sender):\(r.sponsorshipID)", into: &rv, max: AgentState.maxRevoked)
                a.revoked = rv
                if let mine = a.mySponsorship, mine.sponsorshipID == r.sponsorshipID,
                    mine.enabledBy.hexString == sender
                {
                    a.mySponsorship = nil
                    out.append(.sponsorship("Your owner revoked this AI account's sponsorship. Sending is paused."))
                }
                agentState = a
            }
        }
        // A sponsorship sent TO me by its signer (as opposed to one an agent attaches).
        if let sp = m.body.agentSponsorship, m.participantType == .human, sp.enabledBy.hexString == sender {
            if sp.agent != identityHex {
                // Someone else's sponsorship, presented by its sponsor: nothing to do.
            } else if !isAgent {
                out.append(.sponsorship("Received a sponsorship, but this account is not in agent mode — ignored."))
            } else if sender != agentState.ownerIdentityHex {
                out.append(.sponsorship("Refused a sponsorship from \(sender.prefix(12))…: not the pinned owner."))
            } else if isRevoked(sp) {
                out.append(.sponsorship("Refused a sponsorship that was already revoked."))
            } else {
                do {
                    try sp.verify(presentedBy: sender, now: Self.nowSeconds)
                    var a = agentState
                    a.mySponsorship = sp
                    agentState = a
                    out.append(.sponsorship("Sponsored by your owner until \(Date(timeIntervalSince1970: TimeInterval(sp.activeUntil)))."))
                } catch {
                    out.append(.sponsorship("Refused an invalid sponsorship: \(error)"))
                }
            }
        }
        return out
    }

    /// Per-message sponsorship check for anything agent-labeled.
    public func sponsorshipStatus(of m: ReceivedMessage, now: Int64 = EldrClient.nowSeconds) -> SponsorshipStatus {
        SponsorshipStatus.evaluate(
            participantType: m.participantType, body: m.body, senderIdentityHex: m.senderIdentityHex,
            now: now, isRevoked: isRevoked)
    }

    func appendHistory(_ e: HistoryEntry) {
        var a = agentState
        var h = a.history ?? []
        var e = e
        let seq = a.nextSeq ?? 1
        e.seq = seq
        a.nextSeq = seq + 1
        h.append(e)
        if h.count > AgentState.maxHistory { h.removeFirst(h.count - AgentState.maxHistory) }
        // Byte cap too: the whole state is re-encrypted on every save.
        var total = h.reduce(0) { $0 + $1.text.utf8.count }
        while total > AgentState.maxHistoryBytes, h.count > 1 { total -= h.removeFirst().text.utf8.count }
        a.history = h
        agentState = a
    }

    /// Joins chunked messages. Returns nil while parts are outstanding.
    func reassemble(_ m: ReceivedMessage) -> MessageBody? {
        guard let ch = m.body.chunk else { return m.body }
        guard ch.total >= 1, ch.total <= PQRCConstants.maxChunksPerMessage, (0..<ch.total).contains(ch.index)
        else { return nil }
        if ch.total == 1 { var b = m.body; b.chunk = nil; return b }
        let key = "\(m.senderIdentityHex):\(ch.id)"
        chunkCounter += 1
        var acc = chunkBuffers[key] ?? {
            var t = m.body
            t.text = ""
            t.chunk = nil
            return (template: t, total: ch.total, parts: [:], order: chunkCounter)
        }()
        guard acc.total == ch.total else { return nil }
        // Memory bound (AC214): 16 buffers × 512 parts × ~64 KiB let one contact pin
        // ~0.5 GiB. Cap what is held across ALL incomplete messages.
        let held = chunkBuffers.values.reduce(0) { $0 + $1.parts.values.reduce(0) { $0 + $1.utf8.count } }
        let prior = acc.parts[ch.index]?.utf8.count ?? 0
        if held - prior + m.body.text.utf8.count > Self.maxBufferedChunkBytes {
            chunkBuffers[key] = nil
            return nil
        }
        acc.parts[ch.index] = m.body.text
        acc.order = chunkCounter
        guard acc.parts.count == acc.total else {
            chunkBuffers[key] = acc
            if chunkBuffers.count > 16,
                let oldest = chunkBuffers.min(by: { $0.value.order < $1.value.order })?.key
            { chunkBuffers[oldest] = nil }
            return nil
        }
        chunkBuffers[key] = nil
        let ordered = (0..<acc.total).compactMap { acc.parts[$0] }
        guard ordered.count == acc.total else { return nil }
        var whole = acc.template
        whole.text = MessageChunker.join(ordered)
        return whole
    }
}
