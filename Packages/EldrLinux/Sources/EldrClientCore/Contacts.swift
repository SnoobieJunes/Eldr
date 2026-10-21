// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// 60-digit safety code in 12 groups of 5 (APP-SPEC §6.4, D13). Same algorithm as
/// iOS `PersonaRuntime.safetyCode(with:)`: SHA-256 of the two identity keys sorted by
/// hex, stretched by re-hashing, each byte mod 10.
public enum SafetyCode {
    public static func compute(_ a: Data, _ b: Data) -> String {
        let keys = [a, b].sorted { $0.hexString < $1.hexString }
        var digest = sha256(keys[0] + keys[1])
        var digits = ""
        while digits.count < 60 {
            for byte in digest where digits.count < 60 { digits += String(byte % 10) }
            digest = sha256(digest)
        }
        return stride(from: 0, to: 60, by: 5).map { String(digits.dropFirst($0).prefix(5)) }.joined(separator: " ")
    }
}

/// Contact management (WS-N7): rename, verify by safety code, block, pin, delete
/// history. Deleting history is not unfriending (same as iOS `deleteConversation`).
extension EldrClient {
    private func contactIndex(_ q: String) throws -> Int {
        let c = try contact(matching: q)
        guard let i = state.contacts.firstIndex(where: { $0.identityHex == c.identityHex }) else {
            throw EldrClientError.unknownContact(q)
        }
        return i
    }

    public func renameContact(_ q: String, to name: String?) async throws {
        let i = try contactIndex(q)
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n, n.count > 64 { throw EldrClientError.badSetting("names are at most 64 characters") }
        state.contacts[i].name = (n?.isEmpty ?? true) ? nil : n
        try await persist()
    }

    public func safetyCode(with q: String) throws -> String {
        let c = try contact(matching: q)
        guard let peer = Data(hexString: c.identityHex) else { throw EldrClientError.unknownContact(q) }
        return SafetyCode.compute(identity.publicKeyData, peer)
    }

    public func setVerified(_ q: String, _ on: Bool) async throws {
        let i = try contactIndex(q)
        state.contacts[i].verified = on ? true : nil
        try await persist()
    }

    /// A blocked contact's messages are dropped by the messenger (nothing is sent to
    /// them about it); unblocking resumes delivery of new messages.
    public func setBlocked(_ q: String, _ on: Bool) async throws {
        let i = try contactIndex(q)
        state.contacts[i].blocked = on ? true : nil
        await messenger.setBlocked(state.contacts[i].identityHex, blocked: on)
        try await persist()
    }

    public func setPinned(_ q: String, _ on: Bool) async throws {
        let i = try contactIndex(q)
        state.contacts[i].pinned = on ? true : nil
        try await persist()
    }

    /// Local history only; the contact and its session survive. Returns rows removed.
    @discardableResult
    public func deleteHistory(with q: String) async throws -> Int {
        let c = try contact(matching: q)
        var a = agentState
        let before = a.history?.count ?? 0
        a.history = a.history?.filter { !($0.peerIdentityHex == c.identityHex && $0.groupID == nil && $0.threadID == nil) }
        agentState = a
        try await persist()
        return before - (a.history?.count ?? 0)
    }

    /// Re-apply blocks after a restart (the messenger's block list is in memory).
    func reapplyBlocks() async {
        for c in state.contacts where c.blocked == true { await messenger.setBlocked(c.identityHex, blocked: true) }
    }
}
