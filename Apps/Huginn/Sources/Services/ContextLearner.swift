import Darwin
import Foundation
import PQRCACP

/// The self-learning loop. Tails `events.jsonl` (what the agent appends per turn) and
/// turns it into durable, per-project `eldr.md` the agent reads back on its next
/// session:
///  - a failed shell command  → a `## LLM Corrections` note
///  - a written file the user then edits (within 15 min) → a corrections note
///  - a finished session       → a `## Session History` entry (most-recent 10 kept)
/// Each project's file lives at `<configDir>/projects/<sha256(cwd)>/eldr.md` (shared
/// path math with the agent via ProjectContext) and is capped to 4 KB after every
/// update so it always fits the system-prompt budget.
@MainActor
final class ContextLearner: ObservableObject {

    struct ProjectMemory: Identifiable, Equatable {
        var id: String { path }
        var cwd: String  // human-readable; recovered from a sidecar marker
        var path: String  // the eldr.md
        var preview: String
    }

    @Published private(set) var activeProjects: [ProjectMemory] = []

    private let paths: ConfigPaths
    /// B2: the at-rest key for the metadata sinks, derived from the SAME Secure-Enclave-
    /// wrapped master key the agent + transcript use (see `ConversationMemory.metadataKey()`).
    /// When present, `eldr.md` is written WHOLE-file sealed and each `events.jsonl` line is
    /// opened before parsing; nil ⇒ everything stays cleartext (today's behavior — no
    /// regression). Injected via `init`/`setMetadataKey`, so an external launch that lacks
    /// the master key degrades gracefully. Never logged/persisted in the clear (invariant 12).
    private var metadataKey: Data?

    private var eventsHandle: FileHandle?
    private var eventsSource: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0

    // write_file watchers: path → source / expiry task.
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var watcherExpiries: [String: Task<Void, Never>] = [:]

    init(paths: ConfigPaths = .standard, metadataKey: Data? = nil) {
        self.paths = paths
        self.metadataKey = metadataKey
    }

    /// B2: inject (or clear) the at-rest metadata key once it's derived (the derivation is
    /// async — it forces the `ConversationMemory`/`EncryptedStore` bootstrap — so the view
    /// pushes it in after construction). nil ⇒ cleartext fallback.
    func setMetadataKey(_ key: Data?) { self.metadataKey = key }

    deinit {
        eventsSource?.cancel()
        for source in watchers.values { source.cancel() }
    }

    // MARK: - Lifecycle

    func start() {
        refreshProjects()
        guard eventsSource == nil else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.eventsFile) {
            try? fm.createDirectory(
                atPath: (paths.eventsFile as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            fm.createFile(atPath: paths.eventsFile, contents: nil)
        }
        guard let handle = FileHandle(forReadingAtPath: paths.eventsFile) else { return }
        eventsHandle = handle
        // Only react to NEW events (don't replay history into eldr.md on every launch).
        offset = (try? handle.seekToEnd()) ?? 0

        // Main-queue delivery: this class is @MainActor, so the handler closure is
        // @MainActor-inferred and Swift 6's dynamic isolation check traps if a
        // background queue invokes it (the LogTailer crash class — see LogTailerTests).
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            let mask = source.data
            Task { @MainActor [weak self] in self?.readEvents(mask) }
        }
        // No async `self.eventsHandle = nil` in the cancel handler: it ran AFTER a
        // stop()/start() rotation had already installed the new handle and nilled it,
        // silently killing the watch. stop() cancels then releases the handle (which
        // owns + closes its fd on dealloc), which is sufficient and race-free.
        eventsSource = source
        source.resume()
    }

    func stop() {
        eventsSource?.cancel()
        eventsSource = nil
        try? eventsHandle?.close()
        eventsHandle = nil
        for path in Array(watchers.keys) { unwatch(path) }
    }

    // MARK: - Event ingestion

    private func readEvents(_ mask: DispatchSource.FileSystemEvent) {
        if mask.contains(.rename) || mask.contains(.delete) {
            stop()
            offset = 0
            start()
            return
        }
        guard let handle = eventsHandle else { return }
        do {
            try handle.seek(toOffset: offset)
            let data = (try handle.readToEnd()) ?? Data()
            offset = (try? handle.offset()) ?? offset
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // B2: a sealed line opens to its plaintext JSON; a legacy plaintext line
                // (openLine → nil) is kept as-is; a sealed line with no key falls through
                // to the base64 text, which JSONValue.parse rejects (skipped, not leaked).
                let raw = String(line)
                let plain = metadataKey.flatMap { ACPMetadataCrypto.openLine(raw, key: $0) } ?? raw
                if let json = JSONValue.parse(plain) { ingest(event: json) }
            }
        } catch {
            stop()
            offset = 0
            start()
        }
    }

    private func ingest(event json: JSONValue) {
        guard let type = json["type"]?.stringValue, let cwd = json["cwd"]?.stringValue else {
            return
        }
        switch type {
        case "shell_result":
            if let exit = json["exit"]?.intValue, exit != 0 {
                let cmd = json["cmd"]?.stringValue ?? ""
                let summary = Self.firstLine(json["summary"]?.stringValue ?? "")
                let note =
                    "Command failed (exit \(exit)): `\(cmd)`"
                    + (summary.isEmpty ? "" : " — \(summary)")
                update(cwd: cwd) { $0.addCorrection(note) }
            }
        case "write_file":
            if let path = json["path"]?.stringValue { watchFile(path, cwd: cwd) }
        case "session_end":
            let ts = json["ts"]?.stringValue ?? ""
            let summary = json["summary"]?.stringValue ?? ""
            let files = json["files"]?.intValue ?? 0
            let build = json["build"]?.stringValue ?? "unknown"
            update(cwd: cwd) {
                $0.addSession("\(ts): \(summary) (files: \(files), build: \(build))")
            }
        default:
            break
        }
    }

    static func firstLine(_ s: String) -> String {
        String(s.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - write_file watching (detect a user editing the agent's file)

    private func watchFile(_ path: String, cwd: String) {
        guard watchers[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.fileChanged(path, cwd: cwd) }
        }
        source.setCancelHandler { close(fd) }
        watchers[path] = source
        source.resume()
        // Expire the watch after 15 minutes.
        watcherExpiries[path] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            await MainActor.run { self?.unwatch(path) }
        }
    }

    private func fileChanged(_ path: String, cwd: String) {
        let name = (path as NSString).lastPathComponent
        update(cwd: cwd) {
            $0.addCorrection(
                "You edited `\(name)` after the agent wrote it — prefer your version of that file.")
        }
        unwatch(path)
    }

    private func unwatch(_ path: String) {
        watchers[path]?.cancel()
        watchers[path] = nil
        watcherExpiries[path]?.cancel()
        watcherExpiries[path] = nil
    }

    // MARK: - eldr.md read/write

    private func update(cwd: String, _ mutate: (inout ProjectMemoryDoc) -> Void) {
        let mdPath = ProjectContext.memoryPath(configDir: paths.configDir, cwd: cwd)
        let dir = (mdPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Sidecar `cwd` marker so the UI can show the real path (the dir is a hash).
        let marker = (dir as NSString).appendingPathComponent("cwd")
        if !FileManager.default.fileExists(atPath: marker) {
            try? cwd.data(using: .utf8)?.write(to: URL(fileURLWithPath: marker))
        }

        var doc = ProjectMemoryDoc(parsing: readMemoryText(mdPath))
        mutate(&doc)
        doc.cap(toBytes: 4096)
        // B2: with a key, write the WHOLE file sealed (magic header + base64); without one,
        // write plaintext exactly as before. A seal failure also falls back to plaintext so
        // an update is never lost.
        let serialized = doc.serialized()
        let out: Data
        if let metadataKey, let sealed = ProjectContext.sealForDisk(serialized, key: metadataKey) {
            out = sealed
        } else {
            out = Data(serialized.utf8)
        }
        try? out.write(to: URL(fileURLWithPath: mdPath), options: .atomic)
        refreshProjects()
    }

    func refreshProjects() {
        let fm = FileManager.default
        guard let hashes = try? fm.contentsOfDirectory(atPath: paths.projectsDir) else {
            activeProjects = []
            return
        }
        var result: [ProjectMemory] = []
        for hash in hashes {
            let dir = (paths.projectsDir as NSString).appendingPathComponent(hash)
            let mdPath = (dir as NSString).appendingPathComponent("eldr.md")
            guard fm.fileExists(atPath: mdPath) else { continue }
            let cwd =
                (try? String(
                    contentsOfFile: (dir as NSString).appendingPathComponent("cwd"),
                    encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? hash
            let doc = ProjectMemoryDoc(parsing: readMemoryText(mdPath))
            result.append(ProjectMemory(cwd: cwd, path: mdPath, preview: doc.preview))
        }
        activeProjects = result.sorted { $0.cwd < $1.cwd }
    }

    /// The full eldr.md text (for the "View" sheet).
    func memoryText(_ project: ProjectMemory) -> String { readMemoryText(project.path) }

    /// B2: read an `eldr.md` from disk, transparently unsealing a WHOLE-file-sealed file
    /// (magic header) with `metadataKey`. Returns "" when the file is absent, or is sealed
    /// but unreadable (no/wrong key) — so ciphertext is never parsed or rendered as text; a
    /// legacy plaintext (headerless) file is returned as-is regardless of key.
    private func readMemoryText(_ path: String) -> String {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        return ProjectContext.openFromDisk(data, key: metadataKey) ?? ""
    }

    /// Delete a project's memory (the "Clear" button) and refresh.
    func clear(_ project: ProjectMemory) {
        let dir = (project.path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
        refreshProjects()
    }
}
