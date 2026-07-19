import Combine
import Foundation
import SwiftUI

// WS-M2: the log console's pure logic — line classification + syntax markup,
// the search model, error→remediation matching, and bounded on-disk reads for
// back-scrolling past LogTailer's 64 KB seed. Everything in this file is
// deterministic and unit-tested (LogStoreTests); the live state (tailers,
// follow-tail, the visible row list) belongs to LogConsoleModel, and the file
// watching stays in LogTailer.
//
// Privacy (invariant 12): these functions only *render* existing local tool
// logs (mlx-server.log, eldr-acp.log, the in-memory DiagnosticsLog). Nothing
// here writes, copies, or forwards log content anywhere.

// MARK: - Console rows

/// One console row: id stable across appends (SwiftUI diffing keeps unchanged
/// rows), text `\r`-normalized, classification precomputed once at ingest.
struct LogConsoleRow: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let lineClass: LogMarkup.LineClass

    /// @MainActor because classification is (see `LogMarkup.classify`) — which
    /// matches every producer: tailer ingest, the console model, job windows.
    @MainActor
    init(id: Int, rawText: String) {
        self.id = id
        self.text = Self.normalizingCarriageReturns(rawText)
        self.lineClass = LogMarkup.classify(text)
    }

    /// Terminal semantics for a line tailed from a FILE: a mid-line `\r` means
    /// everything before it was overdrawn, so keep the LAST segment (tqdm-style
    /// redraws collapse to their final state). Job panes get this live via
    /// `TerminalLineBuffer`; tailed files land here already joined into one line.
    static func normalizingCarriageReturns(_ raw: String) -> String {
        guard raw.contains("\r") else { return raw }
        var text = raw
        while text.hasSuffix("\r") { text.removeLast() }
        guard let last = text.split(separator: "\r", omittingEmptySubsequences: true).last
        else { return "" }
        return String(last)
    }
}

// MARK: - Syntax markup

/// Line classification + AttributedString styling for the console: timestamps,
/// log levels, HTTP access lines, Python tracebacks. Classification happens once
/// per line at ingest (`LogConsoleRow`); the attributed rendering happens per
/// visible row and folds in the current search highlights.
enum LogMarkup {

    enum Level: Equatable, Sendable {
        case error, warn, info, debug, none
    }

    struct LineClass: Equatable, Sendable {
        var level: Level = .none
        /// Python traceback shape (header or `  File "…"` frame) — styled like an
        /// error even when no level token appears on the line itself.
        var isTraceback = false
        /// HTTP access-line status (`"GET /v1/models HTTP/1.1" 200`), when present.
        var httpStatus: Int?
        /// Length (in Characters) of a leading timestamp, styled secondary.
        var timestampLength = 0
    }

    // Precompiled once — classify runs for every ingested line. @MainActor (not
    // just Sendable-annotated) because `Regex` is NOT Sendable in this SDK, and
    // every classification site already runs on the main actor (LogTailer
    // ingest, the console model, job windows) — isolation costs nothing here.
    // Leading timestamps: `2026-07-18 10:22:33,123`, ISO `T` form, `[bracketed]`,
    // or a bare `10:22:33` time.
    @MainActor private static let timestampRegex =
        #/^\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\]?/#
    @MainActor private static let bareTimeRegex = #/^\[?\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\]?/#
    /// BaseHTTPRequestHandler / uvicorn access lines: `"GET /path HTTP/1.1" 200`.
    @MainActor private static let httpRegex =
        #/"(?:GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS) [^"]*" (\d{3})/#
    /// The final line of a Python traceback: `SomeError: message` / `SomeException`.
    @MainActor private static let exceptionLineRegex =
        #/^[A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception|Interrupt)\b/#
    @MainActor private static let errorTokenRegex =
        #/\b(?:ERROR|CRITICAL|FATAL|error|failed|failure)\b/#
    @MainActor private static let warnTokenRegex = #/\b(?:WARNING|WARN|warning|deprecated)\b/#
    @MainActor private static let debugTokenRegex = #/\b(?:DEBUG|TRACE)\b/#
    @MainActor private static let infoTokenRegex = #/\bINFO\b/#

    @MainActor
    static func classify(_ line: String) -> LineClass {
        var lineClass = LineClass()

        if let match = line.prefixMatch(of: timestampRegex)
            ?? line.prefixMatch(of: bareTimeRegex)
        {
            lineClass.timestampLength = line.distance(
                from: line.startIndex, to: match.range.upperBound)
        }

        if let match = line.firstMatch(of: httpRegex), let status = Int(match.output.1) {
            lineClass.httpStatus = status
        }

        if line.hasPrefix("Traceback (") || line.hasPrefix("  File \"") {
            lineClass.isTraceback = true
        }

        if lineClass.isTraceback || line.prefixMatch(of: exceptionLineRegex) != nil
            || line.firstMatch(of: errorTokenRegex) != nil
        {
            lineClass.level = .error
        } else if line.firstMatch(of: warnTokenRegex) != nil {
            lineClass.level = .warn
        } else if line.firstMatch(of: debugTokenRegex) != nil {
            lineClass.level = .debug
        } else if line.firstMatch(of: infoTokenRegex) != nil {
            lineClass.level = .info
        }

        // An HTTP access line's own status outranks token guessing: 5xx is an
        // error, 4xx a warning, 2xx/3xx routine even if the path contains "error".
        if let status = lineClass.httpStatus, !lineClass.isTraceback {
            switch status {
            case 500...: lineClass.level = .error
            case 400...: lineClass.level = .warn
            default: lineClass.level = .none
            }
        }

        return lineClass
    }

    /// Text color for a classified line (the console's base row styling).
    static func color(for lineClass: LineClass) -> Color {
        if lineClass.isTraceback { return .red }
        switch lineClass.level {
        case .error: return .red
        case .warn: return .orange
        case .debug: return .secondary
        case .info, .none: return .primary
        }
    }

    /// The fully-styled row: base level color, secondary timestamp prefix, an
    /// HTTP status tinted by its class, and search-match highlights (the current
    /// match visibly distinct from the rest).
    static func attributed(
        _ text: String, lineClass: LineClass,
        matches: [Range<String.Index>] = [], currentMatch: Range<String.Index>? = nil
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = color(for: lineClass)

        if lineClass.timestampLength > 0,
            let end = text.index(
                text.startIndex, offsetBy: lineClass.timestampLength, limitedBy: text.endIndex),
            let range = attributedRange(text.startIndex..<end, in: text, of: attributed)
        {
            attributed[range].foregroundColor = .secondary
        }

        if let status = lineClass.httpStatus, let statusRange = text.range(of: " \(status)"),
            let range = attributedRange(statusRange, in: text, of: attributed)
        {
            attributed[range].foregroundColor =
                status >= 500 ? .red : status >= 400 ? .orange : .green
        }

        for match in matches {
            guard let range = attributedRange(match, in: text, of: attributed) else { continue }
            attributed[range].backgroundColor = Color.yellow.opacity(0.30)
        }
        if let currentMatch,
            let range = attributedRange(currentMatch, in: text, of: attributed)
        {
            attributed[range].backgroundColor = Color.orange.opacity(0.55)
        }
        return attributed
    }

    private static func attributedRange(
        _ range: Range<String.Index>, in text: String, of attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        Range(NSRange(range, in: text), in: attributed)
    }
}

// MARK: - Search model

struct LogSearchOptions: Equatable, Sendable {
    var caseSensitive = false
    var isRegex = false
}

/// One search hit: which row, and where in that row's text.
struct LogSearchMatch: Equatable, Sendable {
    let rowID: Int
    let range: Range<String.Index>
}

enum LogSearch {

    /// Compile the query once per search pass. `nil` = invalid regex (the UI
    /// shows the field as invalid); a non-regex query never fails.
    static func compile(query: String, options: LogSearchOptions) -> CompiledQuery? {
        guard !query.isEmpty else { return CompiledQuery(kind: .empty) }
        if options.isRegex {
            guard var regex = try? Regex(query) else { return nil }
            if !options.caseSensitive { regex = regex.ignoresCase() }
            return CompiledQuery(kind: .regex(regex))
        }
        return CompiledQuery(kind: .plain(query, caseSensitive: options.caseSensitive))
    }

    /// Deliberately NOT Sendable: `Regex<AnyRegexOutput>` isn't, so compiled
    /// queries stay inside the isolation they were built in. Anything that
    /// searches off the main actor passes the (Sendable) query string + options
    /// across and compiles on its side — see `LogBackscroll.searchOnDisk`.
    struct CompiledQuery {
        enum Kind {
            case empty
            case plain(String, caseSensitive: Bool)
            case regex(Regex<AnyRegexOutput>)
        }
        let kind: Kind

        var isEmpty: Bool { if case .empty = kind { return true }; return false }

        /// Non-overlapping match ranges within one line (empty ranges dropped —
        /// a zero-width regex like `a*` must not produce phantom highlights).
        func ranges(in text: String) -> [Range<String.Index>] {
            switch kind {
            case .empty:
                return []
            case .plain(let needle, let caseSensitive):
                var ranges: [Range<String.Index>] = []
                var from = text.startIndex
                let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                while from < text.endIndex,
                    let found = text.range(of: needle, options: options, range: from..<text.endIndex)
                {
                    ranges.append(found)
                    from = found.upperBound
                }
                return ranges
            case .regex(let regex):
                return text.matches(of: regex).map(\.range).filter { !$0.isEmpty }
            }
        }
    }

    /// All matches across the rows, in row order. `nil` = the query didn't compile.
    static func matches(
        in rows: [LogConsoleRow], query: String, options: LogSearchOptions
    ) -> [LogSearchMatch]? {
        guard let compiled = compile(query: query, options: options) else { return nil }
        guard !compiled.isEmpty else { return [] }
        var all: [LogSearchMatch] = []
        for row in rows {
            for range in compiled.ranges(in: row.text) {
                all.append(LogSearchMatch(rowID: row.id, range: range))
            }
        }
        return all
    }

    /// Next/prev navigation with wraparound. `nil` in = start from the ends;
    /// `nil` out = no matches to step through.
    static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return forward ? (current + 1) % count : (current - 1 + count) % count
    }
}

// MARK: - Error → remediation

/// A plain-language fix chip for a known failure pattern in the logs.
struct LogRemediation: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let fix: String
}

enum LogRemediationCatalog {

    /// Known patterns, most-specific first: a CacheNotFound traceback also
    /// contains "Exception in thread" on an earlier line, so the generic
    /// thread-crash entry stays LAST and per-line matching runs in this order.
    static let all: [(marker: String, caseSensitive: Bool, hint: LogRemediation)] = [
        (
            "ModuleNotFoundError: No module named 'mlx_lm'", true,
            LogRemediation(
                id: "env-broken",
                title: "The MLX environment is broken",
                fix:
                    "Repair it from the MLX tab — the environment chip's ⋯ menu ▸ Update mlx-lm reinstalls the toolkit."
            )
        ),
        (
            "CacheNotFound", true,
            LogRemediation(
                id: "cache-missing",
                title: "The Hugging Face cache folder is missing",
                fix:
                    "Download any model in MLX ▸ Models to recreate the cache folder, then restart the server."
            )
        ),
        (
            "HFValidationError", true,
            LogRemediation(
                id: "bad-model-id",
                title: "The model id or path isn't valid",
                fix:
                    "Set Model in MLX ▸ Server to a Hugging Face id (owner/name) or an absolute model folder path, then restart."
            )
        ),
        (
            "No safetensors found", true,
            LogRemediation(
                id: "wrong-format",
                title: "This model isn't MLX format",
                fix:
                    "mlx_lm can't load GGUF or other runtimes' builds — download an MLX build instead (mlx-community or lmstudio-community publish them)."
            )
        ),
        (
            "address already in use", false,
            LogRemediation(
                id: "port-taken",
                title: "The port is already taken",
                fix:
                    "Another server holds this port (LM Studio?). Stop it there, or change Port in MLX ▸ Server and press Start."
            )
        ),
        (
            "Exception in thread", true,
            LogRemediation(
                id: "thread-crash",
                title: "A server thread crashed",
                fix:
                    "Usually the model failed to load — the traceback names the cause. Check Model in MLX ▸ Server, then restart."
            )
        ),
    ]

    static func hint(for line: String) -> LogRemediation? {
        for entry in all {
            if entry.caseSensitive {
                if line.contains(entry.marker) { return entry.hint }
            } else if line.range(of: entry.marker, options: [.caseInsensitive]) != nil {
                return entry.hint
            }
        }
        return nil
    }

    /// The most recent hint in the lines (scanned from the end) — the console
    /// shows one chip for the latest recognized failure.
    static func latestHint(in lines: [String]) -> LogRemediation? {
        for line in lines.reversed() {
            if let hint = hint(for: line) { return hint }
        }
        return nil
    }
}

// MARK: - On-disk back-scroll + stream search

/// Bounded reads of a log FILE outside the tailer's in-memory window: "Load
/// older" chunks walking backwards from the seed, and a stream search over the
/// on-disk region the window can't see. Pure functions over a path — callers
/// run them off the main actor (they do file I/O).
enum LogBackscroll {

    struct Chunk: Equatable, Sendable {
        /// Complete lines, oldest first (empty lines omitted, matching the tailer).
        let lines: [String]
        /// Byte offset of the first returned line — the next older read ends here.
        /// `startOffset == 0` means the file's beginning was reached.
        let startOffset: UInt64
    }

    /// Read up to `maxBytes` ending just before `endOffset`, aligned to a line
    /// start (a torn head line is dropped, exactly like the tailer's seed). Nil
    /// when there's nothing before `endOffset` or the file can't be read.
    static func readChunk(
        path: String, endingAt endOffset: UInt64, maxBytes: Int = 65_536
    ) -> Chunk? {
        guard endOffset > 0, maxBytes > 0 else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let start = endOffset > UInt64(maxBytes) ? endOffset - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            var data = try? handle.read(upToCount: Int(endOffset - start)), !data.isEmpty
        else { return nil }

        var firstLineOffset = start
        if start > 0 {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
                // One giant line fills the whole chunk — nothing line-aligned to
                // show. Report "no progress" so the caller stops asking.
                return Chunk(lines: [], startOffset: endOffset)
            }
            let dropped = data.distance(from: data.startIndex, to: newline) + 1
            data = data[data.index(after: newline)...]
            firstLineOffset = start + UInt64(dropped)
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return Chunk(lines: lines, startOffset: firstLineOffset)
    }

    struct DiskSearchResult: Equatable, Sendable {
        /// Occurrences (not lines) found in the scanned region.
        let matchCount: Int
        /// Line-start byte offset of the EARLIEST matching line — "load older
        /// until here" reaches every reported match. Nil when nothing matched.
        let earliestMatchOffset: UInt64?
        /// True when the scan was bounded by `maxScanBytes` and older bytes exist
        /// that were never examined.
        let truncated: Bool
    }

    /// Stream-search the file region BEFORE `endOffset` (the part the in-memory
    /// window doesn't cover), newest-bounded at `maxScanBytes`. Reads in fixed
    /// chunks, carrying partial lines across boundaries, so an 8 MB scan never
    /// holds more than one chunk + one line in memory.
    static func searchOnDisk(
        path: String, query: String, options: LogSearchOptions,
        before endOffset: UInt64, maxScanBytes: Int = 8 << 20,
        chunkBytes: Int = 262_144
    ) -> DiskSearchResult {
        guard endOffset > 0,
            let compiled = LogSearch.compile(query: query, options: options),
            !compiled.isEmpty,
            let handle = FileHandle(forReadingAtPath: path)
        else { return DiskSearchResult(matchCount: 0, earliestMatchOffset: nil, truncated: false) }
        defer { try? handle.close() }

        var scanStart: UInt64 = 0
        var truncated = false
        if endOffset > UInt64(maxScanBytes) {
            scanStart = endOffset - UInt64(maxScanBytes)
            truncated = true
        }
        guard (try? handle.seek(toOffset: scanStart)) != nil else {
            return DiskSearchResult(matchCount: 0, earliestMatchOffset: nil, truncated: false)
        }

        var matchCount = 0
        var earliest: UInt64?
        var carry = Data()
        /// Byte offset of `carry`'s first byte.
        var carryOffset = scanStart
        var remaining = endOffset - scanStart
        var droppedTornHead = scanStart == 0  // nothing to drop at BOF

        func scanLine(_ lineData: Data, at offset: UInt64) {
            guard !lineData.isEmpty else { return }
            let line = String(decoding: lineData, as: UTF8.self)
            let hits = compiled.ranges(in: line).count
            guard hits > 0 else { return }
            matchCount += hits
            if earliest == nil { earliest = offset }
        }

        while remaining > 0 {
            let want = Int(min(UInt64(chunkBytes), remaining))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            carry.append(chunk)
            // Split complete lines out of the carry buffer.
            while let newline = carry.firstIndex(of: UInt8(ascii: "\n")) {
                let lineLength = carry.distance(from: carry.startIndex, to: newline)
                let lineData = carry.subdata(
                    in: carry.startIndex..<carry.index(carry.startIndex, offsetBy: lineLength))
                let lineOffset = carryOffset
                carry.removeSubrange(
                    carry.startIndex...carry.index(carry.startIndex, offsetBy: lineLength))
                carryOffset += UInt64(lineLength) + 1
                if droppedTornHead {
                    scanLine(lineData, at: lineOffset)
                } else {
                    droppedTornHead = true  // torn head line: skip, like readChunk
                }
            }
        }
        // The final carry is the line that runs up to endOffset (the in-memory
        // window's first line starts there, so a trailing newline normally ends
        // the region and the carry is empty).
        if droppedTornHead, !carry.isEmpty {
            scanLine(carry, at: carryOffset)
        }
        return DiskSearchResult(
            matchCount: matchCount, earliestMatchOffset: earliest, truncated: truncated)
    }
}

// MARK: - Console sources

/// What a console can show: the two file-backed tool logs, or the in-memory
/// diagnostics bus. Codable+Hashable because "Open as window" routes a source
/// value through a `WindowGroup(for:)` scene.
enum LogConsoleSource: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case mlxServer
    case agent
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mlxServer: return "MLX server"
        case .agent: return "Agent (eldr-acp)"
        case .diagnostics: return "Diagnostics"
        }
    }

    /// On-disk log file, nil for the in-memory diagnostics source. Paths are
    /// parameterized so tests point a model at temp files, never the real
    /// config dir. (@MainActor: `MLXService.serverLogPath` lives on a MainActor
    /// class, and every caller — model, view — is main-isolated anyway.)
    @MainActor
    func filePath(paths: ConfigPaths) -> String? {
        switch self {
        case .mlxServer: return MLXService.serverLogPath(paths: paths)
        case .agent: return paths.logFile
        case .diagnostics: return nil
        }
    }
}

// MARK: - Console model

/// The live state behind ONE console surface (the MLX tab's embedded pane, the
/// Logs tab, an expanded sheet, a standalone window). Each surface owns its own
/// model — and its own `LogTailer` — so visibility drives file watching per
/// surface, and nothing couples to `MLXService.serverLog` (whose lifecycle
/// belongs to the kill-switch and the failure scan, not to what the user is
/// currently looking at).
///
/// Rows ACCUMULATE across tailer publishes (up to `maxRows`), so the console's
/// scrollback outlives the tailer's own 2000-line retention window; a tailer
/// `fileGeneration` change (rotation / oversized resume gap) resets the history
/// because the accumulated lines no longer join up with the file.
@MainActor
final class LogConsoleModel: ObservableObject {

    static let maxRows = 10_000

    @Published private(set) var source: LogConsoleSource
    @Published private(set) var rows: [LogConsoleRow] = []
    /// Latest recognized failure (dismissable; a DIFFERENT failure re-arms it).
    @Published private(set) var remediation: LogRemediation?
    /// Sticks the view to the newest rows. Searching suspends the stickiness
    /// (`searchActive`) — match navigation and auto-scroll would fight.
    @Published var followTail = true
    @Published var wrapLines = true

    // Search state. The view binds the query/options; matches recompute
    // debounced on edits and inline on row batches while a search is active.
    @Published var query = ""
    @Published var caseSensitive = false
    @Published var useRegex = false
    @Published private(set) var queryInvalid = false
    @Published private(set) var matchesByRow: [Int: [Range<String.Index>]] = [:]
    @Published private(set) var matchCount = 0
    @Published private(set) var currentMatch: LogSearchMatch?
    /// 1-based position for the "3 of 17" label; 0 when nothing is current.
    @Published private(set) var currentMatchOrdinal = 0

    var searchActive: Bool { !query.isEmpty }

    private var orderedMatches: [LogSearchMatch] = []
    private var currentIndex: Int?
    private var tailer: LogTailer?
    private var lastIngestedID = -1
    private var knownGeneration = 0
    private var started = false
    private var dismissedRemediationID: String?
    private var cancellables: Set<AnyCancellable> = []
    private let paths: ConfigPaths
    private let diagnostics: DiagnosticsLog

    /// The file behind the current source (Reveal in Finder target); nil for
    /// the in-memory diagnostics source.
    var currentFilePath: String? { source.filePath(paths: paths) }

    init(
        source: LogConsoleSource, paths: ConfigPaths = .standard,
        diagnostics: DiagnosticsLog = .shared
    ) {
        self.source = source
        self.paths = paths
        self.diagnostics = diagnostics
        attach(to: source)
        rebindSearchDebounce()
    }

    // MARK: Lifecycle

    func start() {
        started = true
        tailer?.start()
        // The diagnostics subscription is gated on `started` (a hidden console
        // must not rebuild 500 rows per event) — catch up now.
        if source == .diagnostics { rebuildFromDiagnostics(diagnostics.events) }
    }

    func stop() {
        started = false
        tailer?.stop()
    }

    /// Swap what this console shows (the source picker). Tears down the old
    /// source's watcher and state, keeps the search query (searching the same
    /// term across sources is the common flow when hunting a failure).
    func switchSource(_ newSource: LogConsoleSource) {
        guard newSource != source else { return }
        tailer?.stop()
        tailer = nil
        cancellables.removeAll()
        source = newSource
        resetContent()
        attach(to: newSource)
        rebindSearchDebounce()
        if started { tailer?.start() }
        recomputeMatches(resetPosition: true)
    }

    /// Clear the source: file logs truncate on disk (the tailer's own Clear
    /// semantics), diagnostics clears the in-memory bus.
    func clear() {
        switch source {
        case .mlxServer, .agent:
            tailer?.clear()
            // The tailer bumps its generation on the reseed; drop our copy now
            // so the view empties immediately rather than on the next publish.
            resetContent()
        case .diagnostics:
            diagnostics.clear()
            resetContent()
        }
    }

    var allText: String { rows.map(\.text).joined(separator: "\n") }

    func dismissRemediation() {
        dismissedRemediationID = remediation?.id
        remediation = nil
    }

    // MARK: Search navigation

    func stepMatch(forward: Bool) {
        currentIndex = LogSearch.step(from: currentIndex, count: orderedMatches.count, forward: forward)
        syncCurrentMatch()
    }

    // MARK: Wiring

    private func attach(to source: LogConsoleSource) {
        switch source {
        case .mlxServer, .agent:
            guard let path = source.filePath(paths: paths) else { return }
            let tailer = LogTailer(path: path)
            self.tailer = tailer
            knownGeneration = tailer.fileGeneration
            tailer.$lines
                .receive(on: RunLoop.main)
                .sink { [weak self] lines in self?.ingest(lines) }
                .store(in: &cancellables)
        case .diagnostics:
            diagnostics.$events
                .receive(on: RunLoop.main)
                .sink { [weak self] events in self?.rebuildFromDiagnostics(events) }
                .store(in: &cancellables)
        }
    }

    /// Debounced re-search on query/option edits (typing must not scan 10k rows
    /// per keystroke); dropFirst skips the initial published values. Called from
    /// init AND after `switchSource` clears `cancellables` (killing the old
    /// source's subscription takes this pipeline with it).
    private func rebindSearchDebounce() {
        Publishers.CombineLatest3($query, $caseSensitive, $useRegex)
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.recomputeMatches(resetPosition: true) }
            .store(in: &cancellables)
    }

    private func resetContent() {
        rows = []
        lastIngestedID = -1
        remediation = nil
        dismissedRemediationID = nil
        orderedMatches = []
        matchesByRow = [:]
        matchCount = 0
        currentIndex = nil
        currentMatch = nil
        currentMatchOrdinal = 0
    }

    // MARK: Ingest — file tailer

    private func ingest(_ lines: [LogLine]) {
        guard let tailer else { return }
        if tailer.fileGeneration != knownGeneration {
            // Rotation or reseed: the accumulated history no longer joins up
            // with what the tailer now shows.
            knownGeneration = tailer.fileGeneration
            resetContent()
        }
        let fresh = lines.filter { $0.id > lastIngestedID }
        guard !fresh.isEmpty else { return }
        lastIngestedID = fresh.last?.id ?? lastIngestedID
        appendRows(fresh.map { LogConsoleRow(id: $0.id, rawText: $0.text) })
    }

    // MARK: Ingest — diagnostics bus

    private func rebuildFromDiagnostics(_ events: [DiagnosticsLog.Event]) {
        // Only while visible — the bus publishes per event, and an invisible
        // console rebuilding its rows for each one is pure waste (start() does
        // a catch-up rebuild when the surface comes back).
        guard started else { return }
        // The bus is small (cap 500) and publishes per event — a full rebuild
        // keeps ids aligned with its head-trimming without bookkeeping.
        rows = events.enumerated().map {
            LogConsoleRow(id: $0.offset, rawText: Self.formatDiagnostics($0.element))
        }
        refreshRemediation()
        if searchActive { recomputeMatches(resetPosition: false) }
    }

    @MainActor private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Render a diagnostics event as a log line. The severity becomes a level
    /// TOKEN so the shared markup styles it like any other log — no special
    /// diagnostics rendering path.
    static func formatDiagnostics(_ event: DiagnosticsLog.Event) -> String {
        let time = timeFormatter.string(from: event.at)
        let severity: String
        switch event.severity {
        case .error: severity = "ERROR "
        case .warn: severity = "WARNING "
        case .info, .success: severity = ""
        }
        let detail = event.detail.isEmpty ? "" : " — \(event.detail)"
        return "\(time) \(severity)[\(event.category.rawValue)] \(event.title)\(detail)"
    }

    // MARK: Shared append path

    private func appendRows(_ newRows: [LogConsoleRow]) {
        guard !newRows.isEmpty else { return }
        var updated = rows
        updated.append(contentsOf: newRows)
        if updated.count > Self.maxRows {
            updated.removeFirst(updated.count - Self.maxRows)
        }
        rows = updated
        refreshRemediation()
        if searchActive { recomputeMatches(resetPosition: false) }
    }

    private func refreshRemediation() {
        // Only the recent past matters for the chip — a failure from a thousand
        // lines ago shouldn't hover over a now-healthy log.
        let recent = rows.suffix(200).map(\.text)
        guard let hint = LogRemediationCatalog.latestHint(in: recent) else {
            if remediation != nil { remediation = nil }
            return
        }
        if hint.id == dismissedRemediationID { return }
        if remediation != hint { remediation = hint }
    }

    // MARK: Search

    private func recomputeMatches(resetPosition: Bool) {
        let options = LogSearchOptions(caseSensitive: caseSensitive, isRegex: useRegex)
        guard let all = LogSearch.matches(in: rows, query: query, options: options) else {
            queryInvalid = true
            orderedMatches = []
            matchesByRow = [:]
            matchCount = 0
            currentIndex = nil
            syncCurrentMatch()
            return
        }
        queryInvalid = false
        orderedMatches = all
        matchCount = all.count
        var byRow: [Int: [Range<String.Index>]] = [:]
        for match in all { byRow[match.rowID, default: []].append(match.range) }
        matchesByRow = byRow
        if resetPosition {
            currentIndex = all.isEmpty ? nil : 0
        } else if let index = currentIndex, index >= all.count {
            currentIndex = all.isEmpty ? nil : all.count - 1
        }
        syncCurrentMatch()
    }

    private func syncCurrentMatch() {
        if let index = currentIndex, index < orderedMatches.count {
            currentMatch = orderedMatches[index]
            currentMatchOrdinal = index + 1
        } else {
            currentMatch = nil
            currentMatchOrdinal = 0
        }
    }
}
