import PQRCACP  // WS-D: the shared CustomCommand chip model.
import SwiftUI

/// Phase D4 — the live INTERACTIVE terminal (PTY) a paired coding-agent node is running.
/// This is the project's highest-risk surface (a persistent interactive shell on the
/// user's Mac, driven from the phone), so the UI puts the KILL control front and center:
/// a prominent red "Stop" button that terminates the session at any time.
///
/// Append-only monospace output (the streamed combined stdout+stderr), a stdin field to
/// type into the live shell, and the Stop control. The output is agent text — display-only,
/// trusted no further than a bubble — and is NEVER persisted (the live stream is not
/// written at rest, CLAUDE.md inv. 12). Shown only for a coding-agent conversation while a
/// terminal is live.
struct ACPTerminalView: View {
    @Bindable var model: AppModel
    let conversationID: String
    let terminal: LiveACPTerminal

    @State private var stdin = ""
    @FocusState private var stdinFocused: Bool
    // H1: incremental ANSI cache. Parsing the whole (≤256 KB) buffer on every streamed chunk was
    // O(n²) and drove progressive frame drops; the renderer folds in only the newly-appended
    // output (carrying SGR state across chunks). Updated in `.onChange` — never inside `body`.
    @State private var renderer = ANSITerminalRenderer()
    @State private var renderedOutput = AttributedString(" ")
    // L2: dedupe resize reports. `.onChange(of: geo.size)` fires continuously during
    // keyboard/scroll animations; only send when the derived cols/rows actually change
    // so we don't spam the node over the relay.
    @State private var lastReportedSize: (cols: Int, rows: Int)?
    /// WS-D: the user's custom quick-command chips (per-silo, editable).
    @State private var customCommands: [CustomCommand] = []
    @State private var showCommandEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            outputView
            if terminal.closed {
                closedFooter
            } else {
                chipRow
                stdinRow
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                // Opaque dark fill (a terminal look) that also keeps the contrast auditor
                // a determinable background (A7).
                .fill(Color(.secondarySystemBackground)))
        .accessibilityIdentifier("acp-terminal")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(terminal.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // THE KILL CONTROL — prominent, always available while live. Terminates the
            // PTY's child process group + closes fds on the node.
            if !terminal.closed {
                Button(role: .destructive) {
                    Task { await model.stopACPTerminal(conversationID: conversationID) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("acp-terminal-stop")
                .accessibilityLabel("Stop terminal")
                .help("Kill this interactive shell on the Mac. The process and its children are terminated immediately.")
            }
        }
    }

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // ANSI SGR colors/bold/underline interpreted + stripped (feature 9);
                // display-only, never persisted (invariant 12). Rendered incrementally into
                // `renderedOutput` off the `body` path (H1) — see the `.onChange` below.
                Text(renderedOutput)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("acp-terminal-output-end")
            }
            .frame(minHeight: 120, maxHeight: 280)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.systemBackground)))
            // Report the view's size as terminal columns/rows so full-screen tools on
            // the node lay out to the phone (feature 9). Estimated from the caption
            // monospaced advance/line height.
            .overlay {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { reportSize(geo.size) }
                        .onChange(of: geo.size) { _, s in reportSize(s) }
                }
            }
            .onChange(of: terminal.output, initial: true) {
                // Fold only the newly-appended output into the cached AttributedString (H1),
                // then keep the newest output in view as it streams.
                renderedOutput = renderer.render(terminal.output.isEmpty ? " " : terminal.output)
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("acp-terminal-output-end", anchor: .bottom)
                }
            }
            .accessibilityIdentifier("acp-terminal-output")
        }
    }

    /// Estimate columns × rows from the view size and report them to the node.
    private func reportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let charWidth: CGFloat = 7.2   // ~caption monospaced advance
        let lineHeight: CGFloat = 15.0  // ~caption line height
        let cols = max(20, Int((size.width - 16) / charWidth))
        let rows = max(5, Int(size.height / lineHeight))
        guard lastReportedSize?.cols != cols || lastReportedSize?.rows != rows else { return }  // L2: only on actual change
        lastReportedSize = (cols, rows)
        Task { await model.resizeACPTerminal(cols: cols, rows: rows, conversationID: conversationID) }
    }

    /// A curated set of common shell commands, always offered regardless of what the
    /// node advertises — the node's `available_commands_update` (skills like `/spec`)
    /// may be empty or sparse, but "build/test/status" are useful in any shell.
    private static let curatedCommands = ["build", "test", "git status", "git diff", "ls", "clear"]

    /// WS1 — quick-action chips: the user's OWN custom chips first (WS-D:
    /// persisted, editable via the slider button), then the curated set, then
    /// whatever the node advertised for this session (`available_commands_update`,
    /// e.g. skills), then a `^Z` control chip. Each chip is just a shortcut for
    /// typing the same text / control byte into the live shell — same
    /// `sendACPTerminalInput`/`Control` paths the stdin field and ^C/^D use. A
    /// custom chip with auto-send OFF only fills the stdin field for editing.
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(customCommands) { command in
                    Button {
                        if command.autoSend {
                            Task {
                                await model.sendACPTerminalInput(
                                    command.text, conversationID: conversationID)
                            }
                        } else {
                            stdin = command.text
                            stdinFocused = true
                        }
                    } label: {
                        Text(command.label).font(.caption.monospaced())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.purple)
                    .accessibilityIdentifier("acp-terminal-custom-chip-\(command.label)")
                }
                ForEach(Self.curatedCommands, id: \.self) { cmd in
                    commandChip(cmd)
                }
                ForEach(model.acpCommandsByConversation[conversationID] ?? [], id: \.self) { cmd in
                    commandChip(cmd)
                }
                Button {
                    Task { await model.sendACPTerminalControl("\u{1A}", conversationID: conversationID) }
                } label: {
                    Text("^Z").font(.caption.weight(.bold).monospaced())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Send suspend (Control-Z)")
                .accessibilityIdentifier("acp-terminal-ctrl-z")
                // WS-D: edit the custom chips (add / reorder / delete).
                Button {
                    showCommandEditor = true
                } label: {
                    Image(systemName: customCommands.isEmpty ? "plus.circle" : "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit quick commands")
                .accessibilityIdentifier("acp-terminal-chip-editor")
            }
        }
        .sheet(isPresented: $showCommandEditor, onDismiss: {
            customCommands = AppSession.customCommands(siloID: model.siloID)
        }) {
            CustomCommandEditorView(siloID: model.siloID)
        }
        .onAppear { customCommands = AppSession.customCommands(siloID: model.siloID) }
    }

    private func commandChip(_ command: String) -> some View {
        Button {
            Task { await model.sendACPTerminalInput(command, conversationID: conversationID) }
        } label: {
            Text(command).font(.caption.monospaced())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("acp-terminal-chip-\(command)")
    }

    private var stdinRow: some View {
        HStack(spacing: 8) {
            // Interrupt / EOF controls (feature 9): send the raw control byte to the
            // PTY so the tty delivers SIGINT / EOF to the foreground job.
            Button {
                Task { await model.sendACPTerminalControl("\u{03}", conversationID: conversationID) }
            } label: {
                Text("^C").font(.caption.weight(.bold).monospaced())
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .accessibilityLabel("Send interrupt (Control-C)")
            .accessibilityIdentifier("acp-terminal-ctrl-c")
            Button {
                Task { await model.sendACPTerminalControl("\u{04}", conversationID: conversationID) }
            } label: {
                Text("^D").font(.caption.weight(.bold).monospaced())
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Send end-of-file (Control-D)")
            .accessibilityIdentifier("acp-terminal-ctrl-d")
            TextField("Type a command…", text: $stdin, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($stdinFocused)
                .onSubmit(submit)
                #if os(macOS) || targetEnvironment(macCatalyst)
                    // Mac: Return sends the line, Shift+Return inserts a newline.
                    .onKeyPress { press in
                        guard press.key == .return, !press.modifiers.contains(.shift)
                        else { return .ignored }
                        submit()
                        return .handled
                    }
                #endif
                .accessibilityIdentifier("acp-terminal-stdin")
            Button(action: submit) {
                Image(systemName: "return")
            }
            .disabled(stdin.isEmpty)
            .accessibilityLabel("Send to terminal")
        }
    }

    private var closedFooter: some View {
        HStack(spacing: 8) {
            Label(
                terminal.exitCode.map { "Terminal ended (exit \($0))" } ?? "Terminal ended",
                systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Dismiss") {
                model.dismissACPTerminal(conversationID: conversationID)
            }
            .font(.caption)
            .accessibilityIdentifier("acp-terminal-dismiss")
        }
    }

    private func submit() {
        let line = stdin
        guard !line.isEmpty else { return }
        stdin = ""
        Task { await model.sendACPTerminalInput(line, conversationID: conversationID) }
    }
}

/// H2: isolates the live-terminal subscription. Reading `acpTerminalByConversation` HERE — not in
/// `ConversationView.body` — means a streamed terminal chunk (which fires many times a second)
/// re-renders ONLY this slot, not the whole conversation (message `LazyVStack`, AI bar, thread
/// chips, composer). Previously every chunk re-evaluated `ConversationView.body` and re-ran the
/// O(n) `messages(for:)` filter, re-laying-out the entire transcript. Shown only while live.
struct ACPTerminalSlot: View {
    @Bindable var model: AppModel
    let conversationID: String

    var body: some View {
        if let terminal = model.acpTerminalByConversation[conversationID] {
            ACPTerminalView(model: model, conversationID: conversationID, terminal: terminal)
                .padding(.horizontal)
                .padding(.top, 6)
                .frame(maxWidth: 760)
        }
    }
}

/// H2 (same rationale as `ACPTerminalSlot`): isolates the ACP plan-checklist subscription so a
/// plan update re-renders only this slot, not the whole conversation. Shown only when non-empty.
struct ACPPlanSlot: View {
    @Bindable var model: AppModel
    let conversationID: String

    var body: some View {
        if let plan = model.acpPlansByConversation[conversationID], !plan.isEmpty {
            ACPPlanView(entries: plan)
                .padding(.horizontal)
                .padding(.top, 6)
                .frame(maxWidth: 760)
        }
    }
}

/// WS-D: editor for the terminal's custom quick-command chips — add, edit
/// inline, reorder, delete. Persists per-silo via `AppSession` on every change,
/// so the strip (which re-reads on dismiss) always matches.
struct CustomCommandEditorView: View {
    let siloID: String
    @Environment(\.dismiss) private var dismiss
    @State private var commands: [CustomCommand] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($commands) { $command in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Label", text: $command.label)
                                .font(.headline)
                            TextField("Text to send", text: $command.text)
                                .font(.body.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Toggle("Send immediately", isOn: $command.autoSend)
                                .font(.callout)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { commands.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { commands.remove(atOffsets: $0) }
                    Button {
                        commands.append(CustomCommand(label: "new", text: "", autoSend: false))
                    } label: {
                        Label("Add command", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("custom-command-add")
                } footer: {
                    Text("Chips above the terminal input. \u{201C}Send immediately\u{201D} runs the text as a line the moment you tap; off = the chip only fills the input so you can add arguments first.")
                }
            }
            .navigationTitle("Quick commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { commands = AppSession.customCommands(siloID: siloID) }
            .onChange(of: commands) { _, newValue in
                AppSession.setCustomCommands(newValue, siloID: siloID)
            }
        }
    }
}
