import CryptoKit
import Foundation

// Phase-1c plumbing: a JSONL event log and a project-context locator. Both are
// pure helpers (no actor state) so they're trivially Sendable and unit-testable,
// and `public` so the macOS Configurator's ContextLearner (Phase 3) reuses the
// EXACT same path math — agent and learner MUST agree on where a project's
// `eldr.md` lives or the self-learning loop silently writes/reads different files.

/// Appends one JSON object per line to a JSONL file. The agent calls this after
/// significant turn events (write_file, run_shell, session end); the Configurator
/// tails the file to drive live monitoring + ContextLearner. Best-effort: a logging
/// failure NEVER fails a turn (the agent's job is to code, not to log).
public enum ACPEventLog {

    /// `{"type":"write_file","path":…,"session":…,"cwd":…,"ts":…}`
    public static func writeFile(
        path filePath: String, session: String, cwd: String, to eventsFile: String?
    ) {
        append(
            [
                ("type", .string("write_file")),
                ("path", .string(filePath)),
                ("session", .string(session)),
                ("cwd", .string(cwd)),
                ("ts", .string(nowISO8601())),
            ], to: eventsFile)
    }

    /// `{"type":"shell_result","cmd":…,"exit":<int>,"summary":…,"session":…,"cwd":…,"ts":…}`
    /// `summary` is the caller-truncated first slice of the command's output.
    public static func shellResult(
        cmd: String, exit code: Int, summary: String, session: String, cwd: String,
        to eventsFile: String?
    ) {
        append(
            [
                ("type", .string("shell_result")),
                ("cmd", .string(cmd)),
                ("exit", .int(code)),
                ("summary", .string(summary)),
                ("session", .string(session)),
                ("cwd", .string(cwd)),
                ("ts", .string(nowISO8601())),
            ], to: eventsFile)
    }

    /// `{"type":"session_end","cwd":…,"session":…,"summary":…,"files":<int>,"build":…,"ts":…}`
    /// `build` is `"green" | "red" | "unknown"`.
    public static func sessionEnd(
        cwd: String, session: String, summary: String, files: Int, build: String,
        to eventsFile: String?
    ) {
        append(
            [
                ("type", .string("session_end")),
                ("cwd", .string(cwd)),
                ("session", .string(session)),
                ("summary", .string(summary)),
                ("files", .int(files)),
                ("build", .string(build)),
                ("ts", .string(nowISO8601())),
            ], to: eventsFile)
    }

    /// Append one serialized object as a single line. JSONValue → JSONSerialization
    /// escapes embedded newlines, so a multi-line `summary` can't break JSONL framing.
    static func append(_ fields: [(String, JSONValue)], to path: String?) {
        guard let path, !path.isEmpty else { return }
        let line = JSONValue.object(Dictionary(fields, uniquingKeysWith: { a, _ in a })).serialized() + "\n"
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

    /// Resolve the context to inject for a session: an explicit `ELDR_ACP_CONTEXT_FILE`
    /// path wins; otherwise the auto-discovered per-project file. Returns nil when
    /// neither exists or both are empty. Reads at most `maxBytes` (the budget the
    /// system-prompt block is capped to).
    public static func read(
        explicitPath: String?, configDir: String?, cwd: String, maxBytes: Int = 4096
    ) -> String? {
        if let explicitPath, let text = readFile(explicitPath, maxBytes: maxBytes) { return text }
        if let configDir {
            let auto = memoryPath(configDir: configDir, cwd: cwd)
            if let text = readFile(auto, maxBytes: maxBytes) { return text }
        }
        return nil
    }

    /// Read the first `maxBytes` of a file, lossily decoded (a cut mid-multibyte-char
    /// becomes U+FFFD, never a crash). nil for absent/empty.
    static func readFile(_ path: String, maxBytes: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data.prefix(maxBytes), as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Wrap context for injection as a leading system message.
    public static func systemBlock(_ contents: String) -> String {
        "--- Project Context (eldr.md) ---\n\(contents)\n---"
    }
}
