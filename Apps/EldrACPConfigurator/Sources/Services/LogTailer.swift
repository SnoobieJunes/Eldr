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
@MainActor
final class LogTailer: ObservableObject {

    @Published private(set) var lines: [LogLine] = []

    private let path: String
    /// Cap retained lines so a long-running session doesn't grow unbounded in memory.
    private let maxLines = 2000

    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var nextID = 0
    private let queue = DispatchQueue(label: "chat.eldr.configurator.logtailer")

    init(path: String) { self.path = path }

    deinit { source?.cancel() }

    // MARK: - Lifecycle

    func start() {
        guard source == nil else { return }
        openAndPrime()
    }

    func stop() {
        source?.cancel()
        source = nil
        try? handle?.close()
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

        // Seed with the existing tail so the view isn't empty on open.
        let existing = (try? h.readToEnd()) ?? Data()
        offset = (try? h.offset()) ?? UInt64(existing.count)
        ingest(existing, seeding: true)

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: h.fileDescriptor, eventMask: [.write, .extend, .rename, .delete],
            queue: queue)
        src.setEventHandler { [weak self] in
            let mask = src.data
            Task { @MainActor [weak self] in self?.handleEvent(mask) }
        }
        src.setCancelHandler { [weak self] in
            // The cancel handler owns closing the fd to avoid races with the source.
            Task { @MainActor in self?.handle = nil }
        }
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
