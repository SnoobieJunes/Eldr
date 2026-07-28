// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCCore
import PQRCNostr

// WS-I7 Path A — "Connect my AI to a Buzz workspace", the persistent half.
//
// One `BuzzConnection` = one local model published into one Buzz workspace as an
// agent member. This file owns everything durable about that: the record on disk,
// the agent's own signing key in the Keychain, and the NIP-OA attestation that
// makes the workspace's relay accept it. `BuzzGatewayService` owns the process.
//
// Key handling (SPEC §3.1 / invariant 10):
//  - Each connection mints its OWN fresh secp256k1 agent key — never the owner's
//    identity key, and never shared between workspaces, so two workspaces can't
//    correlate the same agent pubkey.
//  - The agent key lives in the data-protection Keychain
//    (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synced) under
//    `buzzagent.<id>`, and is handed to the child ONLY through its spawn
//    environment.
//  - The OWNER key is used ONCE, in memory, to compute the attestation, and is
//    never written anywhere. What persists is the auth TAG — a signature, not a
//    secret.

/// One configured Buzz workspace connection.
struct BuzzConnection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// kind:0 display name — also the `@mention` trigger.
    var displayName: String
    var about: String
    /// kind:0 avatar, as an https URL (never an inlined data: blob — it crosses
    /// to the child as an environment variable).
    var pictureURL: String
    /// Buzz relay WebSocket URL (`wss://…`, or `ws://` on loopback).
    var relayURL: String
    var channelIds: [String]
    var systemPrompt: String
    /// x-only hex of the agent key minted for THIS connection (public half; the
    /// private half is in the Keychain).
    var agentPubkeyHex: String
    /// The workspace owner who attested this agent, when known.
    var ownerPubkeyHex: String?
    /// NIP-OA `["auth", owner, conditions, sig]` — a signature, not a secret.
    var authTagJSON: String?
    var respondToMentionsOnly: Bool
    /// Phase 4 egress firewall: scrub secret-shaped content from replies before
    /// they cross into the (signed-not-E2EE) workspace. Default ON.
    var redactOutbound: Bool
    /// Model id for the gateway to ask for. Empty ⇒ follow Huginn's current
    /// backend (`ConfigurationStore.llmModel`).
    var model: String
    /// OpenAI-compatible base URL. Empty ⇒ follow `ConfigurationStore.llmURL`.
    var providerURL: String
    /// The E2EE-termination disclosure was shown AND acknowledged. The gateway
    /// refuses to start without it (fail closed).
    var disclosureAcknowledged: Bool
    /// User-paused: not started on launch, not restarted after a stop.
    var paused: Bool
    var createdAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        displayName: String = "Eldr",
        about: String = BuzzConnection.defaultAbout,
        pictureURL: String = "",
        relayURL: String = "",
        channelIds: [String] = [],
        systemPrompt: String = BuzzConnection.defaultSystemPrompt,
        agentPubkeyHex: String = "",
        ownerPubkeyHex: String? = nil,
        authTagJSON: String? = nil,
        respondToMentionsOnly: Bool = true,
        redactOutbound: Bool = true,
        model: String = "",
        providerURL: String = "",
        disclosureAcknowledged: Bool = false,
        paused: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.about = about
        self.pictureURL = pictureURL
        self.relayURL = relayURL
        self.channelIds = channelIds
        self.systemPrompt = systemPrompt
        self.agentPubkeyHex = agentPubkeyHex
        self.ownerPubkeyHex = ownerPubkeyHex
        self.authTagJSON = authTagJSON
        self.respondToMentionsOnly = respondToMentionsOnly
        self.redactOutbound = redactOutbound
        self.model = model
        self.providerURL = providerURL
        self.disclosureAcknowledged = disclosureAcknowledged
        self.paused = paused
        self.createdAt = createdAt
    }

    static let defaultAbout =
        "A local, on-device AI hosted on its owner's own machine via Eldr/Huginn."

    /// Step 3's default persona — good enough that most users skip the text box
    /// (plan §5.4). It states the one thing a workspace member most needs to know:
    /// where this agent runs.
    static let defaultSystemPrompt = """
        You are a helpful AI participating in a Buzz workspace channel. You run \
        locally on your owner's own machine (Eldr/Huginn) — nothing you process is \
        sent to a cloud model. Answer the message you were mentioned in, directly \
        and concisely. If you are unsure, say so rather than guessing. Never repeat \
        credentials, keys, or private file contents into the channel.
        """

    /// Tolerant decoding: every field except `id` falls back to its default when
    /// absent. A record written by an older (or newer) Huginn must not fail to
    /// decode — the file is decoded as a WHOLE, so one missing key would silently
    /// empty the user's entire connection list and orphan live Keychain items.
    /// Same forward-compatibility posture as the wire structs (SPEC §12).
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BuzzConnection()
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? fallback.displayName
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? fallback.about
        pictureURL = try c.decodeIfPresent(String.self, forKey: .pictureURL) ?? ""
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL) ?? ""
        channelIds = try c.decodeIfPresent([String].self, forKey: .channelIds) ?? []
        systemPrompt =
            try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? fallback.systemPrompt
        agentPubkeyHex = try c.decodeIfPresent(String.self, forKey: .agentPubkeyHex) ?? ""
        ownerPubkeyHex = try c.decodeIfPresent(String.self, forKey: .ownerPubkeyHex)
        authTagJSON = try c.decodeIfPresent(String.self, forKey: .authTagJSON)
        respondToMentionsOnly =
            try c.decodeIfPresent(Bool.self, forKey: .respondToMentionsOnly) ?? true
        // Missing ⇒ ON. A record from before the egress firewall existed must not
        // decode into an agent that posts unredacted (fail toward privacy).
        redactOutbound = try c.decodeIfPresent(Bool.self, forKey: .redactOutbound) ?? true
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        providerURL = try c.decodeIfPresent(String.self, forKey: .providerURL) ?? ""
        // Missing ⇒ NOT acknowledged: the disclosure gate fails closed.
        disclosureAcknowledged =
            try c.decodeIfPresent(Bool.self, forKey: .disclosureAcknowledged) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        // Belt and braces on top of the symmetric decoder above: a date written in
        // any other shape falls back rather than throwing, because throwing here
        // costs the user every connection in the file, not just this timestamp.
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    /// Keychain account for this connection's agent private key.
    var keychainAccount: String { Self.keychainAccount(id: id) }
    static func keychainAccount(id: String) -> String { "buzzagent.\(id)" }

    /// Short, human-readable relay label for the status row (`auston.communities.buzz.xyz`).
    var relayHost: String { URL(string: relayURL)?.host ?? relayURL }
}

/// Everything that can be wrong with a connection before it may run. Surfaced in
/// the wizard as sentences, and re-checked at start (a hand-edited file must not
/// launch a gateway that can't work).
enum BuzzConnectionProblem: Equatable {
    case missingDisplayName
    case invalidRelay(String)
    case noChannels
    case invalidChannel(String)
    case disclosureNotAcknowledged
    case missingAgentKey

    var message: String {
        switch self {
        case .missingDisplayName:
            return "Give the agent a display name — it's what people @mention."
        case .invalidRelay(let why):
            return "Workspace relay URL: \(why)"
        case .noChannels:
            return "Add at least one channel for the agent to listen in."
        case .invalidChannel(let value):
            return "“\(value)” isn't a channel id (Buzz channels are UUIDs)."
        case .disclosureNotAcknowledged:
            return
                "Acknowledge the end-to-end-encryption notice before the agent posts anything."
        case .missingAgentKey:
            return "This connection has no agent key in the Keychain — remove it and reconnect."
        }
    }
}

/// The durable half of WS-I7: the connection file + the agent keys behind it.
///
/// Paths and Keychain are injectable so the tests run against a temp dir and an
/// isolated Keychain service, never the user's real state.
@MainActor
final class BuzzConnectionStore: ObservableObject {

    @Published private(set) var connections: [BuzzConnection] = []

    let path: String
    private let keychain: KeychainBox
    private let random: any RandomSource

    init(
        path: String = ConfigPaths.standard.buzzConnectionsFile,
        keychain: KeychainBox = KeychainBox(),
        random: any RandomSource = SystemRandomSource()
    ) {
        self.path = path
        self.keychain = keychain
        self.random = random
        reload()
    }

    // MARK: - Load / save

    private struct File: Codable { var connections: [BuzzConnection] }

    /// The decoder MUST mirror `persist()`'s encoder — an asymmetric date strategy
    /// silently emptied the whole list on the next launch (the file decodes as a
    /// whole, so one throwing field drops every connection while its Keychain key
    /// lives on). Caught by `createMintsAndPersists`.
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func reload() {
        guard let data = FileManager.default.contents(atPath: path),
            let file = try? Self.decoder().decode(File.self, from: data)
        else {
            connections = []
            return
        }
        connections = file.connections
    }

    @discardableResult
    private func persist() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(File(connections: connections)) else { return false }
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            // Owner-only: the file carries relay URLs, channel ids, and the
            // attestation — not secrets, but nothing another account needs either.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }

    func connection(id: String) -> BuzzConnection? { connections.first { $0.id == id } }

    // MARK: - Create / update / remove

    enum StoreError: Error, LocalizedError, Equatable {
        case keyGeneration(String)
        case attestation(String)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .keyGeneration(let why): return "Couldn't create the agent's key: \(why)"
            case .attestation(let why): return "Owner attestation failed: \(why)"
            case .writeFailed: return "Couldn't write the connections file."
            }
        }
    }

    /// Mint a fresh agent key for `draft`, optionally owner-attest it (NIP-OA),
    /// store the private half in the Keychain, and save the record.
    ///
    /// `ownerPrivateKey` — an nsec or 64-hex owner key — is used ONCE here and is
    /// never persisted; only the resulting auth tag and the owner's PUBLIC key are
    /// written. Pass nil when the owner supplies a ready-made auth tag instead
    /// (the "I was invited" path), or when the agent key is itself a member.
    @discardableResult
    func create(_ draft: BuzzConnection, ownerPrivateKey: String?) throws -> BuzzConnection {
        var connection = draft
        let keypair: NostrKeypair
        do {
            keypair = try NostrKeypair(randomSource: random)
        } catch {
            throw StoreError.keyGeneration(error.localizedDescription)
        }
        connection.agentPubkeyHex = keypair.publicKeyHex

        if let ownerPrivateKey, !ownerPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let attestation = try Self.attest(
                ownerPrivateKey: ownerPrivateKey, agentPublicKeyHex: keypair.publicKeyHex,
                random: random)
            connection.ownerPubkeyHex = attestation.ownerPubkeyHex
            connection.authTagJSON = attestation.authTagJSON
        }

        do {
            try keychain.save(
                Data(keypair.privateKeyData.hexString.utf8), account: connection.keychainAccount)
        } catch {
            throw StoreError.keyGeneration("Keychain refused the item (\(error)).")
        }
        connections.append(connection)
        guard persist() else {
            keychain.delete(account: connection.keychainAccount)
            connections.removeAll { $0.id == connection.id }
            throw StoreError.writeFailed
        }
        return connection
    }

    func update(_ connection: BuzzConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        persist()
    }

    /// Remove the record AND destroy the agent key. The caller publishes the
    /// signed retirement first (`BuzzRevoker`) — once this returns, the key that
    /// could sign as this agent no longer exists on the machine.
    func remove(id: String) {
        keychain.delete(account: BuzzConnection.keychainAccount(id: id))
        connections.removeAll { $0.id == id }
        persist()
    }

    /// Phase 4 key rotation: mint a NEW agent key for an existing connection and
    /// re-attest it, so a workspace can't keep correlating the old pubkey. The old
    /// key is destroyed; the caller restarts the gateway (and may retire the old
    /// identity first).
    @discardableResult
    func rotateKey(id: String, ownerPrivateKey: String?) throws -> BuzzConnection {
        guard var connection = connection(id: id) else { throw StoreError.writeFailed }
        let keypair: NostrKeypair
        do {
            keypair = try NostrKeypair(randomSource: random)
        } catch {
            throw StoreError.keyGeneration(error.localizedDescription)
        }
        if let ownerPrivateKey, !ownerPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let attestation = try Self.attest(
                ownerPrivateKey: ownerPrivateKey, agentPublicKeyHex: keypair.publicKeyHex,
                random: random)
            connection.ownerPubkeyHex = attestation.ownerPubkeyHex
            connection.authTagJSON = attestation.authTagJSON
        } else {
            // A stale attestation names the OLD key and the relay would reject it —
            // never carry it forward silently.
            connection.authTagJSON = nil
        }
        connection.agentPubkeyHex = keypair.publicKeyHex
        do {
            try keychain.save(
                Data(keypair.privateKeyData.hexString.utf8), account: connection.keychainAccount)
        } catch {
            throw StoreError.keyGeneration("Keychain refused the item (\(error)).")
        }
        update(connection)
        return connection
    }

    /// Attach an admin-supplied NIP-OA tag to an EXISTING connection ("I was
    /// invited").
    ///
    /// This is deliberately a second step rather than a wizard field: a NIP-OA tag
    /// signs a SPECIFIC agent pubkey, and that key does not exist until the
    /// connection is created — so an admin cannot attest it in advance. The order
    /// that actually works is: create the connection → send the admin the agent
    /// pubkey Huginn shows → paste the tag they return here.
    ///
    /// The tag is verified against THIS connection's agent key before it is
    /// stored; a tag for someone else's agent is refused rather than saved and
    /// then silently rejected by the relay at connect time.
    @discardableResult
    func applyAttestation(_ tagJSON: String, id: String) throws -> BuzzConnection {
        guard var connection = connection(id: id) else { throw StoreError.writeFailed }
        let trimmed = tagJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner: String
        do {
            owner = try NIPOA.verifyAuthTag(trimmed, agentPublicKeyHex: connection.agentPubkeyHex)
        } catch {
            throw StoreError.attestation(
                "that tag doesn't authorize THIS agent key (\(String(connection.agentPubkeyHex.prefix(12)))…). Send your admin the agent key shown here and paste the tag they return."
            )
        }
        connection.authTagJSON = trimmed
        connection.ownerPubkeyHex = owner
        update(connection)
        return connection
    }

    // MARK: - Keys

    /// The agent's private key (hex) for a connection, or nil when the Keychain
    /// item is gone (a restored file without its keys).
    func agentPrivateKeyHex(id: String) -> String? {
        keychain.load(account: BuzzConnection.keychainAccount(id: id))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func hasAgentKey(id: String) -> Bool {
        keychain.hasItem(account: BuzzConnection.keychainAccount(id: id))
    }

    /// The signing keypair for a connection — needed to publish the retirement
    /// events on Remove. Nil when the key is missing or unreadable.
    func agentKeypair(id: String) -> NostrKeypair? {
        guard let hex = agentPrivateKeyHex(id: id), let data = Data(hexString: hex) else {
            return nil
        }
        return try? NostrKeypair(privateKey: data)
    }

    // MARK: - Attestation (pure)

    struct Attestation: Equatable {
        let ownerPubkeyHex: String
        let authTagJSON: String
    }

    /// Compute a NIP-OA owner attestation for an agent pubkey. Pure and static so
    /// the tests exercise it without a store, a Keychain, or a relay. The owner
    /// key is parsed from an `nsec1…` or 64-hex string and dropped on return.
    static func attest(
        ownerPrivateKey: String, agentPublicKeyHex: String, conditions: String = "",
        random: any RandomSource = SystemRandomSource()
    ) throws -> Attestation {
        let ownerKey: NostrKeypair
        do {
            ownerKey = try BuzzGatewayConfigParsing.parseKey(ownerPrivateKey)
        } catch {
            throw StoreError.attestation(
                "that isn't an owner key — paste the workspace owner's nsec1… or 64-hex key.")
        }
        do {
            let tag = try NIPOA.computeAuthTag(
                ownerPrivateKey: ownerKey.privateKeyData, agentPublicKeyHex: agentPublicKeyHex,
                conditions: conditions, randomSource: random)
            // Verify what we just produced before persisting it: a tag that doesn't
            // verify locally would be rejected by the relay with no explanation.
            let owner = try NIPOA.verifyAuthTag(tag, agentPublicKeyHex: agentPublicKeyHex)
            return Attestation(ownerPubkeyHex: owner, authTagJSON: tag)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.attestation("\(error)")
        }
    }

    // MARK: - Validation (pure)

    /// Everything wrong with `connection`, in the order a user should fix it.
    /// `hasKey` is passed in so the check stays pure (the caller asks the
    /// Keychain). Reuses `ConfigurationStore.validateRelayOverride` for the relay
    /// rule — SPEC §0's "never plaintext off loopback" is one rule, in one place.
    static func problems(with connection: BuzzConnection, hasKey: Bool) -> [BuzzConnectionProblem] {
        var problems: [BuzzConnectionProblem] = []
        if connection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(.missingDisplayName)
        }
        switch ConfigurationStore.validateRelayOverride(connection.relayURL) {
        case .success(let url):
            if url == nil { problems.append(.invalidRelay("required (e.g. wss://you.communities.buzz.xyz)")) }
        case .failure(let error):
            switch error {
            case .invalidURL:
                problems.append(.invalidRelay("that isn't a URL."))
            case .unsupportedScheme:
                problems.append(.invalidRelay("use a wss:// (or loopback ws://) WebSocket URL."))
            case .plaintextOffLoopback:
                problems.append(
                    .invalidRelay(
                        "plaintext ws:// is only allowed for a relay on this machine — use wss://."))
            }
        }
        if connection.channelIds.isEmpty {
            problems.append(.noChannels)
        }
        for channel in connection.channelIds where !isChannelID(channel) {
            problems.append(.invalidChannel(channel))
        }
        if !connection.disclosureAcknowledged {
            problems.append(.disclosureNotAcknowledged)
        }
        if !hasKey || connection.agentPubkeyHex.count != 64 {
            problems.append(.missingAgentKey)
        }
        return problems
    }

    /// Buzz channel ids are UUIDs (the `h` tag). Accepts either case.
    static func isChannelID(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// Split a user-typed channel list ("a, b\nc") into ids.
    static func parseChannelList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// Key parsing shared with the gateway's own env reader. Huginn deliberately does
/// NOT link `EldrBuzzGateway` (it would pull the whole node package into the app),
/// so the one-screen parse is mirrored here against the SAME rules — hex or
/// `nsec1…`, 32 bytes — and pinned by `BuzzConnectionTests`.
enum BuzzGatewayConfigParsing {
    enum ParseError: Error { case badKey }

    static func parseKey(_ raw: String) throws -> NostrKeypair {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("nsec1") {
            guard let (hrp, data) = Bech32.decode(trimmed), hrp == "nsec", data.count == 32,
                let keypair = try? NostrKeypair(privateKey: data)
            else { throw ParseError.badKey }
            return keypair
        }
        guard let data = Data(hexString: trimmed), data.count == 32,
            let keypair = try? NostrKeypair(privateKey: data)
        else { throw ParseError.badKey }
        return keypair
    }
}
