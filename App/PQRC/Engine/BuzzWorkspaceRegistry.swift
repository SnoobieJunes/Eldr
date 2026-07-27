// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr

/// WS-BM3 — the phone's record of which Buzz workspaces this account belongs to,
/// and the keys it belongs with.
///
/// **One key per workspace, never the Eldr identity key** (DEVIATIONS AC147).
/// Buzz's own client mints a fresh keypair per community and so do we, for two
/// reasons that both matter more than the convenience of a single key:
///
/// - Reusing the Eldr Nostr identity would publish a permanent, public
///   correlation between Eldr identity and Buzz activity — the irreversible cost
///   `ELDR-BUZZ-PAIRING.md §3` records for its Option A. There is no undoing it
///   after the first post.
/// - Two workspaces run by two operators cannot be linked to one person by their
///   member key alone.
///
/// The secret half lives in the Keychain under `buzzws.<workspaceID>`, in the
/// account's own silo service, with the same `WhenUnlockedThisDeviceOnly` class
/// as every other long-term secret (invariant 10). The record below carries no
/// secret and is safe in UserDefaults alongside the rest of the silo's config.
struct BuzzWorkspaceRecord: Codable, Identifiable, Sendable, Equatable {
    /// Local id; also the Keychain account suffix. Not an identity.
    let id: String
    /// `wss://…` — with the channel id, half of every Buzz address. Buzz resolves
    /// the community from this host before AUTH, so it can never be dropped.
    var relayURL: String
    /// What the user calls this workspace.
    var name: String
    /// The community id the relay reported at claim time.
    var communityID: String
    /// The role the invite granted (`member` / `admin`).
    var role: String
    /// Our member pubkey in this workspace — the public half of `buzzws.<id>`.
    var pubkeyHex: String
    var joinedAt: Int64

    /// The Keychain account holding this workspace's secret key.
    var keychainAccount: String { BuzzWorkspaceRegistry.keychainAccount(for: id) }

    /// The host, for display. A workspace is identified to the user by the
    /// operator's domain, because that is who can read what they post there.
    var host: String { URL(string: relayURL)?.host ?? relayURL }
}

/// Loads, saves and keys the workspace list for one account silo.
struct BuzzWorkspaceRegistry: Sendable {
    let siloID: String
    let keychain: KeychainStore
    let randomSource: any RandomSource

    init(siloID: String, keychain: KeychainStore, randomSource: any RandomSource = SystemRandomSource()) {
        self.siloID = siloID
        self.keychain = keychain
        self.randomSource = randomSource
    }

    static func keychainAccount(for workspaceID: String) -> String { "buzzws.\(workspaceID)" }

    private var defaultsKey: String { AppSession.siloDefaultsKey("buzzWorkspaces", siloID) }

    // MARK: - Records

    func load() -> [BuzzWorkspaceRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let records = try? JSONDecoder().decode([BuzzWorkspaceRecord].self, from: data)
        else { return [] }
        return records
    }

    func save(_ records: [BuzzWorkspaceRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Keys

    /// Mint a fresh per-workspace keypair and store the secret half. Called once,
    /// before claiming an invite: the key that claims is the key that becomes a
    /// member, so it must exist first.
    func mintKeypair(for workspaceID: String) throws -> NostrKeypair {
        let keypair = try NostrKeypair(randomSource: randomSource)
        try keychain.save(keypair.privateKeyData, account: Self.keychainAccount(for: workspaceID))
        return keypair
    }

    func keypair(for record: BuzzWorkspaceRecord) throws -> NostrKeypair {
        let data = try keychain.load(account: record.keychainAccount)
        return try NostrKeypair(privateKey: data)
    }

    /// Forget a workspace: drop the record AND destroy the key.
    ///
    /// Leaving the key behind would leave a usable workspace credential on the
    /// device after the user believes they have left, so the Keychain delete is
    /// part of the operation, not a cleanup detail. Note this is local only —
    /// Buzz's own membership row is the relay's to remove, and a Nostr relay
    /// keeps what was already published either way.
    func forget(_ record: BuzzWorkspaceRecord) {
        keychain.delete(account: record.keychainAccount)
        save(load().filter { $0.id != record.id })
    }

    // MARK: - Joining

    /// Claim an invite with a freshly minted key and persist the result.
    ///
    /// Idempotent on Buzz's side (`already_member` is a success), so a retry
    /// after a dropped response is safe — but it mints a *new* key each attempt,
    /// so the caller should not loop on this blindly.
    func join(
        link: BuzzInviteLink, name: String? = nil, ageConfirmed: Bool = false,
        http: any BuzzHTTPTransport = URLSessionBuzzHTTPTransport(),
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) async throws -> BuzzWorkspaceRecord {
        let workspaceID = UUID().uuidString
        let keypair = try mintKeypair(for: workspaceID)
        let client = BuzzInviteClient(
            relayURL: link.relayURL, randomSource: randomSource, http: http)
        do {
            let result = try await client.claim(
                link: link, keypair: keypair, ageConfirmed: ageConfirmed)
            let record = BuzzWorkspaceRecord(
                id: workspaceID, relayURL: link.relayURL,
                name: name ?? (URL(string: link.relayURL)?.host ?? link.relayURL),
                communityID: result.communityID, role: result.role,
                pubkeyHex: keypair.publicKeyHex, joinedAt: now)
            save(load() + [record])
            return record
        } catch {
            // A failed claim must not leave an orphan credential behind.
            keychain.delete(account: Self.keychainAccount(for: workspaceID))
            throw error
        }
    }
}
