// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation
import PQRCCore
import PQRCNostr

/// WS-BM3 — the app-side engine for Buzz workspaces.
///
/// Sibling to `AppModel`, deliberately **not** merged into it. A Buzz workspace
/// is a different kind of thing from an Eldr conversation and the separation is
/// the point:
///
/// - An Eldr conversation is PQ-ratcheted end-to-end; the relay sees ciphertext.
/// - A Buzz channel is **signed but not encrypted**; the workspace's relay
///   operator reads every word.
///
/// Folding the two into one list of "chats" would make that difference a styling
/// detail. It is not — it is the whole security posture, and the UI owes the
/// user a visible boundary (`disclosure`, below) the same way the `ai_window`
/// banner is owed. Eldr's own encrypted plane over a Buzz relay is WS-BM4 and is
/// a separate surface again.
@MainActor
@Observable
final class BuzzWorkspaceModel {
    /// The honest, unmissable sentence. Shown before the first send into any
    /// workspace and available from the channel header thereafter.
    ///
    /// `nonisolated` because it is a constant and error text is formatted from
    /// background contexts too — the boundary must be renderable everywhere it
    /// is needed, never skipped because the wrong actor was current.
    nonisolated static let disclosure = """
        Messages you send in this workspace are readable by whoever runs it. \
        Buzz channels are signed but not end-to-end encrypted. Your Eldr chats \
        stay encrypted; this workspace does not.
        """

    enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var workspaces: [BuzzWorkspaceRecord] = []
    private(set) var channels: [String: [BuzzChannel]] = [:]  // workspaceID → channels
    private(set) var messages: [String: [BuzzMessage]] = [:]  // "workspaceID/channelID" → messages
    private(set) var rosters: [String: BuzzRoster] = [:]  // "workspaceID/channelID" → roster
    private(set) var profiles: [String: [String: BuzzProfile]] = [:]  // workspaceID → pubkey → profile
    private(set) var state: [String: ConnectionState] = [:]  // workspaceID → state
    /// Set when a send failed, so the UI can surface the relay's own words
    /// rather than a generic failure.
    private(set) var lastError: [String: String] = [:]

    /// The transport seam (CLAUDE.md: dependency seams are protocols, injected).
    /// Production dials a real WebSocket; tests inject an in-process relay so no
    /// unit test touches the network.
    typealias TransportFactory = @Sendable (URL) async -> any RelayTransport

    private let registry: BuzzWorkspaceRegistry
    private let makeTransport: TransportFactory
    private var clients: [String: BuzzWorkspaceClient] = [:]
    private var transports: [String: any RelayTransport] = [:]
    private var timelineTasks: [String: Task<Void, Never>] = [:]

    init(
        registry: BuzzWorkspaceRegistry,
        makeTransport: @escaping TransportFactory = { url in
            await NostrWebSocketTransport(url: url).connect()
        }
    ) {
        self.registry = registry
        self.makeTransport = makeTransport
        self.workspaces = registry.load()
    }

    static func key(_ workspaceID: String, _ channelID: String) -> String {
        "\(workspaceID)/\(channelID)"
    }

    func connectionState(_ workspaceID: String) -> ConnectionState {
        state[workspaceID] ?? .idle
    }

    // MARK: - Joining

    /// Join a workspace from an invite link. Mints a fresh per-workspace key
    /// (AC147), claims, persists, and connects.
    @discardableResult
    func join(link: BuzzInviteLink, name: String? = nil, ageConfirmed: Bool = false) async throws
        -> BuzzWorkspaceRecord
    {
        let record = try await registry.join(link: link, name: name, ageConfirmed: ageConfirmed)
        workspaces = registry.load()
        await connect(record)
        return record
    }

    /// Leave locally: disconnect, drop the record, destroy the key.
    func forget(_ record: BuzzWorkspaceRecord) {
        disconnect(record.id)
        registry.forget(record)
        workspaces = registry.load()
        channels[record.id] = nil
        profiles[record.id] = nil
        state[record.id] = nil
        for key in messages.keys where key.hasPrefix("\(record.id)/") { messages[key] = nil }
        for key in rosters.keys where key.hasPrefix("\(record.id)/") { rosters[key] = nil }
    }

    // MARK: - Session

    /// Idempotent. SwiftUI re-runs a row's `.task` whenever the row is rebuilt,
    /// so without this guard scrolling the sidebar would open a new WebSocket
    /// per rebuild and orphan the previous one.
    func connect(_ record: BuzzWorkspaceRecord) async {
        switch connectionState(record.id) {
        case .connecting, .connected: return
        case .idle, .failed: break
        }
        guard let url = URL(string: record.relayURL) else {
            state[record.id] = .failed("That workspace address isn't a valid relay URL.")
            return
        }
        state[record.id] = .connecting
        do {
            let keypair = try registry.keypair(for: record)
            let transport = await makeTransport(url)
            let client = BuzzWorkspaceClient(
                transport: transport, keypair: keypair,
                randomSource: SystemRandomSource(),
                configuration: .init(relayURL: record.relayURL))
            try await client.connect()
            transports[record.id] = transport
            clients[record.id] = client
            channels[record.id] = try await client.channels()
            state[record.id] = .connected
        } catch {
            state[record.id] = .failed(Self.describe(error))
        }
    }

    func disconnect(_ workspaceID: String) {
        timelineTasks
            .filter { $0.key.hasPrefix("\(workspaceID)/") }
            .forEach { key, task in
                task.cancel()
                timelineTasks[key] = nil
            }
        // Socket teardown is transport-specific; in-process transports have no
        // socket to close, so the downcast is the whole of it.
        if let socket = transports[workspaceID] as? NostrWebSocketTransport {
            Task { await socket.disconnect() }
        }
        transports[workspaceID] = nil
        clients[workspaceID] = nil
        state[workspaceID] = .idle
    }

    // MARK: - Channels

    /// Load a channel's history and roster, then follow it live. Safe to call
    /// again for the same channel — the live follow is not duplicated.
    func openChannel(_ channelID: String, in workspaceID: String) async {
        guard let client = clients[workspaceID] else { return }
        let key = Self.key(workspaceID, channelID)
        do {
            let history = try await client.history(channelID: channelID)
            // Merge rather than assign: a live message can land between the
            // history request and its response, and re-opening a channel must
            // not drop it.
            var merged = messages[key] ?? []
            let known = Set(merged.map(\.id))
            merged.append(contentsOf: history.filter { !known.contains($0.id) })
            messages[key] = merged.sorted { $0.createdAt < $1.createdAt }
            let roster = try await client.roster(channelID: channelID)
            rosters[key] = roster
            await loadProfiles(for: roster.members, in: workspaceID)
        } catch {
            lastError[workspaceID] = Self.describe(error)
        }
        guard timelineTasks[key] == nil else { return }
        let since = (messages[key]?.last?.createdAt).map { $0 + 1 }
        let stream = await client.timeline(channelID: channelID, since: since)
        timelineTasks[key] = Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.apply(event, workspaceID: workspaceID, channelID: channelID)
                }
            } catch {
                await self?.recordStreamFailure(error, workspaceID: workspaceID)
            }
        }
    }

    func closeChannel(_ channelID: String, in workspaceID: String) {
        let key = Self.key(workspaceID, channelID)
        timelineTasks[key]?.cancel()
        timelineTasks[key] = nil
    }

    private func apply(_ event: BuzzWorkspaceEvent, workspaceID: String, channelID: String) async {
        let key = Self.key(workspaceID, channelID)
        switch event {
        case .message(let message):
            var list = messages[key] ?? []
            // The relay replays stored events before live ones, and a reconnect
            // replays again — dedupe by event id rather than trusting ordering.
            guard !list.contains(where: { $0.id == message.id }) else { return }
            list.append(message)
            messages[key] = list.sorted { $0.createdAt < $1.createdAt }
            if profiles[workspaceID]?[message.authorPubkey] == nil {
                await loadProfiles(for: [message.authorPubkey], in: workspaceID)
            }
        case .deletion(let messageID, let byPubkey):
            // Only honour a deletion by the message's own author. Buzz enforces
            // this relay-side too, but a client that trusts the relay to have
            // done so is a client that hides messages on a hostile relay's say-so.
            messages[key] = (messages[key] ?? []).filter {
                !($0.id == messageID && $0.authorPubkey == byPubkey)
            }
        case .rosterUpdated(let roster):
            let existing = rosters[key] ?? BuzzRoster(channelID: channelID)
            rosters[key] = existing.merging(roster)
        case .channelUpdated(let channel):
            var list = channels[workspaceID] ?? []
            if let index = list.firstIndex(where: { $0.id == channel.id }) {
                list[index] = channel
            } else {
                list.append(channel)
            }
            channels[workspaceID] = list
        case .reaction, .membership, .unhandled:
            // Reactions and membership churn are not rendered yet; unknown kinds
            // are expected (Buzz ships kinds we do not model) and are never errors.
            break
        }
    }

    private func recordStreamFailure(_ error: any Error, workspaceID: String) {
        lastError[workspaceID] = Self.describe(error)
        if case .connected = connectionState(workspaceID) {
            state[workspaceID] = .failed(Self.describe(error))
        }
    }

    private func loadProfiles(for pubkeys: [String], in workspaceID: String) async {
        guard let client = clients[workspaceID] else { return }
        let known = profiles[workspaceID] ?? [:]
        let missing = pubkeys.filter { known[$0] == nil }
        guard !missing.isEmpty, let fetched = try? await client.profiles(of: missing) else { return }
        profiles[workspaceID] = known.merging(fetched) { _, new in new }
    }

    // MARK: - Sending

    /// Post to a channel. Returns false and sets `lastError` on failure — a send
    /// that did not land must never look like one that did.
    @discardableResult
    func send(_ text: String, to channelID: String, in workspaceID: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = clients[workspaceID] else { return false }
        do {
            _ = try await client.send(trimmed, to: channelID)
            lastError[workspaceID] = nil
            return true
        } catch {
            lastError[workspaceID] = Self.describe(error)
            return false
        }
    }

    func displayName(_ pubkey: String, in workspaceID: String) -> String {
        profiles[workspaceID]?[pubkey]?.bestName ?? String(pubkey.prefix(8))
    }

    func isMine(_ message: BuzzMessage, in workspaceID: String) -> Bool {
        workspaces.first { $0.id == workspaceID }?.pubkeyHex == message.authorPubkey
    }

    /// User-facing error text. Buzz's relay messages are terse but genuinely
    /// useful (`restricted: …`, `invalid: …`), so they are surfaced rather than
    /// flattened into "something went wrong".
    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case BuzzWorkspaceError.rejected(let reason):
            return "The workspace refused it: \(reason)"
        case BuzzWorkspaceError.contentTooLong(let bytes, let limit):
            return "That message is \(bytes) bytes; this workspace allows \(limit). Shorten it or split it yourself."
        case BuzzInviteError.expired:
            return "That invite has expired. Ask for a fresh link."
        case BuzzInviteError.invalid:
            return "That invite isn't valid for this workspace."
        case BuzzInviteError.joinPolicyRequired, BuzzInviteError.joinPolicyNotAccepted:
            return "This workspace requires you to accept its terms before joining."
        case BuzzInviteError.rateLimited:
            return "Too many join attempts. Wait a minute and try again."
        case BuzzInviteError.malformedLink, BuzzInviteError.unsupportedRelayScheme:
            return "That doesn't look like a Buzz invite link."
        case NostrError.notAuthenticated:
            return "This workspace didn't accept your key. You may have been removed from it."
        default:
            return "Couldn't reach the workspace."
        }
    }
}
