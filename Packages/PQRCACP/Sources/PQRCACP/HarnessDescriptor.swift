import Foundation

// Phase 1 item 3 + the "Scaffolds that make Phases 2–4 drop-in" section of
// docs/ACPRouterplan.md: a DATA-DRIVEN backend descriptor — "how to launch/connect each
// harness". The plan's whole thesis is that EldrChat is a universal ACP *router*: the node
// owns identity/E2EE/transport, and the actual coding is delegated to interchangeable ACP
// harnesses (built-in `eldr-acp`, Xcode ACP, OpenClaw, Claude Code, Codex, Gemini CLI,
// OpenCode, Cursor, …). A harness is selectable iff the node knows how to reach it, and
// that knowledge is exactly this descriptor. Adding a harness = appending one entry to
// `HarnessRegistry.all` — no architecture change (the Phase-2 drop-in seam).
//
// This type is platform-agnostic (it's just data) and stays iOS-available so the phone's
// router UI can list/select descriptors; the macOS-only `StdioHarnessTransport` is what
// actually spawns a `.stdioSpawn` descriptor's process on the node.

/// How a backend is reached.
public enum HarnessKind: Sendable, Equatable {
    /// The in-process reference harness: EldrChat's own ACP agent (`eldr-acp`/`ACPAgent`)
    /// driven by an injected `LLMClient` (bring-your-own-model). No subprocess — `runHarness`
    /// runs it via `runACPAgent(transport:llm:…)`, the unchanged Phase-1 built-in path.
    case builtIn
    /// An external ACP-speaking binary launched over stdio. `runHarness` spawns the
    /// descriptor's `command`+`args`+`env` as a `Process` (via `StdioHarnessTransport`) and
    /// pipes the phone's verified, decrypted ACP line-stream to/from its stdin/stdout with
    /// `runACPProxy`.
    case stdioSpawn
}

/// A data-only description of one selectable ACP backend. The `command`/`args`/`env` shape
/// matches the OpenClaw `acpx` plugin config (`OpenClawRegistration.swift`: each agent is
/// `{ "command": <path>, "args": [...] }`), so the same launch spec the Configurator writes
/// into a client's config is the spec the node spawns directly.
public struct HarnessDescriptor: Sendable, Equatable, Identifiable {
    /// Stable identifier used to select this backend (router persistence, logs, tests). Never
    /// localize — this is a key, not a label.
    public let id: String
    /// Human-facing name for the router picker ("Current agent: …").
    public let displayName: String
    /// How the node reaches this backend (`.builtIn` vs `.stdioSpawn`).
    public let kind: HarnessKind
    /// `.stdioSpawn` only: the executable to launch (an absolute path or a bare name resolved
    /// on `PATH`). Empty for `.builtIn`.
    public let command: String
    /// `.stdioSpawn` only: arguments passed to `command`.
    public let args: [String]
    /// `.stdioSpawn` only: environment variables ADDED to (merged over) the inherited process
    /// environment when spawning — e.g. forcing a toolchain or a model. Empty = inherit only.
    public let env: [String: String]
    /// True for the Phase-2 placeholder descriptors whose `command` is a *conventional default
    /// to be confirmed* against the actually-installed tool (these tools aren't installed yet;
    /// the launch commands are best-effort scaffolding data, not verified). The built-in and
    /// the locally-installed Xcode/OpenClaw launchers are not provisional.
    public let isProvisional: Bool
    /// WS3b — the environment variable name this harness reads its vendor API key from
    /// (e.g. `ANTHROPIC_API_KEY`), or nil for a harness that needs none (`.builtIn`, the
    /// installed launchers, which bring their own model config). This is NOT the key
    /// itself — `env` never carries a secret at rest in the static registry. The node
    /// host looks the key up from ITS OWN Keychain by `id` and merges
    /// `[vendorKeyEnvVar: key]` into a COPY of this descriptor's `env` at launch time
    /// (see `withVendorKey`), so the secret exists only for the duration of one spawn.
    public let vendorKeyEnvVar: String?

    public init(
        id: String,
        displayName: String,
        kind: HarnessKind,
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        isProvisional: Bool = false,
        vendorKeyEnvVar: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.command = command
        self.args = args
        self.env = env
        self.isProvisional = isProvisional
        self.vendorKeyEnvVar = vendorKeyEnvVar
    }

    /// WS3b — a copy of this descriptor with `key` merged into `env` under
    /// `vendorKeyEnvVar`. No-op (returns self unchanged) when this harness declares no
    /// vendor-key env var, or `key` is nil/empty (no key on file yet — the harness still
    /// launches, just without one, so a missing Keychain entry fails open to "no key"
    /// rather than blocking the launch). The caller is responsible for sourcing `key`
    /// from ITS OWN Keychain — this type carries no secret storage itself.
    public func withVendorKey(_ key: String?) -> HarnessDescriptor {
        guard let envVar = vendorKeyEnvVar, let key, !key.isEmpty else { return self }
        var merged = env
        merged[envVar] = key
        return HarnessDescriptor(
            id: id, displayName: displayName, kind: kind, command: command, args: args,
            env: merged, isProvisional: isProvisional, vendorKeyEnvVar: vendorKeyEnvVar)
    }

    /// The built-in EldrChat reference harness (bring-your-own-model). Convenience so the node
    /// and tests don't string-match `"eldr-acp"`.
    public static let builtIn = HarnessDescriptor(
        id: "eldr-acp",
        displayName: "Eldr (built-in)",
        kind: .builtIn)
}

/// The default, data-driven registry of selectable ACP backends. This is the single seam the
/// plan calls out: "Backend registry is data-driven, so **Phase 2** harnesses … register as
/// descriptors with no architecture change." A real Phase-2 integration adds an entry here
/// (and confirms its `command`); nothing else in the proxy/transport path changes.
///
/// IMPORTANT — the `.stdioSpawn` commands below are of three confidences:
///   • NOT provisional — `eldr-acp-xcode` / `eldr-acp-openclaw`: the launchers the
///     Huginn actually installs into `~/.local/bin` (see `ConfigPaths.launcher`
///     / `.openClawLauncher`). These exist on this machine today.
///   • NOT provisional (WS3d, verified) — Claude Code, Gemini CLI: `command`+`args`
///     confirmed by actually installing each (`npm install -g
///     @zed-industries/claude-code-acp @google/gemini-cli`) and driving a REAL
///     `initialize` handshake through the exact production path (`runHarness` →
///     `StdioHarnessTransport`), not just a hand-typed shell probe — both returned a
///     well-formed ACP `initialize` result. What's still UNVERIFIED: an actual
///     `session/prompt` (needs a real vendor credential — `claude /login` or
///     `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` — neither obtained here) and the
///     `@zed-industries/claude-code-acp` package is npm-flagged DEPRECATED in favor
///     of `@agentclientprotocol/claude-agent-acp`, whose bin is named
///     `claude-agent-acp` (not `claude-code-acp`) — if the operator installs the
///     successor instead, this descriptor's `command` must be updated to match.
///     OPERATIONAL CAVEAT (the actual blocker in practice): `npm install -g` under
///     nvm lands the binary in `~/.nvm/versions/node/<v>/bin`, which is NOT on a
///     GUI-launched Huginn.app's (or launchd-spawned eldr-node's) default PATH —
///     confirmed by spawning with the system default PATH (`/etc/paths` +
///     `/etc/paths.d`, no `~/.local/bin`/nvm) and getting `No such file or
///     directory`. A bare command name here only resolves if the operator installs
///     via a PATH-visible method (Homebrew, system Node) or the node's own PATH is
///     extended — this is a real per-Mac setup step, not a code bug.
///   • Still provisional (`isProvisional: true`) — Codex, OpenCode, Cursor:
///     SCAFFOLDING DATA. The commands/args are the tools' *conventional* ACP launch
///     invocations and MUST be confirmed against each installed tool before Phase-2
///     wiring; they are NOT verified here (none of these harnesses is installed).
///     They exist so the registry is the drop-in point.
public enum HarnessRegistry {
    /// `~/.local/bin/<name>` — where the Configurator installs the launchers (mirrors
    /// `ConfigPaths.binDir`). Resolved per-user so the descriptors point at the real scripts.
    private static func localBin(_ name: String) -> String {
        // `NSHomeDirectory()` is available on every platform (unlike
        // `FileManager.homeDirectoryForCurrentUser`, which is macOS-only and broke the
        // iOS app build — the registry is iOS-available so the phone's router UI can LIST
        // backends; only the macOS node ever spawns these launchers).
        let home = NSHomeDirectory()
        return ((home as NSString).appendingPathComponent(".local/bin") as NSString)
            .appendingPathComponent(name)
    }

    public static let all: [HarnessDescriptor] = [
        // ── Built-in: the in-process eldr-acp / LLM agent (bring-your-own-model). ──
        .builtIn,

        // ── Installed launchers (NOT provisional): the Configurator writes these scripts. ──
        // Xcode ACP Agent launcher — forces the Xcode-beta toolchain, then execs `eldr-acp`.
        HarnessDescriptor(
            id: "xcode-acp",
            displayName: "Xcode ACP Agent",
            kind: .stdioSpawn,
            command: localBin("eldr-acp-xcode")),
        // OpenClaw launcher — same script body, client-agnostic (`ConfigPaths.openClawLauncher`).
        HarnessDescriptor(
            id: "openclaw",
            displayName: "OpenClaw",
            kind: .stdioSpawn,
            command: localBin("eldr-acp-openclaw")),

        // ── WS3d-verified: command+args confirmed against the real installed binary. ──
        // Claude Code: the `@zed-industries/claude-code-acp` ACP adapter (npm-deprecated in
        // favor of `@agentclientprotocol/claude-agent-acp`, bin `claude-agent-acp` — update
        // `command` if/when the operator installs the successor instead).
        HarnessDescriptor(
            id: "claude-code",
            displayName: "Claude Code",
            kind: .stdioSpawn,
            command: "claude-code-acp",
            args: [],
            isProvisional: false,
            vendorKeyEnvVar: "ANTHROPIC_API_KEY"),
        // Gemini CLI: Google's `@google/gemini-cli`, ACP mode over stdio.
        HarnessDescriptor(
            id: "gemini-cli",
            displayName: "Gemini CLI",
            kind: .stdioSpawn,
            command: "gemini",
            args: ["--experimental-acp"],
            isProvisional: false,
            vendorKeyEnvVar: "GEMINI_API_KEY"),

        // ── Phase-2 placeholders (still PROVISIONAL — commands are defaults to confirm). ──
        // Codex: OpenAI's `codex` CLI, ACP/stdio subcommand.
        HarnessDescriptor(
            id: "codex",
            displayName: "Codex",
            kind: .stdioSpawn,
            command: "codex",
            args: ["acp"],
            isProvisional: true),
        // OpenCode: the `opencode` CLI's ACP/agent stdio mode.
        HarnessDescriptor(
            id: "opencode",
            displayName: "OpenCode",
            kind: .stdioSpawn,
            command: "opencode",
            args: ["acp"],
            isProvisional: true),
        // Cursor: the `cursor-agent` ACP launcher.
        HarnessDescriptor(
            id: "cursor",
            displayName: "Cursor",
            kind: .stdioSpawn,
            command: "cursor-agent",
            args: ["acp"],
            isProvisional: true),
    ]

    /// Look up a descriptor by its stable `id` (router selection / restore).
    public static func descriptor(id: String) -> HarnessDescriptor? {
        all.first { $0.id == id }
    }
}
