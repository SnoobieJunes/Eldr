import AppKit
import SwiftUI

/// Live, color-coded view of `eldr-acp.log` (what the launcher tees stderr into).
struct LogView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @StateObject private var tailer: LogTailer

    /// WS-M0: rendering is bounded like the MLX pane — the tailer retains up to
    /// 2000 lines (Copy all still copies them all), but only this many rows are
    /// laid out, so a chatty agent session can't re-layout thousands of Texts per
    /// (batched) append. WS-M2's reusable console replaces this view.
    private static let maxRenderedLines = 300

    init() {
        // The tailer needs the log path before the environment is available, so it's
        // built from the standard paths here (same path the launcher writes to).
        _tailer = StateObject(wrappedValue: LogTailer(path: ConfigPaths.standard.logFile))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent log").font(.headline)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tailer.allText, forType: .string)
                }
                Button("Clear") { tailer.clear() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if tailer.lines.isEmpty {
                            Text("No log output yet. Run a prompt from Xcode (or the Test Chat) and lines will stream in here.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(tailer.lines.suffix(Self.maxRenderedLines)) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .onChange(of: tailer.lines.count) { _, _ in
                    if let last = tailer.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .onAppear { tailer.start() }
        .onDisappear { tailer.stop() }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .llm: return .blue
        case .tool: return .purple
        case .error: return .red
        case .info: return .primary
        }
    }
}
