// SPDX-License-Identifier: Apache-2.0
import Crypto
import EldrNodeCore
import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr
#if canImport(os)
import os
#endif

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
///   --responder  who answers: `sybilclaw` (default), `eldr-acp`, or a `HarnessRegistry`
///              id (`claude-code`, `gemini-cli`, …) to spawn that external cloud CLI as
///              a `.stdioSpawn` harness (WS3c). Its vendor key comes from the Keychain
///              (`--import-vendor-key`), never argv/env.
///   --import-vendor-key <harness-id>  seed that harness's vendor API key from STDIN
///              into the node Keychain, then exit (mirrors `--import-token`).
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
        let rawArguments = CommandLine.arguments
        let arguments = parse(rawArguments)

        // Mode: seed the LLM token into the node Keychain from STDIN, then exit. The token
        // is read from stdin only — never argv (it'd show in `ps`), the env file (C-8), or
        // shell history. This is how the SSH installer provisions the token headlessly.
        if rawArguments.contains("--import-token") {
            await importTokenMode()
            return
        }

        // WS3b: seed a cloud-CLI harness's vendor key (`--import-vendor-key claude-code`)
        // into the node Keychain from STDIN, same discipline as `--import-token` — never
        // argv/env file/shell history.
        if let harnessID = arguments["import-vendor-key"]?.nonEmpty {
            await importVendorKeyMode(harnessID: harnessID)
            return
        }

        // Mode: print the `pqrc:add?npub=…&type=coding_agent` pairing link the phone scans,
        // then exit. Loads-or-creates the node identity (idempotent; same npub the daemon
        // serves under), so the installer can emit the link without the GUI.
        if rawArguments.contains("--print-pairing-link") {
            printPairingLinkMode(arguments)
            return
        }

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
            let keychain = try makeIdentityStore()
            let nostrKeypair = try loadOrCreateNostrKeypair(keychain)
            let identity = try loadOrCreatePQRCIdentity(keychain)
            let identityDH = try loadOrCreateIdentityDH(keychain)
            let prekeyManager = try await loadOrCreatePrekeyManager(keychain, identity: identity)

            let transport: any RelayTransport
            #if canImport(Network)
            transport = await NostrWebSocketTransport(url: relayWSURL).connect()
            #else
            // Linux: URLSessionWebSocketTask can't connect ("WebSockets not supported by
            // libcurl"), so dial the relay over SwiftNIO instead (WS-L5).
            transport = try await NIONostrTransport(url: relayWSURL).connect()
            #endif
            let messenger = try PQRCMessenger(
                identity: identity, nostrKeypair: nostrKeypair, prekeyManager: prekeyManager,
                identityDH: identityDH, transports: [transport], clock: SystemClock(),
                randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())

            // Model: read from the environment (same knobs as the Configurator/launcher).
            // C-8: if no ELDR_LLM_TOKEN is in the environment, fall back to the Keychain copy
            // seeded by `--import-token` — never the env file.
            var llmEnv = env
            if llmEnv["ELDR_LLM_TOKEN"]?.nonEmpty == nil,
                let stored = keychain.load(account: tokenAccount),
                let token = String(data: stored, encoding: .utf8)?.nonEmpty
            {
                llmEnv["ELDR_LLM_TOKEN"] = token
            }
            let llmConfig = LLMConfig.fromEnvironment(llmEnv)
            let toolEnvironment = ToolEnvironment(workdir: workdir, baseEnvironment: env)

            // Responder: who answers the owner's chats. `sybilclaw` (default) routes the turn
            // to the user's OWN assistant over its local Gateway (their "current agent");
            // `eldr-acp` uses the node's own local LLM tool loop (the proven path). The
            // sybilclaw path reuses the same ACP plumbing via an LLMClient adapter.
            // WS3c: `--responder claude-code`/`gemini-cli` instead spawn that cloud CLI as
            // an EXTERNAL `.stdioSpawn` harness (`HarnessRegistry`) — `llm` below is then
            // unused (the CLI brings its own model); its vendor key comes from the node
            // Keychain (`--import-vendor-key`), never argv/env file, and is merged into
            // the descriptor's `env` ONLY (never the general node env `toolEnvironment`
            // wraps — see `HarnessDescriptor.withVendorKey`).
            let responder = arguments["responder"]?.nonEmpty?.lowercased() ?? "sybilclaw"
            let gatewayPort = arguments["gateway-port"]?.nonEmpty.flatMap { Int($0) } ?? 18789
            // Only a `.stdioSpawn` registry hit is an EXTERNAL cloud harness. "eldr-acp"
            // is in the registry too — as `.builtIn` — and must keep taking the built-in
            // path below (status line and all), not the cloud-harness one.
            let registryHit = HarnessRegistry.descriptor(id: responder)
            let cloudHarness =
                (registryHit?.kind == .stdioSpawn || registryHit?.kind == .a2aRemote)
                ? registryHit : nil
            let useSybilclaw = cloudHarness == nil && !["eldr-acp", "eldracp", "acp"].contains(responder)
            let llm: any LLMClient =
                useSybilclaw
                ? SybilclawLLMClient(
                    gateway: SybilclawGatewayClient(
                        port: gatewayPort, token: env["SYBILCLAW_GATEWAY_TOKEN"],
                        userAgent: "eldr-node/0.1.0",
                        // WS-B5: no diagnostics UI on the headless node — fold the client's
                        // lifecycle events into the daemon's own OSLog stream (protocol/
                        // connection state only; the client never hands this payload text).
                        onEvent: { event in logGatewayEvent(event) }))
                : OpenAICompatibleLLMClient(config: llmConfig)
            let harnessDescriptor: HarnessDescriptor
            if let cloudHarness, cloudHarness.kind == .a2aRemote {
                let bearerToken = keychain.load(account: a2aBearerAccount(for: cloudHarness.id))
                    .flatMap { String(data: $0, encoding: .utf8) }
                harnessDescriptor = cloudHarness.withBearerToken(bearerToken)
            } else if let cloudHarness {
                let vendorKey = keychain.load(account: vendorKeyAccount(for: cloudHarness.id))
                    .flatMap { String(data: $0, encoding: .utf8) }
                harnessDescriptor = cloudHarness.withVendorKey(vendorKey)
            } else {
                harnessDescriptor = .builtIn
            }

            // Status only — never secrets/payloads (inv. 10, 12). `identityHex` is a
            // PUBLIC key derived from the (actor-isolated) identity; awaited, prefix only.
            let nodeIdentityHex = await messenger.identityHex
            print("eldr-node — Phase 4 standalone node")
            print("  relay:    \(relayURL)")
            print("  owner:    \(hexPrefix(ownerIdentityHex)) (C-3 gate target)")
            print("  node id:  \(hexPrefix(nodeIdentityHex))")
            print("  workdir:  \(workdir) (C-2 jail)")
            if let cloudHarness, cloudHarness.kind == .a2aRemote {
                let hasToken = harnessDescriptor.a2aBearerToken?.isEmpty == false
                print(
                    "  responder: \(cloudHarness.displayName) (A2A: \(cloudHarness.a2aCardURL ?? "?")) — bearer token \(hasToken ? "loaded" : "MISSING, import with --import-vendor-key \(cloudHarness.id)")"
                )
            } else if let cloudHarness {
                let hasKey = !(harnessDescriptor.env[cloudHarness.vendorKeyEnvVar ?? ""] ?? "").isEmpty
                print(
                    "  responder: \(cloudHarness.displayName) (\(cloudHarness.command)) — vendor key \(hasKey ? "loaded" : "MISSING, import with --import-vendor-key \(cloudHarness.id)")"
                )
            } else if useSybilclaw {
                print("  responder: sybilclaw assistant (local Gateway :\(gatewayPort))")
            } else {
                print("  responder: eldr-acp — \(llmConfig.url) [\(llmConfig.model)]")
            }
            print("  pairing:  \(pairingLink(npub: nostrKeypair.npub, relay: relayURL))")
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
                    streamingEnabled: false,
                    descriptor: harnessDescriptor)
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

    /// The Keychain account the LLM token is seeded into by `--import-token` and read back
    /// at serve time (C-8: the token lives in the Keychain, never the env file).
    static let tokenAccount = "node-llm-token"

    /// WS3b: the Keychain account a cloud-CLI harness's vendor key is seeded into by
    /// `--import-vendor-key <id>` and read back at serve time. One account per harness id
    /// so multiple vendor keys coexist independently.
    static func vendorKeyAccount(for harnessID: String) -> String {
        "node-vendor-key-\(harnessID)"
    }

    /// `.a2aRemote` counterpart to `vendorKeyAccount`: the Keychain account a harness's A2A
    /// bearer token is seeded into by `--import-vendor-key <id>` (same CLI flag — the mode
    /// picks the right account by looking up the descriptor's `kind`) and read back at serve
    /// time via `HarnessDescriptor.withBearerToken`.
    static func a2aBearerAccount(for harnessID: String) -> String {
        "node-a2a-bearer-\(harnessID)"
    }

    // MARK: - Headless provisioning modes (exit after running)

    /// Read the LLM token from STDIN and store it in the node Keychain. Never logs the
    /// token; reads stdin only (not argv/env). The SSH installer pipes the token here.
    private static func importTokenMode() async {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            FileHandle.standardError.write(Data(
                "eldr-node --import-token: empty token on stdin; nothing imported.\n".utf8))
            exit(2)
        }
        do {
            try makeIdentityStore().save(Data(token.utf8), account: tokenAccount)
            FileHandle.standardError.write(Data(
                "eldr-node: LLM token imported to the Keychain (account \(tokenAccount)).\n".utf8))
        } catch {
            FileHandle.standardError.write(Data(
                "eldr-node --import-token: Keychain write failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// WS3b: read a cloud-CLI harness's vendor key from STDIN and store it in the node
    /// Keychain under that harness's own account. Same discipline as `importTokenMode` —
    /// never argv/env file/shell history. `harnessID` should be a `HarnessRegistry` id
    /// (e.g. `claude-code`, `gemini-cli`); an unknown id still stores under its own
    /// account (harmless — `serve` just never resolves that descriptor at all).
    private static func importVendorKeyMode(harnessID: String) async {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let key = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            FileHandle.standardError.write(Data(
                "eldr-node --import-vendor-key \(harnessID): empty key on stdin; nothing imported.\n"
                    .utf8))
            exit(2)
        }
        // Route to the A2A bearer account when the id names an `.a2aRemote` descriptor, else
        // the vendor-key account (`.stdioSpawn`) — same CLI surface, correct storage either way.
        let account =
            HarnessRegistry.descriptor(id: harnessID)?.kind == .a2aRemote
            ? a2aBearerAccount(for: harnessID) : vendorKeyAccount(for: harnessID)
        do {
            try makeIdentityStore().save(Data(key.utf8), account: account)
            FileHandle.standardError.write(Data(
                "eldr-node: vendor key for \(harnessID) imported to the Keychain.\n".utf8))
        } catch {
            FileHandle.standardError.write(Data(
                "eldr-node --import-vendor-key \(harnessID): Keychain write failed: \(error)\n"
                    .utf8))
            exit(1)
        }
    }

    /// Print the `pqrc:add?npub=…&type=coding_agent` deep link the phone scans, then exit.
    /// Loads-or-creates the node's Nostr identity so the printed npub matches what the
    /// daemon serves under. `--relay` (or `PQRC_RELAY_URL`) rides along as a hint.
    private static func printPairingLinkMode(_ arguments: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        let relayURL =
            arguments["relay"]?.nonEmpty ?? env["PQRC_RELAY_URL"]?.nonEmpty
        do {
            let keypair = try loadOrCreateNostrKeypair(makeIdentityStore())
            print(pairingLink(npub: keypair.npub, relay: relayURL))
        } catch {
            FileHandle.standardError.write(Data(
                "eldr-node --print-pairing-link: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The deep link EldrChat's `handleDeepLink` parses (same shape as the Configurator's
    /// `ACPBridgeService.deepLink`): npub + the `coding_agent` type tag, plus an optional
    /// relay hint the app may use to suggest the matching relay.
    static func pairingLink(npub: String, relay: String?) -> String {
        var link = "pqrc:add?npub=\(npub)&type=coding_agent"
        if let relay, !relay.isEmpty,
            let encoded = relay.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        {
            link += "&relay=\(encoded)"
        }
        return link
    }

    // MARK: - Identity load-or-create (macOS Keychain; key bytes never logged)

    private static func loadOrCreateNostrKeypair(_ keychain: any IdentityStore) throws -> NostrKeypair {
        if let data = keychain.load(account: "node-nostr-key") {
            return try NostrKeypair(privateKey: data)
        }
        let keypair = try NostrKeypair(randomSource: SystemRandomSource())
        try keychain.save(keypair.privateKeyData, account: "node-nostr-key")
        return keypair
    }

    private static func loadOrCreatePQRCIdentity(_ keychain: any IdentityStore) throws -> PQRCIdentity {
        if let seed = keychain.load(account: "node-pqrc-identity-seed") {
            return try PQRCIdentity(seed: seed)
        }
        let identity = try PQRCIdentity(randomSource: SystemRandomSource())
        try keychain.save(identity.privateKey.rawRepresentation, account: "node-pqrc-identity-seed")
        return identity
    }

    private static func loadOrCreateIdentityDH(
        _ keychain: any IdentityStore
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
        _ keychain: any IdentityStore, identity: PQRCIdentity
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

    /// WS-B5: the sybilclaw gateway client's lifecycle events, one OSLog line each.
    /// `SybilclawGatewayEvent` carries no payload text by construction (invariant 12) —
    /// only protocol/connection state and short, non-payload error descriptions — so
    /// there's nothing to redact here.
    private static let gatewayLog = Logger(subsystem: "chat.eldr.eldr-node", category: "gateway")

    private static func logGatewayEvent(_ event: SybilclawGatewayEvent) {
        switch event {
        case .connecting(let host, let port):
            gatewayLog.debug("connecting → \(host, privacy: .public):\(port, privacy: .public)")
        case .connected:
            gatewayLog.debug("connected")
        case .disconnected(let reason):
            gatewayLog.notice("disconnected: \(reason ?? "-", privacy: .public)")
        case .turnStarted:
            gatewayLog.debug("turn started")
        case .turnSucceeded:
            gatewayLog.debug("turn succeeded")
        case .turnFailed(let reason):
            gatewayLog.error("turn failed: \(reason, privacy: .public)")
        }
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
