import Foundation

/// One classified line from `eldr-acp.log`.
struct LogLine: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case llm  // model calls
        case tool  // tool execution
        case error
        case info
    }
    let id: Int
    let text: String
    let kind: Kind
}

/// Follows `~/.config/eldr-acp/eldr-acp.log`, publishing newly-appended lines
/// classified for color-coding. Uses a `DispatchSourceFileSystemObject` on the
/// file descriptor (write/extend → read the delta; rename/delete → reopen, handling
/// log rotation). The app stops/starts it with window visibility.
///
/// The source delivers on the MAIN queue: this class is @MainActor, so its event
/// handler closure is @MainActor-inferred, and Swift 6's dynamic isolation check
/// SIGTRAPs (`dispatch_assert_queue_fail`) if a background queue invokes it — the
/// crash the MLX server pane hit the first time it wrote to a tailed log
/// (2026-07-17 crash report; regression: `LogTailerTests`). Events are rare and
/// the handler is tiny, so main-queue delivery costs nothing.
@MainActor
final class LogTailer: ObservableObject {

    @Published private(set) var lines: [LogLine] = []

    private let path: String
    /// Cap retained lines so a long-running session doesn't grow unbounded in memory.
    private let maxLines = 2000
    /// Cap how much of an EXISTING file the tailer reads when it (re)opens. A
    /// long-lived server log reaches hundreds of KB, and `readToEnd()` of the whole
    /// file on the main actor visibly froze the MLX tab on first open — seeding from
    /// the last 64 KB keeps open instant. Incremental delta reads stay unbounded
    /// (they're the few bytes just appended).
    private let maxSeedBytes: UInt64

    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var nextID = 0

    init(path: String, maxSeedBytes: UInt64 = 65_536) {
        self.path = path
        self.maxSeedBytes = maxSeedBytes
    }

    deinit { source?.cancel() }

    // MARK: - Lifecycle

    func start() {
        guard source == nil else { return }
        openAndPrime()
    }

    func stop() {
        // Cancel the source, then drop the handle. The handle (a
        // `FileHandle(forReadingAtPath:)`) owns its fd and closes it on dealloc, so
        // releasing it here is sufficient — no explicit close racing the source.
        source?.cancel()
        source = nil
        handle = nil
    }

    /// Truncate the log on disk and clear the view ("Clear" button).
    func clear() {
        stop()
        try? Data().write(to: URL(fileURLWithPath: path))
        lines.removeAll()
        offset = 0
        start()
    }

    var allText: String { lines.map(\.text).joined(separator: "\n") }

    // MARK: - File watching

    private func openAndPrime() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        handle = h

        // Seed with the existing TAIL (bounded) so the view isn't empty on open.
        let size = (try? h.seekToEnd()) ?? 0
        let seedStart = size > maxSeedBytes ? size - maxSeedBytes : 0
        try? h.seek(toOffset: seedStart)
        var existing = (try? h.readToEnd()) ?? Data()
        if seedStart > 0, let firstNewline = existing.firstIndex(of: UInt8(ascii: "\n")) {
            // Started mid-line: drop the partial first line.
            existing = existing[existing.index(after: firstNewline)...]
        }
        offset = (try? h.offset()) ?? size
        ingest(existing, seeding: true)

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: h.fileDescriptor, eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        // Pin the handle this source watches so the event/cancel closures can't
        // touch a freshly-reopened handle after a rotation (the old bug: an async
        // `self.handle = nil` from the stale cancel handler nilled the NEW handle and
        // silently stopped tailing). The handle owns its fd and closes it on dealloc.
        src.setEventHandler { [weak self] in
            let mask = src.data
            Task { @MainActor [weak self] in self?.handleEvent(mask) }
        }
        // No cancel handler: releasing `handle` (in stop()/reopen) closes the fd, and
        // the source is cancelled before the handle is released.
        source = src
        src.resume()
    }

    private func handleEvent(_ mask: DispatchSource.FileSystemEvent) {
        // Rotation: the file we hold was renamed/deleted → reopen from the top.
        if mask.contains(.rename) || mask.contains(.delete) {
            stop()
            offset = 0
            openAndPrime()
            return
        }
        guard let h = handle else { return }
        do {
            try h.seek(toOffset: offset)
            let new = (try h.readToEnd()) ?? Data()
            offset = (try? h.offset()) ?? offset
            ingest(new, seeding: false)
        } catch {
            // A read error usually means rotation we missed — reopen.
            stop()
            offset = 0
            openAndPrime()
        }
    }

    private func ingest(_ data: Data, seeding: Bool) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        let newLines =
            text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> LogLine in
                defer { nextID += 1 }
                return LogLine(id: nextID, text: String(line), kind: Self.classify(String(line)))
            }
        lines.append(contentsOf: newLines)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    /// Bucket a log line for color-coding. Order matters: errors win over the rest.
    static func classify(_ line: String) -> LogLine.Kind {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("exit 1") || lower.contains("failed") {
            return .error
        }
        if lower.contains("llm url=") || lower.contains("complete(") || lower.contains("http") {
            return .llm
        }
        if lower.contains("run_shell") || lower.contains("write_file")
            || lower.contains("read_file") || lower.contains("list_dir")
        {
            return .tool
        }
        return .info
    }
}
