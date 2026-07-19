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
///
/// WS-M0 publish hygiene: appended lines are BATCHED — ingest accumulates them in
/// `pendingLines` and `lines` publishes at most once per `flushInterval` (~4 Hz),
/// so a chatty writer can't invalidate every observing view per line. Seeding at
/// (re)open stays one synchronous publish.
@MainActor
final class LogTailer: ObservableObject {

    @Published private(set) var lines: [LogLine] = []

    /// True while the dispatch source is watching the file (false after `stop()` —
    /// the observable "tailer is idle" signal the MLX kill-switch tests assert).
    var isTailing: Bool { source != nil }

    /// WS-M2: byte offset of the first line the current seed retained — the
    /// anchor the log console's "Load older" back-scroll reads BEFORE. Only valid
    /// for the current `fileGeneration`.
    private(set) var earliestSeedOffset: UInt64 = 0

    /// WS-M2: bumped whenever a fresh tail seed REPLACES earlier content
    /// (rotation, or a stop/start gap too large to resume through). The console
    /// accumulates lines across publishes; a generation change tells it the
    /// accumulated history no longer matches the file and must be dropped.
    private(set) var fileGeneration = 0

    private let path: String
    /// Cap retained lines so a long-running session doesn't grow unbounded in memory.
    private let maxLines = 2000
    /// Cap how much of an EXISTING file the tailer reads when it (re)opens. A
    /// long-lived server log reaches hundreds of KB, and `readToEnd()` of the whole
    /// file on the main actor visibly froze the MLX tab on first open — seeding from
    /// the last 64 KB keeps open instant. Incremental delta reads stay unbounded
    /// (they're the few bytes just appended).
    private let maxSeedBytes: UInt64
    /// Batch window for publishing appended lines (~4 Hz by default).
    private let flushInterval: Duration

    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var nextID = 0
    /// Ingested-but-not-yet-published lines (already counted in `offset`/`nextID`).
    private var pendingLines: [LogLine] = []
    private var flushTask: Task<Void, Never>?

    init(
        path: String, maxSeedBytes: UInt64 = 65_536,
        flushInterval: Duration = .milliseconds(250)
    ) {
        self.path = path
        self.maxSeedBytes = maxSeedBytes
        self.flushInterval = flushInterval
    }

    deinit {
        source?.cancel()
        flushTask?.cancel()
    }

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
        // Publish whatever already arrived: `offset` counts these lines, so the
        // resume path in openAndPrime() will NOT read them again — dropping them
        // here would lose them for good.
        flushPendingNow()
    }

    /// Truncate the log on disk and clear the view ("Clear" button).
    func clear() {
        stop()
        try? Data().write(to: URL(fileURLWithPath: path))
        lines.removeAll()
        offset = 0
        start()
    }

    var allText: String { (lines + pendingLines).map(\.text).joined(separator: "\n") }

    /// The id the NEXT ingested line will get — an "anything from now on" baseline
    /// for callers that classify lines by age (MLXService's launch-scoped failure
    /// scan). Counts still-unpublished pending lines too, unlike `lines.last?.id`.
    var nextLineID: Int { nextID }

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

        let size = (try? h.seekToEnd()) ?? 0
        if offset > 0, size >= offset, size - offset <= maxSeedBytes {
            // Re-opened mid-session (the owning view was hidden and re-shown):
            // resume from where the last stop() left off. Re-seeding the tail here
            // used to APPEND a second copy of everything already shown — duplicate
            // history on every tab switch. A gap larger than maxSeedBytes falls
            // through to a fresh bounded tail seed instead.
            try? h.seek(toOffset: offset)
            let delta = (try? h.readToEnd()) ?? Data()
            offset = (try? h.offset()) ?? size
            ingest(delta, seeding: true)
        } else {
            // First open, rotation (file shrank / offset reset), or a too-large
            // resume gap: seed with the existing TAIL (bounded) so the view isn't
            // empty on open.
            if size < offset { offset = 0 }
            let seedStart = size > maxSeedBytes ? size - maxSeedBytes : 0
            try? h.seek(toOffset: seedStart)
            var existing = (try? h.readToEnd()) ?? Data()
            var firstLineOffset = seedStart
            if seedStart > 0, let firstNewline = existing.firstIndex(of: UInt8(ascii: "\n")) {
                // Started mid-line: drop the partial first line.
                let dropped = existing.distance(from: existing.startIndex, to: firstNewline) + 1
                existing = existing[existing.index(after: firstNewline)...]
                firstLineOffset = seedStart + UInt64(dropped)
            }
            // Cap the seed by the retention cap IN DATA SPACE too: a 64 KB seed
            // of short lines can exceed maxLines, and `publish` would trim the
            // head AFTER ingest — leaving `earliestSeedOffset` pointing below
            // the first line actually kept, so WS-M2's "Load older" would
            // splice older history in with a silent gap at the seam.
            let boundedStart = Self.tailLineStart(existing, maxLines: maxLines)
            if boundedStart > existing.startIndex {
                firstLineOffset += UInt64(
                    existing.distance(from: existing.startIndex, to: boundedStart))
                existing = existing[boundedStart...]
            }
            // A fresh tail seed that REPLACES earlier content (rotation, or a
            // stop/start gap too large to resume through) starts a new
            // generation: back-scroll anchors from the old file/window are void.
            if nextID > 0 { fileGeneration += 1 }
            earliestSeedOffset = firstLineOffset
            offset = (try? h.offset()) ?? size
            ingest(existing, seeding: true)
        }

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

    /// Start index of the last `maxLines` PHYSICAL lines in `data` (a trailing
    /// newline terminates the final line; a partial final line counts as one).
    /// Empty lines count here even though ingest's split omits them from
    /// display — what matters is that the returned index is a true line start,
    /// so byte offsets derived from it stay exact.
    static func tailLineStart(_ data: Data, maxLines: Int) -> Data.Index {
        guard maxLines > 0, !data.isEmpty else { return data.startIndex }
        var position = data.index(before: data.endIndex)
        if data[position] == UInt8(ascii: "\n") {
            guard position > data.startIndex else { return data.startIndex }
            position = data.index(before: position)
        }
        var linesSeen = 0
        while true {
            if data[position] == UInt8(ascii: "\n") {
                linesSeen += 1
                if linesSeen == maxLines { return data.index(after: position) }
            }
            guard position > data.startIndex else { return data.startIndex }
            position = data.index(before: position)
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
        guard !newLines.isEmpty else { return }
        if seeding {
            // One synchronous batch at (re)open. Pending is empty on every current
            // path (stop() flushes before openAndPrime runs) — fold it in first
            // anyway so line order could never invert if that changes.
            publish(pendingLines + newLines)
            pendingLines.removeAll()
        } else {
            pendingLines.append(contentsOf: newLines)
            scheduleFlush()
        }
    }

    // MARK: - Batched publishing

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let interval = self?.flushInterval else { return }
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.publishPending()
        }
    }

    private func flushPendingNow() {
        flushTask?.cancel()
        flushTask = nil
        publishPending()
    }

    private func publishPending() {
        guard !pendingLines.isEmpty else { return }
        publish(pendingLines)
        pendingLines.removeAll()
    }

    /// Append + trim as ONE `lines` assignment — exactly one objectWillChange per
    /// batch, even when the retention cap trims the head.
    private func publish(_ newLines: [LogLine]) {
        guard !newLines.isEmpty else { return }
        var updated = lines
        updated.append(contentsOf: newLines)
        if updated.count > maxLines { updated.removeFirst(updated.count - maxLines) }
        lines = updated
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
