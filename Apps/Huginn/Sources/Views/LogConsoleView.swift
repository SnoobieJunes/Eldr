// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// WS-M2: the ONE reusable log console. Replaces the Logs tab's LogView and the
/// MLX tab's inline server-log pane; a source picker switches between Huginn's
/// existing log surfaces (mlx-server.log / eldr-acp.log / the diagnostics bus)
/// instead of each growing its own viewer. Styles: `.embedded` is the compact
/// in-tab pane (bounded render window, Expand affordances), `.full` fills its
/// container (Logs tab, the expanded sheet, the standalone window).
///
/// Perf discipline (WS-M0): the console observes only its own model — a log
/// batch re-evaluates this view, never the Form section hosting it. Rows render
/// in a LazyVStack with stable ids; each row is an Equatable child, so a batch
/// append lays out the new rows and the (at most one) row whose highlight moved.
struct LogConsoleView: View {
    enum Style { case embedded, full }

    static let windowID = "log-console"
    /// Rendered rows in the embedded pane — the WS-M0 300-row bound. Full
    /// surfaces render the model's whole accumulation (LazyVStack keeps it lazy).
    private static let embeddedWindow = 300

    @StateObject private var model: LogConsoleModel
    private let style: Style
    @State private var sheetShown = false
    @Environment(\.openWindow) private var openWindow

    init(source: LogConsoleSource, style: Style) {
        _model = StateObject(wrappedValue: LogConsoleModel(source: source))
        self.style = style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .embedded ? 6 : 0) {
            toolbar
                .padding(.horizontal, style == .full ? 12 : 0)
                .padding(.vertical, style == .full ? 8 : 0)
            if style == .full { Divider() }
            if let hint = model.remediation {
                remediationChip(hint)
                    .padding(.horizontal, style == .full ? 12 : 0)
                    .padding(.top, style == .full ? 8 : 0)
            }
            pane
                .padding(.horizontal, style == .full ? 12 : 0)
                .padding(.vertical, style == .full ? 10 : 0)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $sheetShown) { LogConsoleSheet(source: model.source) }
    }

    // MARK: Toolbar

    private var sourceBinding: Binding<LogConsoleSource> {
        Binding(get: { model.source }, set: { model.switchSource($0) })
    }

    /// The fixed sources plus — when this console is showing one — the
    /// per-connection Buzz gateway log, which isn't enumerable (WS-I7). Without
    /// it the Picker's selection would have no matching row and render blank.
    private var pickerSources: [LogConsoleSource] {
        var sources = LogConsoleSource.allCases
        if !sources.contains(model.source) { sources.append(model.source) }
        return sources
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 8) {
            if style == .full {
                Picker("Source", selection: sourceBinding) {
                    ForEach(pickerSources) { source in
                        Text(source.title).tag(source)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            searchCluster
            Spacer(minLength: 8)
            followToggle
            if style == .full {
                wrapToggle
                actionButtons
                Button {
                    openWindow(id: Self.windowID, value: model.source)
                } label: {
                    Image(systemName: "macwindow.badge.plus")
                }
                .help("Open as a separate window")
            } else {
                Button {
                    sheetShown = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Expand into a sheet")
                overflowMenu
            }
        }
        .controlSize(.small)
    }

    private var searchCluster: some View {
        HStack(spacing: 4) {
            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: style == .embedded ? 170 : 240)
                .onSubmit { model.stepMatch(forward: true) }
            if model.queryInvalid {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help("Not a valid regular expression")
            } else if model.searchActive {
                Text(
                    model.matchCount == 0
                        ? "0" : "\(model.currentMatchOrdinal)/\(model.matchCount)"
                )
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button {
                model.stepMatch(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.matchCount == 0)
            .help("Previous match")
            Button {
                model.stepMatch(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(model.matchCount == 0)
            .help("Next match")
            Toggle("Aa", isOn: $model.caseSensitive)
                .toggleStyle(.button)
                .help("Match case")
            Toggle(".*", isOn: $model.useRegex)
                .toggleStyle(.button)
                .help("Regular-expression search")
        }
    }

    private var followToggle: some View {
        Toggle(isOn: $model.followTail) {
            Image(systemName: "arrow.down.to.line")
        }
        .toggleStyle(.button)
        .help("Follow new output (paused while a search is active)")
    }

    private var wrapToggle: some View {
        Toggle(isOn: $model.wrapLines) {
            Image(systemName: "arrow.turn.down.left")
        }
        .toggleStyle(.button)
        .help("Wrap long lines (off = scroll horizontally)")
    }

    @ViewBuilder private var actionButtons: some View {
        Button {
            copyAll()
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .help("Copy all")
        Button {
            model.clear()
        } label: {
            Image(systemName: "trash")
        }
        .help(model.source == .diagnostics ? "Clear the events" : "Clear the log file on disk")
        if let path = model.currentFilePath {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal the log file in Finder")
        }
    }

    /// The embedded pane keeps the toolbar compact: everything secondary lives
    /// in one ⋯ menu (the same pattern as the MLX environment chip).
    private var overflowMenu: some View {
        Menu {
            Picker("Source", selection: sourceBinding) {
                ForEach(pickerSources) { source in
                    Text(source.title).tag(source)
                }
            }
            Toggle("Wrap long lines", isOn: $model.wrapLines)
            Divider()
            Button("Copy all") { copyAll() }
            Button(
                model.source == .diagnostics ? "Clear events" : "Clear log file"
            ) { model.clear() }
            if let path = model.currentFilePath {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Divider()
            Button("Open as window") { openWindow(id: Self.windowID, value: model.source) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Log console actions")
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.allText, forType: .string)
    }

    // MARK: Remediation chip

    private func remediationChip(_ hint: LogRemediation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("\(hint.title) — \(hint.fix)", systemImage: "wrench.and.screwdriver")
                .font(.caption)
            Spacer()
            Button {
                model.dismissRemediation()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Dismiss hint")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Log pane

    private var visibleRows: [LogConsoleRow] {
        // The embedded 300-row bound is a streaming-perf measure, not a truth
        // bound: while a search is active it must yield, or match navigation
        // would "jump" to rows that aren't rendered (scrollTo on an absent id
        // is a silent no-op) while the count claims otherwise.
        if style == .embedded && !model.searchActive {
            return Array(model.rows.suffix(Self.embeddedWindow))
        }
        return model.rows
    }

    private var pane: some View {
        ScrollViewReader { proxy in
            ScrollView(model.wrapLines ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    olderControls
                    if visibleRows.isEmpty {
                        Text(emptyText)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(8)
                    }
                    ForEach(visibleRows) { row in
                        ConsoleRowView(
                            row: row,
                            matches: model.matchesByRow[row.id] ?? [],
                            currentRange: model.currentMatch?.rowID == row.id
                                ? model.currentMatch?.range : nil,
                            wrap: model.wrapLines
                        )
                        .equatable()
                        .id(row.id)
                    }
                }
                .padding(6)
                .frame(maxWidth: model.wrapLines ? .infinity : nil, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.rows.count) { _, _ in
                guard model.followTail, !model.searchActive, let last = model.rows.last
                else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .onChange(of: model.currentMatch) { _, newMatch in
                if let newMatch { proxy.scrollTo(newMatch.rowID, anchor: .center) }
            }
            .onChange(of: model.followTail) { _, on in
                if on, let last = model.rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: model.lastPrependSeamID) { _, seam in
                // After "Load older", pin the old top row to the bottom so the
                // freshly loaded chunk is what fills the view.
                if let seam { proxy.scrollTo(seam, anchor: .bottom) }
            }
        }
        .frame(minHeight: style == .embedded ? 220 : 240)
        .frame(maxHeight: style == .embedded ? 220 : .infinity)
        .border(.quaternary)
    }

    /// Top-of-scrollback affordances: back-scroll past the seed, and the
    /// on-disk search verdict for the region the console doesn't hold. Full
    /// style only — the embedded pane's render window would hide what a
    /// prepend loads; Expand is its route to the deep history.
    @ViewBuilder private var olderControls: some View {
        if style == .full,
            model.canLoadOlder || model.isLoadingOlder || model.loadOlderBroken
                || model.diskSearch != .idle
        {
            HStack(spacing: 8) {
                if model.isLoadingOlder {
                    ProgressView().controlSize(.mini)
                }
                if model.canLoadOlder {
                    Button("Load older") { model.loadOlder() }
                        .controlSize(.small)
                        .disabled(model.isLoadingOlder)
                        .help(
                            "Read the log file before what's shown — the console seeds from the file's last 64 KB."
                        )
                }
                switch model.diskSearch {
                case .found(let count, _):
                    Button("\(count) older match\(count == 1 ? "" : "es") on disk — load & jump") {
                        model.loadOlderToDiskMatch()
                    }
                    .controlSize(.small)
                    .disabled(model.isLoadingOlder || !model.canLoadOlder)
                case .searching:
                    Text("searching the file on disk…")
                        .font(.caption2).foregroundStyle(.secondary)
                case .noneFound:
                    Text("no older matches on disk")
                        .font(.caption2).foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
                if model.loadOlderBroken {
                    Text("older history unavailable here — Reveal in Finder for the full file")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyText: String {
        switch model.source {
        case .mlxServer:
            return "No server output yet — start the MLX server and its log streams in here."
        case .agent:
            return
                "No log output yet. Run a prompt from Xcode (or the Test Chat) and lines will stream in here."
        case .diagnostics:
            return
                "No agent activity yet — send a Test Chat message or drive the agent from your phone."
        case .buzzGateway(_, let name):
            return
                "Nothing from \(name) yet — the gateway logs its handshake with the workspace relay, every mention it answers, and any failure, in here."
        }
    }
}

/// One rendered row. Equatable so a batch append re-lays-out only the appended
/// rows (and the row whose search highlight moved) — never the whole window.
private struct ConsoleRowView: View, Equatable {
    let row: LogConsoleRow
    let matches: [Range<String.Index>]
    let currentRange: Range<String.Index>?
    let wrap: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.matches == rhs.matches
            && lhs.currentRange == rhs.currentRange && lhs.wrap == rhs.wrap
    }

    var body: some View {
        let text = Text(
            LogMarkup.attributed(
                row.text.isEmpty ? " " : row.text, lineClass: row.lineClass,
                matches: matches, currentMatch: currentRange)
        )
        .font(.system(.caption2, design: .monospaced))
        .textSelection(.enabled)
        if wrap {
            text.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            text.fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// The embedded pane's Expand target: the full console in a large sheet.
private struct LogConsoleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: LogConsoleSource

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log console — \(source.title)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            LogConsoleView(source: source, style: .full)
        }
        .frame(minWidth: 880, idealWidth: 1050, minHeight: 540, idealHeight: 680)
    }
}

/// Content of the standalone "Open as window" scene (HuginnApp registers the
/// WindowGroup; the routed value picks the source).
struct LogConsoleWindow: View {
    let source: LogConsoleSource

    var body: some View {
        LogConsoleView(source: source, style: .full)
            .navigationTitle("Log console — \(source.title)")
            .frame(minWidth: 700, minHeight: 400)
    }
}
