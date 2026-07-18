import CryptoKit
import Foundation

// Phase-1c plumbing: a JSONL event log and a project-context locator. Both are
// pure helpers (no actor state) so they're trivially Sendable and unit-testable,
// and `public` so the macOS Configurator's ContextLearner (Phase 3) reuses the
// EXACT same path math — agent and learner MUST agree on where a project's
// `eldr.md` lives or the self-learning loop silently writes/reads different files.

/// C-6: redacts credential-shaped substrings before they're written to the node's
/// AT-REST diagnostic sinks (`events.jsonl`, the agent's stderr trace, the launcher
/// logfile). A `run_shell("echo $OPENAI_API_KEY")` or a tool result carrying a token
/// would otherwise land in cleartext on disk; this scrubs the *strings that get
/// written to the log* — NOT the live ACP data channel, the tool results returned to
/// the model, or anything delivered to the owner's paired device. Log hygiene on
/// disk only.
///
/// Self-contained on purpose: PQRCACP is deliberately ZERO-dependency (see
/// `Package.swift`), so it can't import PQRCCore's `CredentialRedactor`. This mirrors
/// that redactor's high-risk patterns. The app can supersede it by injecting the
/// canonical one through `AgentConfig.logRedactor` (one source of truth where it
/// matters); the built-in default means the agent self-protects even if the app
/// forgets to wire the seam (defense in depth). The duplication is the cost of the
/// zero-dependency boundary — flagged for the audit's redactor-as-single-source note.
///
/// Like its PQRCCore twin it leans CONSERVATIVE toward leaking: a false positive only
/// redacts a non-secret in an on-disk log; a false negative would leak a real secret,
/// so the patterns are broad. The marker never echoes the secret.
public enum ACPLogRedactor {
    /// Marker substituted for key-shaped secrets.
    public static let apiKeyMarker = "‹redacted:api-key›"
    /// Marker substituted for token/password-shaped secrets.
    public static let tokenMarker = "‹redacted:token›"

    /// Replace every detected secret in `text` with a marker. Returns the input
    /// unchanged when nothing matched. Runs the full rule set (labeled shapes AND the
    /// generic high-entropy catch-alls) — use for FREE-TEXT fields (a shell command,
    /// captured output, a model message) where any long high-entropy run is suspect.
    public static func scrub(_ text: String) -> String { apply(rules, to: text) }

    /// Path-aware scrub: runs ONLY the unambiguous labeled credential shapes (sk-…,
    /// AKIA…, Bearer …, key=value, …) and NOT the generic high-entropy / bare-hex
    /// catch-alls. A filesystem path legitimately contains long high-entropy runs that
    /// are NOT secrets — a UUID temp dir, and (critically) this codebase's own
    /// `projects/<sha256(cwd)>/…` layout, a 64-char hex id the Configurator's
    /// ContextLearner consumes verbatim. Redacting those would both corrupt a
    /// downstream consumer and over-redact a non-secret; an embedded real credential
    /// (e.g. `…/sk-…/…`) is still caught by the labeled rules.
    public static func scrubPath(_ text: String) -> String { apply(labeledRules, to: text) }

    private static func apply(_ rules: [Rule], to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }

    private struct Rule { let regex: NSRegularExpression; let template: String }

    /// Full set used by `scrub`: labeled shapes first (so they get the right marker),
    /// then the generic high-entropy catch-alls last (over text the earlier rules have
    /// already turned into inert markers).
    private static let rules: [Rule] = labeledRules + entropyRules

    /// Unambiguous, prefix-anchored or key-named credential shapes. Safe to run over a
    /// path. Mirrors `PQRCCore.CredentialRedactor`'s specific rules; keep in sync.
    private static let labeledRules: [Rule] = compile([
        // OpenAI / Anthropic secret keys: sk-… and sk-ant-… (the `ant-` is in the
        // char class, so one pattern covers both).
        ("sk-[A-Za-z0-9_-]{12,}", apiKeyMarker, []),
        // AWS access key ids (AKIA/ASIA/AROA/AIDA + 12+ uppercase/digits).
        ("(?:AKIA|ASIA|AROA|AIDA)[A-Z0-9]{12,}", apiKeyMarker, []),
        // GitHub tokens (ghp_/gho_/ghu_/ghs_/ghr_ + 20+).
        ("gh[pousr]_[A-Za-z0-9]{20,}", tokenMarker, []),
        // Slack tokens (xoxb-/xoxp-/…).
        ("xox[baprs]-[A-Za-z0-9-]{10,}", tokenMarker, []),
        // Google API keys.
        ("AIza[A-Za-z0-9_-]{20,}", apiKeyMarker, []),
        // Bearer tokens — keep the "Bearer " prefix, redact the credential.
        ("(Bearer )[A-Za-z0-9._~+/=-]{12,}", "$1\(tokenMarker)", [.caseInsensitive]),
        // key=value / key: "value" assignments for secret-named keys. Preserve the
        // key, separator, and any quotes; redact only the value.
        (
            "((?:api[_-]?key|secret|access[_-]?token|auth[_-]?token|access[_-]?key|token|password|passwd|pwd))(\\s*[:=]\\s*)([\"']?)([^\\s\"']{6,})([\"']?)",
            "$1$2$3\(tokenMarker)$5", [.caseInsensitive]
        ),
    ])

    /// Generic high-entropy catch-alls. NOT run over paths (false-positives a UUID /
    /// sha256 dir). Mirrors `PQRCCore.CredentialRedactor`'s catch-all rules.
    private static let entropyRules: [Rule] = compile([
        // High-entropy base64/base64url run with BOTH a letter and a digit (the dual
        // lookahead skips long all-letter words and slash-only paths).
        (
            "(?=[A-Za-z0-9+/=_-]*[0-9])(?=[A-Za-z0-9+/=_-]*[A-Za-z])[A-Za-z0-9+/=_-]{40,}",
            tokenMarker, []
        ),
        // Long hex runs (sha1/sha256, 40+ hex chars).
        ("\\b[0-9a-fA-F]{40,}\\b", tokenMarker, []),
    ])

    private static func compile(
        _ specs: [(String, String, NSRegularExpression.Options)]
    ) -> [Rule] {
        specs.compactMap { pattern, template, options in
            // Patterns are compile-time constants; `try?` (not `try!`, per CLAUDE.md)
            // degrades safely — a (never-expected) bad pattern is simply skipped.
            (try? NSRegularExpression(pattern: pattern, options: options))
                .map { Rule(regex: $0, template: template) }
        }
    }
}

/// The redaction seam: a pure, synchronous `String → String` applied at every
/// at-rest log write. Each write site defaults to the right built-in
/// (`ACPLogRedactor.scrub` for free-text fields, `.scrubPath` for the path field), so
/// PQRCACP self-protects with zero wiring; the app can inject PQRCCore's canonical
/// `CredentialRedactor.scrub` for the free-text fields to keep one source of truth.
/// `@Sendable` so it crosses the agent actor boundary.
public typealias ACPLogScrubber = @Sendable (String) -> String

/// Appends one JSON object per line to a JSONL file. The agent calls this after
/// significant turn events (write_file, run_shell, session end); the Configurator
/// tails the file to drive live monitoring + ContextLearner. Best-effort: a logging
/// failure NEVER fails a turn (the agent's job is to code, not to log).
public enum ACPEventLog {

    /// `{"type":"write_file","path":…,"session":…,"cwd":…,"ts":…}`
    /// C-6: `path` (an attacker-influenced free string — a model can `write_file` to a
    /// path that embeds a token) is scrubbed before it hits disk. Defaults to the
    /// PATH-AWARE scrub (`scrubPath`): it catches an embedded `sk-…`/Bearer/etc. but
    /// NOT the generic high-entropy catch-all, so a legitimate UUID/sha256 path
    /// component (e.g. the `projects/<sha256(cwd)>` layout ContextLearner reads) isn't
    /// mangled.
    public static func writeFile(
        path filePath: String, session: String, cwd: String, to eventsFile: String?,
        key: Data? = nil, redact: ACPLogScrubber = ACPLogRedactor.scrubPath
    ) {
        append(
            [
                ("type", .string("write_file")),
                ("path", .string(redact(filePath))),
                ("session", .string(session)),
                ("cwd", .string(cwd)),
                ("ts", .string(nowISO8601())),
            ], to: eventsFile, key: key)
    }

    /// `{"type":"shell_result","cmd":…,"exit":<int>,"summary":…,"session":…,"cwd":…,"ts":…}`
    /// `summary` is the caller-truncated first slice of the command's output.
    /// C-6: both `cmd` (e.g. `echo $OPENAI_API_KEY` — but more to the point a literal
    /// `--token sk-…`) and `summary` (the command's captured output) are scrubbed
    /// before the line is written, the two highest-risk at-rest leak vectors.
    public static func shellResult(
        cmd: String, exit code: Int, summary: String, session: String, cwd: String,
        to eventsFile: String?, key: Data? = nil, redact: ACPLogScrubber = ACPLogRedactor.scrub
    ) {
        append(
            [
                ("type", .string("shell_result")),
                ("cmd", .string(redact(cmd))),
                ("exit", .int(code)),
                ("summary", .string(redact(summary))),
                ("session", .string(session)),
                ("cwd", .string(cwd)),
                ("ts", .string(nowISO8601())),
            ], to: eventsFile, key: key)
    }

    /// `{"type":"session_end","cwd":…,"session":…,"summary":…,"files":<int>,"build":…,"ts":…}`
    /// `build` is `"green" | "red" | "unknown"`.
    /// C-6: `summary` (the model's free-text final message) is scrubbed before disk.
    public static func sessionEnd(
        cwd: String, session: String, summary: String, files: Int, build: String,
        to eventsFile: String?, key: Data? = nil, redact: ACPLogScrubber = ACPLogRedactor.scrub
    ) {
        append(
            [
                ("type", .string("session_end")),
                ("cwd", .string(cwd)),
                ("session", .string(session)),
                ("summary", .string(redact(summary))),
                ("files", .int(files)),
                ("build", .string(build)),
                ("ts", .string(nowISO8601())),
            ], to: eventsFile, key: key)
    }

    /// Append one serialized object as a single line. JSONValue → JSONSerialization
    /// escapes embedded newlines, so a multi-line `summary` can't break JSONL framing.
    ///
    /// B2: when `key` is present, the LINE is sealed with `ACPMetadataCrypto.sealLine`
    /// (base64) before it hits disk, so an at-rest reader sees ciphertext, not the event.
    /// A sealed line is base64 (never starts with `{`), so a reader distinguishes it from a
    /// legacy plaintext JSON line unambiguously (try `openLine`; nil ⇒ legacy plaintext). A
    /// seal failure falls back to writing the plaintext line — an event is NEVER dropped.
    static func append(_ fields: [(String, JSONValue)], to path: String?, key: Data? = nil) {
        guard let path, !path.isEmpty else { return }
        let json = JSONValue.object(Dictionary(fields, uniquingKeysWith: { a, _ in a })).serialized()
        let line: String
        if let key, let sealed = ACPMetadataCrypto.sealLine(json, key: key) {
            line = sealed + "\n"
        } else {
            line = json + "\n"
        }
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            let dir = (path as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Best-effort: never let event logging fail the turn.
        }
    }

    static func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

/// Locates (and reads) a project's persistent context file. A project's identity is
/// the SHA-256 of its absolute working-directory path — STABLE across runs and
/// machine-local-path-free in the shared `projects/` namespace (a hash, not the real
/// path). The agent prepends this file to its system prompt each session; the
/// Configurator's ContextLearner writes to the same path.
public enum ProjectContext {

    /// Stable per-project id: lowercase hex SHA-256 of the absolute cwd path.
    public static func identity(forCwd cwd: String) -> String {
        SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `<configDir>/projects/<sha256(cwd)>/eldr.md`
    public static func memoryPath(configDir: String, cwd: String) -> String {
        let projects = (configDir as NSString).appendingPathComponent("projects")
        let project = (projects as NSString).appendingPathComponent(identity(forCwd: cwd))
        return (project as NSString).appendingPathComponent("eldr.md")
    }

    /// A3: the industry-standard, agent-facing orientation file other harnesses
    /// (claude-code, gemini-cli, Xcode) also read — so a single file at the project
    /// root serves EVERY agent. Discovered at `<cwd>/AGENTS.md`, LAST in the chain
    /// (an explicit override or a per-project `eldr.md` still wins).
    public static let agentsFileName = "AGENTS.md"

    /// `<cwd>/AGENTS.md`
    public static func agentsPath(cwd: String) -> String {
        (cwd as NSString).appendingPathComponent(agentsFileName)
    }

    /// Resolve the context to inject for a session. Precedence (highest first):
    ///  1. an explicit `ELDR_ACP_CONTEXT_FILE` path (`explicitPath`);
    ///  2. the auto-discovered per-project `eldr.md`
    ///     (`<configDir>/projects/<sha256(cwd)>/eldr.md`);
    ///  3. A3: `<cwd>/AGENTS.md` — the industry-standard file other harnesses read.
    /// Returns nil when none exists or all are empty. Reads at most `maxBytes` (the
    /// budget the system-prompt block is capped to).
    public static func read(
        explicitPath: String?, configDir: String?, cwd: String, maxBytes: Int = 4096,
        key: Data? = nil
    ) -> String? {
        if let explicitPath, let text = readFile(explicitPath, maxBytes: maxBytes, key: key) {
            return text
        }
        if let configDir {
            let auto = memoryPath(configDir: configDir, cwd: cwd)
            if let text = readFile(auto, maxBytes: maxBytes, key: key) { return text }
        }
        // A3: fall back to a repo-root AGENTS.md so one file serves every agent.
        if let text = readFile(agentsPath(cwd: cwd), maxBytes: maxBytes, key: key) {
            return text
        }
        return nil
    }

    /// B2: the magic header marking a WHOLE-FILE-sealed `eldr.md`. ASCII, newline-terminated
    /// — a keyless/older reader can't mistake the base64 body that follows it for markdown.
    public static let sealedHeader = "ELDR-SEALED-v1\n"

    /// Read the first `maxBytes` of a file, lossily decoded (a cut mid-multibyte-char
    /// becomes U+FFFD, never a crash). nil for absent/empty.
    ///
    /// B2: a file that begins with `sealedHeader` is WHOLE-FILE sealed — `openFromDisk`
    /// decrypts it (nil key or a failed open ⇒ nil ⇒ SKIP: never render ciphertext as
    /// text). A file WITHOUT the header is legacy plaintext markdown, read exactly as before.
    static func readFile(_ path: String, maxBytes: Int, key: Data? = nil) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // `openFromDisk` returns the plaintext for BOTH a legacy (headerless) file and a
        // successfully-opened sealed file; it returns nil ONLY for a sealed file we can't
        // read (no/wrong key, corrupt) — which correctly maps to "skip" here.
        guard let full = openFromDisk(data, key: key) else { return nil }
        let text = String(decoding: Data(full.utf8).prefix(maxBytes), as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// B2: seal `contents` for WHOLE-FILE at-rest storage — the ASCII `sealedHeader`
    /// followed by base64 of the AES-GCM blob. Returns nil if sealing fails (caller writes
    /// plaintext instead). Requires a key; callers gate on `key != nil` first.
    public static func sealForDisk(_ contents: String, key: Data) -> Data? {
        guard let sealed = ACPMetadataCrypto.seal(Data(contents.utf8), key: key) else {
            return nil
        }
        return Data(sealedHeader.utf8) + Data(sealed.base64EncodedString().utf8)
    }

    /// B2: the SINGLE source of the whole-file header logic, shared by `readFile` (the agent)
    /// and Huginn's ContextLearner. Returns:
    ///  - a HEADERLESS file's bytes decoded as-is (legacy plaintext markdown — used as today);
    ///  - a sealed file's decrypted plaintext when `key` opens it;
    ///  - nil when the file is sealed but `key` is nil or the open fails (wrong key / corrupt)
    ///    — the caller SKIPS it and never renders ciphertext as text.
    public static func openFromDisk(_ data: Data, key: Data?) -> String? {
        let header = Data(sealedHeader.utf8)
        guard data.starts(with: header) else {
            // Legacy plaintext markdown — return it unchanged regardless of key.
            return String(decoding: data, as: UTF8.self)
        }
        // Sealed: needs a key that opens the base64 body.
        guard let key,
            let blob = Data(base64Encoded: Data(data.dropFirst(header.count))),
            let plaintext = ACPMetadataCrypto.open(blob, key: key)
        else { return nil }
        return String(decoding: plaintext, as: UTF8.self)
    }

    /// Wrap context for injection as a leading system message.
    public static func systemBlock(_ contents: String) -> String {
        "--- Project Context (eldr.md) ---\n\(contents)\n---"
    }
}
