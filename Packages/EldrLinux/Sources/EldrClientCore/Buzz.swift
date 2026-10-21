// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr

/// Buzz workspaces on Linux (WS-N7), mirroring iOS `BuzzWorkspaceRegistry` +
/// `BuzzWorkspaceModel`. A Buzz channel is SIGNED, NOT end-to-end encrypted: the
/// workspace operator reads every word. Every surface shows `buzzDisclosure`.
extension EldrClient {
    public static let buzzDisclosure = """
        Messages you send in this workspace are readable by whoever runs it. \
        Buzz channels are signed but not end-to-end encrypted. Your Eldr chats \
        stay encrypted; this workspace does not.
        """

    static func buzzKeyAccount(_ id: String) -> String { "buzzws.\(id)" }

    public var buzzWorkspaces: [BuzzWorkspaceRecord] { state.buzz ?? [] }

    public func buzzWorkspace(matching q: String) throws -> BuzzWorkspaceRecord {
        let ql = q.lowercased()
        let hits = buzzWorkspaces.filter { $0.id.lowercased().hasPrefix(ql) || $0.name.lowercased() == ql || $0.host.lowercased() == ql }
        guard let w = hits.first else { throw EldrClientError.badSetting("no Buzz workspace matches '\(q)'") }
        guard hits.count == 1 else { throw EldrClientError.ambiguousContact(q) }
        return w
    }

    /// Claim an invite with a FRESH per-workspace key (AC147), then persist. A failed
    /// claim leaves no orphan key behind.
    public func buzzJoin(
        link raw: String, name: String? = nil, ageConfirmed: Bool = false,
        http: any BuzzHTTPTransport = URLSessionBuzzHTTPTransport()
    ) async throws -> BuzzWorkspaceRecord {
        guard !isAgent else { throw EldrClientError.agentCannotSponsor }
        guard let link = BuzzInviteLink.parse(raw) else { throw EldrClientError.badSetting("not a Buzz invite link") }
        let id = UUID().uuidString
        let kp = try NostrKeypair(randomSource: SystemRandomSource())
        try store.save(kp.privateKeyData, account: Self.buzzKeyAccount(id))
        do {
            let r = try await BuzzInviteClient(relayURL: link.relayURL, randomSource: SystemRandomSource(), http: http)
                .claim(link: link, keypair: kp, ageConfirmed: ageConfirmed)
            let rec = BuzzWorkspaceRecord(
                id: id, relayURL: link.relayURL, name: name ?? (URL(string: link.relayURL)?.host ?? link.relayURL),
                communityID: r.communityID, role: r.role, pubkeyHex: kp.publicKeyHex, joinedAt: clock.now())
            state.buzz = buzzWorkspaces + [rec]
            try await persist()
            return rec
        } catch {
            store.delete(account: Self.buzzKeyAccount(id))
            throw error
        }
    }

    /// Leave locally: drop the record AND destroy the key (the relay keeps what was published).
    public func buzzForget(_ q: String) async throws {
        let w = try buzzWorkspace(matching: q)
        store.delete(account: Self.buzzKeyAccount(w.id))
        state.buzz = buzzWorkspaces.filter { $0.id != w.id }
        try await persist()
    }

    /// An authenticated client for one workspace. The caller owns its lifetime.
    public func buzzClient(
        _ q: String, transport: TransportFactory? = nil
    ) async throws -> BuzzWorkspaceClient {
        let w = try buzzWorkspace(matching: q)
        guard let key = store.load(account: Self.buzzKeyAccount(w.id)) else {
            throw EldrClientError.badSetting("the key for workspace \(w.name) is missing; join again")
        }
        let t = try await (transport ?? defaultTransportFactory(url: w.relayURL))()
        let c = BuzzWorkspaceClient(
            transport: t, keypair: try NostrKeypair(privateKey: key), randomSource: SystemRandomSource(),
            configuration: .init(relayURL: w.relayURL))
        try await c.connect()
        return c
    }
}
