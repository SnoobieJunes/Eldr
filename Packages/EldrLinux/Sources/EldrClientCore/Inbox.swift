// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr

// WS-N7a: unread counts / mark-read, retry of "Not sent" messages, relay status.

extension EldrClient {
    func historyRows(in conv: String) -> [HistoryEntry] {
        let gid = UIConversation.groupID(conv)
        return history.filter { gid != nil ? $0.groupID == gid : ($0.peerIdentityHex == conv && $0.groupID == nil) }
    }

    /// Incoming, non-thread rows newer than my last read (iOS `unreadCount`). Uses the
    /// local arrival `seq`, never the sender-chosen `sentAt`.
    public func unreadCount(_ conv: String) -> Int {
        let last = state.lastRead?[conv] ?? 0
        return historyRows(in: conv).filter { !$0.outgoing && $0.threadID == nil && Int64($0.seq ?? 0) > last }.count
    }

    public func markRead(_ conversationQuery: String) async throws {
        let conv = try resolveConversation(conversationQuery)
        let newest = historyRows(in: conv).compactMap(\.seq).max().map(Int64.init) ?? 0
        guard (state.lastRead?[conv] ?? 0) < newest else { return }
        var r = state.lastRead ?? [:]
        r[conv] = newest
        state.lastRead = r
        try await persist()
    }

    /// Outgoing rows that reached nobody.
    public func failedMessages() -> [HistoryEntry] { history.filter { $0.failed == true } }

    /// Tap-to-retry (iOS `retry`): drop the failed copy and send the same text fresh.
    @discardableResult
    public func retry(_ messageID: String) async throws -> (reached: Int, skipped: Int) {
        guard let e = history.first(where: { $0.id == messageID || $0.id.hasPrefix(messageID) }), e.failed == true, e.outgoing
        else { throw EldrClientError.badSetting("no unsent message '\(messageID)'") }
        let conv = e.groupID.map { UIConversation.group($0) } ?? e.peerIdentityHex
        var a = agentState
        a.history = (a.history ?? []).filter { $0.id != e.id }
        agentState = a
        return try await post(e.text, conversationID: conv, threadID: e.threadID)
    }

    /// Relay panel: configured URLs and the live connection's status (observational;
    /// never gates delivery). `check` dials now.
    public func relayStatus(check: Bool = false) async -> (relays: [String], status: RelayStatus) {
        guard let t = relayTransport else { return (state.relays, .disconnected) }
        return (state.relays, check ? await t.checkConnection() : await t.currentStatus())
    }
}

public extension RelayStatus {
    var label: String {
        switch self {
        case .connected: return "connected"
        case .connecting: return "connecting…"
        case .disconnected: return "disconnected"
        case .failed(let why): return "failed: \(why)"
        }
    }
}
