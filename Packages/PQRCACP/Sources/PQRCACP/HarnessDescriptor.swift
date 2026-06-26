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

    public init(
        id: String,
        displayName: String,
        kind: HarnessKind,
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        isProvisional: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.command = command
        self.args = args
        self.env = env
        self.isProvisional = isProvisional
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
/// IMPORTANT — the `.stdioSpawn` commands below are of two confidences:
///   • NOT provisional — `eldr-acp-xcode` / `eldr-acp-openclaw`: the launchers the
///     EldrACPConfigurator actually installs into `~/.local/bin` (see `ConfigPaths.launcher`
///     / `.openClawLauncher`). These exist on this machine today.
///   • Provisional (`isProvisional: true`) — Claude Code, Codex, Gemini CLI, OpenCode,
///     Cursor: SCAFFOLDING DATA. The commands/args are the tools' *conventional* ACP launch
///     invocations and MUST be confirmed against each installed tool before Phase-2 wiring;
///     they are NOT verified here (none of these harnesses is installed). They exist so the
///     registry is the drop-in point.
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

        // ── Phase-2 placeholders (PROVISIONAL — commands are defaults to confirm). ──
        // Claude Code: Anthropic's CLI exposes an ACP server mode.
        HarnessDescriptor(
            id: "claude-code",
            displayName: "Claude Code",
            kind: .stdioSpawn,
            command: "claude-code-acp",
            args: [],
            isProvisional: true),
        // Codex: OpenAI's `codex` CLI, ACP/stdio subcommand.
        HarnessDescriptor(
            id: "codex",
            displayName: "Codex",
            kind: .stdioSpawn,
            command: "codex",
            args: ["acp"],
            isProvisional: true),
        // Gemini CLI: Google's `gemini` CLI run as an ACP experiment/server over stdio.
        HarnessDescriptor(
            id: "gemini-cli",
            displayName: "Gemini CLI",
            kind: .stdioSpawn,
            command: "gemini",
            args: ["--experimental-acp"],
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
