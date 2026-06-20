import Crypto
import EldrNodeCore
import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr

/// `eldr-node` — the STANDALONE HEADLESS node (ACPRouterplan Phase 4: "run the host on
/// another machine"). It loads/creates the node's PQRC identity from the macOS Keychain,
/// connects to the Nostr relay, stands up a `PQRCMessenger`, and serves the FULL ACP
/// agent to ITS OWNER's phone over the relay — owner-gated by the C-3 gate inside
/// `EldrNodeCore`.
///
/// Usage:
///   eldr-node --owner <phone-identity-hex> [--relay <wss url>] [--workdir <path>]
///
///   --owner    REQUIRED: the phone's PQRC identity hex (the C-3 gate target). Absent ⇒
///              the node FAILS CLOSED and exits (no owner ⇒ no one may drive the agent).
///   --relay    the relay WebSocket URL. Default: env `PQRC_RELAY_URL`, else
///              `wss://relay.lerants.com`. MUST match the phone's relay.
///   --workdir  the C-2 jail root the agent's file tools operate in. Default: the
///              process cwd. Real file/build tasks need a real project dir here.
///
/// Model config is read from the environment by `LLMConfig.fromEnvironment`
/// (`ELDR_LLM_URL` / `ELDR_LLM_TOKEN` / `ELDR_LLM_MODEL` / `ELDR_LLM_TIMEOUT_SECONDS`),
/// the same knobs the Configurator's relay host and the `eldr-acp` launcher use.
///
/// The process prints only NON-SENSITIVE status (relay url, owner hex PREFIX, workdir,
/// node identity hex PREFIX) — NEVER secrets, key bytes, or payloads (CLAUDE.md inv. 10,
/// 12). It parks forever (like `pqrc-relay`) and shuts down cleanly on SIGINT.
@main
struct EldrNodeMain {
    static func main() async {
        let arguments = parse(CommandLine.arguments)

        // --owner is REQUIRED. Fail closed if absent: a node with no pinned owner has no
        // C-3 gate target, so it must not serve anyone.
        guard let ownerIdentityHex = arguments["owner"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !ownerIdentityHex.isEmpty
        else {
            FileHandle.standardError.write(Data(
                ("eldr-node: --owner <phone-identity-hex> is REQUIRED "
                    + "(the C-3 gate target). Refusing to serve with no owner.\n").utf8))
            exit(2)
        }

        let env = ProcessInfo.processInfo.environment
        let relayURL =
            arguments["relay"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? env["PQRC_RELAY_URL"]?.nonEmpty
            ?? "wss://relay.lerants.com"
        let workdir =
            arguments["workdir"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? FileManager.default.currentDirectoryPath

        guard let relayWSURL = URL(string: relayURL) else {
            FileHandle.standardError.write(Data("eldr-node: invalid --relay URL: \(relayURL)\n".utf8))
            exit(2)
        }

        do {
            // Load/create the node identity from the Keychain (inv. 10 access rules; key
            // bytes never logged). Each secret is independent so a partial prior run still
            // resolves the rest.
            let keychain = NodeKeychain()
            let nostrKeypair = try loadOrCreateNostrKeypair(keychain)
            let identity = try loadOrCreatePQRCIdentity(keychain)
            let identityDH = try loadOrCreateIdentityDH(keychain)
            let prekeyManager = try await loadOrCreatePrekeyManager(keychain, identity: identity)

            let transport = await NostrWebSocketTransport(url: relayWSURL).connect()
            let messenger = try PQRCMessenger(
                identity: identity, nostrKeypair: nostrKeypair, prekeyManager: prekeyManager,
                identityDH: identityDH, transports: [transport], clock: SystemClock(),
                randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())

            // Model: read from the environment (same knobs as the Configurator/launcher).
            let llmConfig = LLMConfig.fromEnvironment(env)
            let llm = OpenAICompatibleLLMClient(config: llmConfig)
            let toolEnvironment = ToolEnvironment(workdir: workdir, baseEnvironment: env)

            // Status only — never secrets/payloads (inv. 10, 12). `identityHex` is a
            // PUBLIC key derived from the (actor-isolated) identity; awaited, prefix only.
            let nodeIdentityHex = await messenger.identityHex
            print("eldr-node — Phase 4 standalone node")
            print("  relay:    \(relayURL)")
            print("  owner:    \(hexPrefix(ownerIdentityHex)) (C-3 gate target)")
            print("  node id:  \(hexPrefix(nodeIdentityHex))")
            print("  workdir:  \(workdir) (C-2 jail)")
            print("  model:    \(llmConfig.url) [\(llmConfig.model)]")
            print("  Publishing keys + serving the owner over the relay. Stop with Ctrl-C.")

            // Publish our keys (10420/10421/10050) so the owner's phone can fetch + verify
            // us and start the encrypted session. Best-effort, bounded attempts: a down
            // relay logs a few lines, it does not block serving.
            do {
                try await messenger.announce(relayURLs: [relayURL], maxAttempts: 6)
                print("  keys published.")
            } catch {
                FileHandle.standardError.write(Data(
                    "eldr-node: key publish failed (will still serve if peers already have our keys)\n".utf8))
            }

            // Clean SIGINT shutdown: cancel the serve task so the transport closes and the
            // agent loop unwinds, then exit. `signal(SIGINT, SIG_IGN)` + a DispatchSource
            // is the cooperative pattern (a bare handler can't touch Swift concurrency).
            let serveTask = Task {
                let node = EldrNodeCore()
                await node.serve(
                    messenger: PQRCNodeMessenger(messenger: messenger),
                    ownerIdentityHex: ownerIdentityHex,
                    maxFrameBytes: relayACPMaxFrameBytes,
                    llm: llm,
                    toolEnvironment: toolEnvironment,
                    config: .default,
                    streamingEnabled: false)
            }

            signal(SIGINT, SIG_IGN)
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigint.setEventHandler {
                print("\neldr-node: shutting down…")
                serveTask.cancel()
                Task {
                    await messenger.stop()
                    exit(0)
                }
            }
            sigint.resume()

            // `serve` only returns if the messenger stream finishes; park otherwise so the
            // process stays up serving the owner (mirrors `pqrc-relay`'s park loop).
            await serveTask.value
            await messenger.stop()
        } catch {
            FileHandle.standardError.write(Data("eldr-node: startup failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The relay's per-message byte budget for framing/chunking ACP lines: the relay's
    /// event-size cap minus gift-wrap overhead. 16 KiB matches the proven e2e budget and
    /// the Configurator's `relayACPMaxFrameBytes`, staying well under a strict 65 535-byte
    /// relay even after wrapping.
    static let relayACPMaxFrameBytes = 16 * 1024

    // MARK: - Identity load-or-create (macOS Keychain; key bytes never logged)

    private static func loadOrCreateNostrKeypair(_ keychain: NodeKeychain) throws -> NostrKeypair {
        if let data = keychain.load(account: "node-nostr-key") {
            return try NostrKeypair(privateKey: data)
        }
        let keypair = try NostrKeypair(randomSource: SystemRandomSource())
        try keychain.save(keypair.privateKeyData, account: "node-nostr-key")
        return keypair
    }

    private static func loadOrCreatePQRCIdentity(_ keychain: NodeKeychain) throws -> PQRCIdentity {
        if let seed = keychain.load(account: "node-pqrc-identity-seed") {
            return try PQRCIdentity(seed: seed)
        }
        let identity = try PQRCIdentity(randomSource: SystemRandomSource())
        try keychain.save(identity.privateKey.rawRepresentation, account: "node-pqrc-identity-seed")
        return identity
    }

    private static func loadOrCreateIdentityDH(
        _ keychain: NodeKeychain
    ) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let seed = keychain.load(account: "node-identity-dh") {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
        }
        let dh = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: SystemRandomSource().bytes(32))
        try keychain.save(dh.rawRepresentation, account: "node-identity-dh")
        return dh
    }

    private static func loadOrCreatePrekeyManager(
        _ keychain: NodeKeychain, identity: PQRCIdentity
    ) async throws -> PrekeyManager {
        let manager: PrekeyManager
        if let blob = keychain.load(account: "node-prekey-state"),
            let state = try? JSONDecoder().decode(PrekeyState.self, from: blob)
        {
            manager = try PrekeyManager(
                identity: identity, randomSource: SystemRandomSource(), state: state)
        } else {
            manager = try PrekeyManager(
                identity: identity, randomSource: SystemRandomSource(), oneTimeCount: 16)
        }
        _ = try await manager.replenish(to: 16)
        // `snapshot()` is a fresh copy of the private halves (every field
        // deep-copied); the live actor state is untouched. Wipe the transient
        // plaintext once the encrypted blob has been handed to the Keychain
        // (AC40).
        var state = await manager.snapshot()
        defer { state.zeroize() }
        try keychain.save(JSONEncoder().encode(state), account: "node-prekey-state")
        return manager
    }

    // MARK: - Non-sensitive status helpers

    /// A short, non-identifying prefix of a hex id for status output — never the full
    /// key. (`identityHex` is a PUBLIC key, but we still only print a prefix so logs stay
    /// terse and consistent with inv. 12's "no payload-adjacent value in full".)
    private static func hexPrefix(_ hex: String) -> String {
        hex.count > 12 ? "\(hex.prefix(8))…\(hex.suffix(4))" : hex
    }

    /// Tiny `--flag value` parser — no ArgumentParser dependency, matching `pqrc-relay`
    /// (CLAUDE.md: no dependencies beyond the pinned set).
    private static func parse(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 1
        while index + 1 < arguments.count {
            if arguments[index].hasPrefix("--") {
                result[String(arguments[index].dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }
}

private extension String {
    /// nil when empty/whitespace-only, else self — for "use this arg if it was actually
    /// provided" defaulting chains.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
