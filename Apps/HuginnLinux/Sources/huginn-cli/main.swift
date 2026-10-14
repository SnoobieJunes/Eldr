// SPDX-License-Identifier: AGPL-3.0-only
// huginn-cli — headless Huginn for Linux (WS-N10). Also the secret helper the
// eldr-acp-launch launcher calls (`huginn-cli secret llm-token|metadata-key`).
import Foundation
import HuginnCore
import PQRCACP
import PQRCNostr

let paths = HuginnPaths.standard()
var args = Array(CommandLine.arguments.dropFirst())

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func die(_ s: String, _ code: Int32 = 1) -> Never { err("huginn-cli: " + s); exit(code) }
@MainActor func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func secrets() -> any SecretStore {
    do { return try HuginnSecrets.open(paths: paths).store } catch {
        die("cannot open Huginn's keystore (\(error)). Set HUGINN_PASSPHRASE_FILE or run under systemd-creds.")
    }
}
func token(_ s: any SecretStore) -> String { HuginnSecrets.string(s, HuginnSecrets.llmTokenAccount) ?? "" }

let usage = """
    usage: huginn-cli <command>
      status                         paths, install state, endpoint health
      config [KEY=VALUE ...]         show (or set) Configuration fields; writes the env file
      set-token                      read the LLM token from stdin into the keystore
      secret llm-token|metadata-key  print a secret (launcher use)
      install [--from DIR ...]       install eldr-acp (+helpers) into ~/.local/bin and write the launcher
      uninstall                      remove what install put in ~/.local/bin
      health                         GET <llm>/models
      chat [--fake] [--auto-approve] TEXT   one Test Chat turn against the real agent
      logs [-n N]                    last N agent log lines, classified
      learn                          ingest events.jsonl once and list project memory
      register acpx|zed|gateway [PATH]  register the launcher with an ACP client
      relay-script --domain D --pubkey HEX [--port P] [--tls cloudflare|letsEncrypt|none]
      world                          the node's town status (read-only)
      buzz list | buzz add --relay URL --channel UUID [--name N] [--owner-key K] --ack | buzz remove ID
      buzz run ID                    run one Buzz gateway in the foreground (Ctrl-C stops it)
      bridge show | bridge set --owner HEX [--relay URL] [--workdir D] [--responder R]
      bridge run                     run eldr-node in the foreground (Ctrl-C stops it)
    """

guard let cmd = args.first else { print(usage); exit(2) }
args.removeFirst()

actor StopFlag {
    private(set) var stopped = false
    func set() { stopped = true }
}
nonisolated(unsafe) var signalSources: [any DispatchSourceSignal] = []

/// Run a supervised child until it exits or SIGINT/SIGTERM arrives, then stop it — the
/// child is never left running.
func runForeground(id: String, executable: String, arguments: [String], env: [String: String], log: String, workdir: String? = nil) async {
    let sup = ChildSupervisor()
    let st = await sup.start(id: id, executable: executable, arguments: arguments, environment: env, logPath: log, workingDirectory: workdir)
    print("\(id): \(st.label) — log \(log)")
    guard st.isRunning else { exit(1) }
    let flag = StopFlag()
    for s in [SIGINT, SIGTERM] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .global())
        src.setEventHandler { Task { await flag.set() } }
        src.resume()
        signalSources.append(src)
    }
    let tail = LogTailer(path: log, startAtEnd: true)
    while await sup.state(id).isRunning, !(await flag.stopped) {
        for l in await tail.poll() { print(l.text) }
        try? await Task.sleep(for: .milliseconds(300))
    }
    await sup.stopAll()
    for l in await tail.poll() { print(l.text) }
    print("\(id): \(await sup.state(id).label)")
}

func binary(_ name: String) -> String {
    let installed = (paths.binDir as NSString).appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: installed) { return installed }
    let here = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    return (here as NSString).appendingPathComponent(name)
}

switch cmd {
case "status":
    let s = HuginnSettings.load(paths: paths)
    print("config dir: \(paths.configDir)")
    print("bin dir:    \(paths.binDir)")
    print("installed:  \(HuginnInstaller(paths: paths).isInstalled ? "yes (\(paths.launcher))" : "no")")
    print("endpoint:   \(s.llmURL)  model=\(s.llmModel)")
    let tok = (try? HuginnSecrets.open(paths: paths)).map { token($0.store) } ?? ""
    print("health:     \(await LLMHealth.check(url: s.llmURL, token: tok).label)")
    print("acpx:       \(HarnessRegistration.isRegistered(target: .acpxGlobal) ? "registered" : "not registered")")
    print("zed:        \(HarnessRegistration.isRegistered(target: .zed) ? "registered" : "not registered")")

case "config":
    var s = HuginnSettings.load(paths: paths)
    if args.isEmpty {
        for (k, v) in s.envPairs(paths: paths) { print("\(k)=\(v)") }
        print("tools=\(s.tools.joined(separator: ","))")
        print("workdir=\(s.workdir)")
        exit(0)
    }
    for kv in args {
        guard let eq = kv.firstIndex(of: "=") else { die("expected KEY=VALUE, got \(kv)") }
        let k = String(kv[..<eq]), v = String(kv[kv.index(after: eq)...])
        switch k {
        case "url", "ELDR_LLM_URL": s.llmURL = v
        case "model", "ELDR_LLM_MODEL": s.llmModel = v
        case "tools": s.tools = v.split(separator: ",").map(String.init)
        case "workdir": s.workdir = v
        case "preamble": s.promptPreamble = v
        case "system-prompt": s.systemPrompt = v
        case "max-steps": s.maxAgentSteps = Int(v) ?? s.maxAgentSteps
        case "learning": s.learningEnabled = v == "1" || v == "on"
        case "ungated": s.allowUngatedTools = v == "1" || v == "on"
        default: die("unknown key \(k) (url, model, tools, workdir, preamble, system-prompt, max-steps, learning, ungated)")
        }
    }
    do { try s.save(paths: paths) } catch { die("\(error)") }
    print("saved \(paths.envFile)")

case "set-token":
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let t = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let s = secrets()
    do {
        if t.isEmpty { s.delete(account: HuginnSecrets.llmTokenAccount) }
        else { try s.save(Data(t.utf8), account: HuginnSecrets.llmTokenAccount) }
    } catch { die("keystore refused the token: \(error)") }
    print(t.isEmpty ? "token cleared" : "token saved")

case "secret":
    let s = secrets()
    switch args.first {
    case "llm-token": print(token(s))
    case "metadata-key":
        do { print(try HuginnSecrets.metadataKey(s).base64EncodedString()) } catch { die("\(error)") }
    default: die("secret llm-token|metadata-key", 2)
    }

case "install":
    var dirs: [String] = []
    while let d = option("--from") { dirs.append(d) }
    if dirs.isEmpty { dirs = [(CommandLine.arguments[0] as NSString).deletingLastPathComponent] }
    do {
        let r = try HuginnInstaller(paths: paths).install(from: dirs)
        print("installed \(r.installed.joined(separator: ", ")) into \(paths.binDir)")
        print("launcher: \(r.launcher)")
    } catch { die("\(error)") }

case "uninstall":
    HuginnInstaller(paths: paths).uninstall()
    print("removed Huginn's binaries and launcher from \(paths.binDir)")

case "health":
    let s = HuginnSettings.load(paths: paths)
    let tok = (try? HuginnSecrets.open(paths: paths)).map { token($0.store) } ?? ""
    let r = await LLMHealth.check(url: s.llmURL, token: tok)
    print(r.label)
    if case .healthy(let m) = r { m.forEach { print("  \($0)") } }
    exit(r.isHealthy ? 0 : 1)

case "chat":
    let fake = flag("--fake"), auto = flag("--auto-approve")
    let text = args.joined(separator: " ")
    guard !text.isEmpty else { die("chat needs text", 2) }
    let s = HuginnSettings.load(paths: paths)
    let tok = fake ? "" : ((try? HuginnSecrets.open(paths: paths)).map { token($0.store) } ?? "")
    var agentCfg = s.agentConfig(paths: paths)
    agentCfg.eventsFilePath = nil  // like the GUI: Test Chat never teaches project memory
    if !auto { agentCfg.permissionTimeoutSeconds = 1 }  // headless: nobody can click Approve
    let session = TestChatSession(options: .init(
        llm: s.llmConfig(token: tok), agent: agentCfg, workdir: s.workdir, autoApprove: auto, useFakeLLM: fake))
    await session.send(text)
    try? await Task.sleep(for: .milliseconds(200))
    for item in await session.items {
        switch item.role {
        case .user: print("you: \(item.text)")
        case .assistant: print("agent: \(item.text)")
        case .toolCall: print("  ⚙ \(item.text) \(item.argsJSON ?? "")")
        case .toolResult: print("  \(item.isError ? "✗" : "→") \(item.text.prefix(400))")
        case .approvalNote: print("  · \(item.text)")
        }
    }
    print("workdir: \(await session.workdir)")

case "logs":
    let n = Int(option("-n") ?? "40") ?? 40
    let t = LogTailer(path: paths.logFile, capacity: n)
    await t.poll()
    for l in await t.lines { print("[\(l.kind.rawValue)] \(l.text)") }

case "learn":
    // Require the key: sealed events read without it would be skipped AND the offset would
    // move past them, losing that learning for good.
    let key: Data
    do { key = try HuginnSecrets.metadataKey(secrets()) } catch { die("no metadata key: \(error)") }
    let l = ContextLearner(paths: paths, metadataKey: key)
    await l.poll()
    let ps = await l.projects()
    if ps.isEmpty { print("no project memory yet") }
    for p in ps {
        print(p.cwd)
        for line in (await l.memoryText(p)).split(separator: "\n") { print("  \(line)") }
    }

case "register":
    let launcher = paths.launcher
    let target: HarnessRegistration.Target
    switch args.first {
    case "acpx": target = .acpxGlobal
    case "zed": target = .zed
    case "gateway":
        guard args.count > 1 else { die("register gateway PATH", 2) }
        target = .gateway(path: args[1])
    default: die("register acpx|zed|gateway PATH", 2)
    }
    do {
        let plan = try HarnessRegistration.plan(target: target, launcherPath: launcher)
        print(try HarnessRegistration.apply(plan, gatewayRunning: false))
    } catch {
        err((error as? HarnessRegistration.RegError)?.message ?? "\(error)")
        if target == .zed { print(HarnessRegistration.zedSnippet(launcherPath: launcher)) }
        exit(1)
    }

case "relay-script":
    var cfg = RelayProvisioner.Config()
    cfg.domain = option("--domain") ?? ""
    cfg.httpPort = Int(option("--port") ?? "7777") ?? 7777
    if let t = option("--tls"), let m = RelayProvisioner.TLSMode(rawValue: t) { cfg.tlsMode = m }
    while let k = option("--pubkey") { cfg.allowedPubkeys.append(k) }
    let p = RelayProvisioner(config: cfg)
    guard let script = p.installScriptIfValid() else {
        p.validate().forEach { err("✗ \($0.message)") }
        exit(1)
    }
    print(script)

case "world":
    do {
        let w = try await WorldStatusClient.fetch(paths: paths)
        print("node town \(w.nodeTownID) · agent \(w.localAgentID) · dropped \(w.droppedInboundCount)")
        for t in w.towns { print("  \(t.label) [\(t.townID.prefix(12))] wall=\(t.wallGranted) delegate=\(t.delegateGranted)") }
        if w.towns.isEmpty { print("  no towns authorized yet") }
    } catch { die(error.message) }

case "buzz":
    let store = BuzzConnectionStore(path: paths.buzzConnectionsFile, secrets: secrets())
    switch args.first {
    case "list", nil:
        let list = store.load()
        if list.isEmpty { print("no Buzz connections") }
        for c in list {
            let probs = BuzzConnectionStore.problems(with: c, hasKey: store.hasAgentKey(id: c.id))
            print("\(c.id)  \(c.displayName) @ \(c.relayHost)  channels=\(c.channelIds.count)  agent=\(c.agentPubkeyHex.prefix(12))…  \(probs.isEmpty ? "ready" : probs.map(\.message).joined(separator: "; "))")
        }
    case "add":
        args.removeFirst()
        var c = BuzzConnection()
        c.relayURL = option("--relay") ?? ""
        while let ch = option("--channel") { c.channelIds += BuzzConnectionStore.parseChannelList(ch) }
        if let n = option("--name") { c.displayName = n }
        let ownerKey = option("--owner-key")
        c.disclosureAcknowledged = flag("--ack")
        do {
            let made = try store.create(c, ownerPrivateKey: ownerKey)
            print("created \(made.id) agent=\(made.agentPubkeyHex)")
            let p = BuzzConnectionStore.problems(with: made, hasKey: true)
            p.forEach { print("  ! \($0.message)") }
        } catch { die(error.message) }
    case "remove":
        guard args.count > 1 else { die("buzz remove ID", 2) }
        do { try store.remove(id: args[1]); print("removed") } catch { die(error.message) }
    case "run":
        guard args.count > 1, let c = store.connection(id: args[1]) else { die("buzz run ID (see buzz list)", 2) }
        let probs = BuzzConnectionStore.problems(with: c, hasKey: store.hasAgentKey(id: c.id))
        guard probs.isEmpty else { die(probs.map(\.message).joined(separator: "; ")) }
        guard let key = store.agentPrivateKeyHex(id: c.id) else { die("no agent key") }
        let s = HuginnSettings.load(paths: paths)
        let env = BuzzConnectionStore.environment(for: c, agentPrivateKeyHex: key, llmURL: s.llmURL, llmModel: s.llmModel, llmToken: token(secrets()))
        let cmd = BridgeSettings.lineBuffered(binary("eldr-buzz-agent"), [])
        await runForeground(id: "buzz-\(c.id)", executable: cmd.executable, arguments: cmd.arguments, env: env, log: paths.buzzLogFile(connectionID: c.id))
    default: die("buzz list|add|remove|run", 2)
    }

case "bridge":
    var b = BridgeSettings.load(paths)
    switch args.first {
    case "show", nil:
        print("owner=\(b.ownerHex) relay=\(b.relayURL) workdir=\(b.workdir) responder=\(b.responder)")
        b.problems.forEach { print("  ! \($0.message)") }
    case "set":
        args.removeFirst()
        if let o = option("--owner") { b.ownerHex = o }
        if let r = option("--relay") { b.relayURL = r }
        if let w = option("--workdir") { b.workdir = w }
        if let r = option("--responder") { b.responder = r }
        guard b.save(paths) else { die("could not write \(paths.bridgeFile)") }
        print("saved"); b.problems.forEach { print("  ! \($0.message)") }
    case "run":
        guard b.problems.isEmpty else { die(b.problems.map(\.message).joined(separator: "; ")) }
        let s = HuginnSettings.load(paths: paths)
        var env = ProcessInfo.processInfo.environment
        env["ELDR_LLM_URL"] = s.llmURL
        env["ELDR_LLM_MODEL"] = s.llmModel
        let cmd = BridgeSettings.lineBuffered(binary("eldr-node"), b.arguments())
        await runForeground(id: "eldr-node", executable: cmd.executable, arguments: cmd.arguments, env: env, log: paths.nodeLogFile, workdir: b.workdir.isEmpty ? nil : b.workdir)
    default: die("bridge show|set|run", 2)
    }

default:
    print(usage)
    exit(2)
}
