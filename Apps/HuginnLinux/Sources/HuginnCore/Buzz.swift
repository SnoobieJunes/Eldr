// SPDX-License-Identifier: AGPL-3.0-only
// Ported from Apps/Huginn BuzzConnectionStore / BuzzGatewayService (WS-N10). The record,
// validation, attestation and child environment are the Mac code; the agent keys live in
// Huginn's EldrKeystore (`SecretStore`) instead of the Keychain.
import Foundation
import PQRCCore
import PQRCNostr

public struct BuzzConnection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// kind:0 display name — also the `@mention` trigger.
    public var displayName: String
    public var about: String
    /// kind:0 avatar, as an https URL (never an inlined data: blob — it crosses
    /// to the child as an environment variable).
    public var pictureURL: String
    /// Buzz relay WebSocket URL (`wss://…`, or `ws://` on loopback).
    public var relayURL: String
    public var channelIds: [String]
    public var systemPrompt: String
    /// x-only hex of the agent key minted for THIS connection (public half; the
    /// private half is in the Keychain).
    public var agentPubkeyHex: String
    /// The workspace owner who attested this agent, when known.
    public var ownerPubkeyHex: String?
    /// NIP-OA `["auth", owner, conditions, sig]` — a signature, not a secret.
    public var authTagJSON: String?
    public var respondToMentionsOnly: Bool
    /// Phase 4 egress firewall: scrub secret-shaped content from replies before
    /// they cross into the (signed-not-E2EE) workspace. Default ON.
    public var redactOutbound: Bool
    /// Model id for the gateway to ask for. Empty ⇒ follow Huginn's current
    /// backend (`ConfigurationStore.llmModel`).
    public var model: String
    /// OpenAI-compatible base URL. Empty ⇒ follow `ConfigurationStore.llmURL`.
    public var providerURL: String
    /// The E2EE-termination disclosure was shown AND acknowledged. The gateway
    /// refuses to start without it (fail closed).
    public var disclosureAcknowledged: Bool
    /// User-paused: not started on launch, not restarted after a stop.
    public var paused: Bool
    public var createdAt: Date

    public init(
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

    public static let defaultAbout =
        "A local, on-device AI hosted on its owner's own machine via Eldr/Huginn."

    /// Step 3's default persona — good enough that most users skip the text box
    /// (plan §5.4). It states the one thing a workspace member most needs to know:
    /// where this agent runs.
    public static let defaultSystemPrompt = """
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
    public init(from decoder: any Decoder) throws {
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
    public var keychainAccount: String { Self.keychainAccount(id: id) }
    public static func keychainAccount(id: String) -> String { "buzzagent.\(id)" }

    /// Short, human-readable relay label for the status row (`auston.communities.buzz.xyz`).
    public var relayHost: String { URL(string: relayURL)?.host ?? relayURL }
}

/// Everything that can be wrong with a connection before it may run. Surfaced in
/// the wizard as sentences, and re-checked at start (a hand-edited file must not

public enum BuzzConnectionProblem: Equatable {
    case missingDisplayName
    case invalidRelay(String)
    case noChannels
    case invalidChannel(String)
    case disclosureNotAcknowledged
    case missingAgentKey

    public var message: String {
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
            return "This connection has no agent key in the keystore — remove it and reconnect."
        }
    }
}

/// The durable half of WS-I7: the connection file + the agent keys behind it.

/// The connections file + the agent keys behind it. Stateless: every call reads the
/// file, so the GUI and huginn-cli never disagree.
public struct BuzzConnectionStore: Sendable {
    public let path: String
    private let secrets: any SecretStore
    private let random: any RandomSource

    public init(path: String, secrets: any SecretStore, random: any RandomSource = SystemRandomSource()) {
        self.path = path
        self.secrets = secrets
        self.random = random
    }

    private struct File: Codable { var connections: [BuzzConnection] }

    public enum StoreError: Error, Equatable {
        case keyGeneration(String)
        case attestation(String)
        case writeFailed
        case notFound

        public var message: String {
            switch self {
            case .keyGeneration(let why): return "Couldn't create the agent's key: \(why)"
            case .attestation(let why): return "Owner attestation failed: \(why)"
            case .writeFailed: return "Couldn't write the connections file."
            case .notFound: return "No such connection."
            }
        }
    }

    public func load() -> [BuzzConnection] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: path),
            let file = try? dec.decode(File.self, from: data)
        else { return [] }
        return file.connections
    }

    private func persist(_ list: [BuzzConnection]) throws(StoreError) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(File(connections: list))
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch { throw .writeFailed }
    }

    public func connection(id: String) -> BuzzConnection? { load().first { $0.id == id } }

    /// Mint the agent key, optionally attest it with the owner key (used once, in
    /// memory, never stored), keep the private half in the keystore, save the record.
    @discardableResult
    public func create(_ draft: BuzzConnection, ownerPrivateKey: String?) throws(StoreError) -> BuzzConnection {
        var c = draft
        let kp: NostrKeypair
        do { kp = try NostrKeypair(randomSource: random) } catch { throw .keyGeneration("\(error)") }
        c.agentPubkeyHex = kp.publicKeyHex
        if let owner = ownerPrivateKey, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let a = try Self.attest(ownerPrivateKey: owner, agentPublicKeyHex: kp.publicKeyHex, random: random)
            c.ownerPubkeyHex = a.ownerPubkeyHex
            c.authTagJSON = a.authTagJSON
        }
        do { try secrets.save(Data(kp.privateKeyData.hexString.utf8), account: c.keychainAccount) }
        catch { throw .keyGeneration("the keystore refused the item (\(error))") }
        var list = load()
        list.append(c)
        do { try persist(list) } catch {
            secrets.delete(account: c.keychainAccount)
            throw error
        }
        return c
    }

    public func update(_ c: BuzzConnection) throws(StoreError) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == c.id }) else { throw .notFound }
        list[i] = c
        try persist(list)
    }

    public func remove(id: String) throws(StoreError) {
        secrets.delete(account: BuzzConnection.keychainAccount(id: id))
        try persist(load().filter { $0.id != id })
    }

    @discardableResult
    public func rotateKey(id: String, ownerPrivateKey: String?) throws(StoreError) -> BuzzConnection {
        guard var c = connection(id: id) else { throw .notFound }
        let kp: NostrKeypair
        do { kp = try NostrKeypair(randomSource: random) } catch { throw .keyGeneration("\(error)") }
        if let owner = ownerPrivateKey, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let a = try Self.attest(ownerPrivateKey: owner, agentPublicKeyHex: kp.publicKeyHex, random: random)
            c.ownerPubkeyHex = a.ownerPubkeyHex
            c.authTagJSON = a.authTagJSON
        } else {
            c.authTagJSON = nil  // a stale tag names the OLD key
        }
        c.agentPubkeyHex = kp.publicKeyHex
        do { try secrets.save(Data(kp.privateKeyData.hexString.utf8), account: c.keychainAccount) }
        catch { throw .keyGeneration("the keystore refused the item (\(error))") }
        try update(c)
        return c
    }

    @discardableResult
    public func applyAttestation(_ tagJSON: String, id: String) throws(StoreError) -> BuzzConnection {
        guard var c = connection(id: id) else { throw .notFound }
        let trimmed = tagJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner: String
        do { owner = try NIPOA.verifyAuthTag(trimmed, agentPublicKeyHex: c.agentPubkeyHex) } catch {
            throw .attestation("that tag doesn't authorize THIS agent key (\(c.agentPubkeyHex.prefix(12))…).")
        }
        c.authTagJSON = trimmed
        c.ownerPubkeyHex = owner
        try update(c)
        return c
    }

    public func agentPrivateKeyHex(id: String) -> String? {
        secrets.load(account: BuzzConnection.keychainAccount(id: id)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func hasAgentKey(id: String) -> Bool { agentPrivateKeyHex(id: id) != nil }

    public struct Attestation: Equatable, Sendable {
        public let ownerPubkeyHex: String
        public let authTagJSON: String
    }

    public static func attest(
        ownerPrivateKey: String, agentPublicKeyHex: String, conditions: String = "",
        random: any RandomSource = SystemRandomSource()
    ) throws(StoreError) -> Attestation {
        guard let ownerKey = BuzzKeys.parse(ownerPrivateKey) else {
            throw .attestation("that isn't an owner key — paste the workspace owner's nsec1… or 64-hex key.")
        }
        do {
            let tag = try NIPOA.computeAuthTag(
                ownerPrivateKey: ownerKey.privateKeyData, agentPublicKeyHex: agentPublicKeyHex,
                conditions: conditions, randomSource: random)
            let owner = try NIPOA.verifyAuthTag(tag, agentPublicKeyHex: agentPublicKeyHex)
            return Attestation(ownerPubkeyHex: owner, authTagJSON: tag)
        } catch {
            throw .attestation("\(error)")
        }
    }

    public static func problems(with c: BuzzConnection, hasKey: Bool) -> [BuzzConnectionProblem] {
        var p: [BuzzConnectionProblem] = []
        if c.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.append(.missingDisplayName) }
        if case .failure(let why) = RelayURL.validate(c.relayURL) { p.append(.invalidRelay(why.message)) }
        if c.channelIds.isEmpty { p.append(.noChannels) }
        for ch in c.channelIds where !isChannelID(ch) { p.append(.invalidChannel(ch)) }
        if !c.disclosureAcknowledged { p.append(.disclosureNotAcknowledged) }
        if !hasKey || c.agentPubkeyHex.count != 64 { p.append(.missingAgentKey) }
        return p
    }

    public static func isChannelID(_ v: String) -> Bool {
        UUID(uuidString: v.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    public static func parseChannelList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// The child's environment (Mac `BuzzGatewayService.environment`, verbatim rules):
    /// agent key via env only, owner private key stripped, fake-LLM flag stripped.
    public static func environment(
        for c: BuzzConnection, agentPrivateKeyHex: String, llmURL: String, llmModel: String,
        llmToken: String, base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["BUZZ_RELAY_URL"] = c.relayURL
        env["BUZZ_PRIVATE_KEY"] = agentPrivateKeyHex
        if let t = c.authTagJSON, !t.isEmpty { env["BUZZ_AUTH_TAG"] = t } else { env.removeValue(forKey: "BUZZ_AUTH_TAG") }
        env["ELDR_BUZZ_CHANNELS"] = c.channelIds.joined(separator: ",")
        env["ELDR_BUZZ_DISPLAY_NAME"] = c.displayName
        env["ELDR_BUZZ_ABOUT"] = c.about
        if c.pictureURL.isEmpty { env.removeValue(forKey: "ELDR_BUZZ_PICTURE") } else { env["ELDR_BUZZ_PICTURE"] = c.pictureURL }
        env["ELDR_BUZZ_SYSTEM_PROMPT"] = c.systemPrompt
        if let o = c.ownerPubkeyHex, !o.isEmpty { env["ELDR_BUZZ_OWNER_PUBKEY"] = o } else { env.removeValue(forKey: "ELDR_BUZZ_OWNER_PUBKEY") }
        env["ELDR_BUZZ_MENTIONS_ONLY"] = c.respondToMentionsOnly ? "1" : "0"
        env["ELDR_BUZZ_REDACT"] = c.redactOutbound ? "1" : "0"
        env.removeValue(forKey: "ELDR_BUZZ_OWNER_PRIVATE_KEY")
        env["ELDR_LLM_URL"] = c.providerURL.isEmpty ? llmURL : c.providerURL
        env["ELDR_LLM_MODEL"] = c.model.isEmpty ? llmModel : c.model
        if llmToken.isEmpty { env.removeValue(forKey: "ELDR_LLM_TOKEN") } else { env["ELDR_LLM_TOKEN"] = llmToken }
        env.removeValue(forKey: "ELDR_ACP_FAKE_LLM")
        return env
    }
}

public enum BuzzKeys {
    /// nsec1… or 64-hex private key → keypair.
    public static func parse(_ raw: String) -> NostrKeypair? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("nsec1") {
            guard let (hrp, data) = Bech32.decode(t), hrp == "nsec", data.count == 32 else { return nil }
            return try? NostrKeypair(privateKey: data)
        }
        guard let data = Data(hexString: t), data.count == 32 else { return nil }
        return try? NostrKeypair(privateKey: data)
    }
}
