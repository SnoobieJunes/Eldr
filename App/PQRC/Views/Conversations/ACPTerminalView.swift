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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            outputView
            if terminal.closed {
                closedFooter
            } else {
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
                Text(terminal.output.isEmpty ? " " : terminal.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("acp-terminal-output-end")
            }
            .frame(minHeight: 120, maxHeight: 280)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.systemBackground)))
            .onChange(of: terminal.output) {
                // Keep the newest output in view as it streams.
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("acp-terminal-output-end", anchor: .bottom)
                }
            }
            .accessibilityIdentifier("acp-terminal-output")
        }
    }

    private var stdinRow: some View {
        HStack(spacing: 8) {
            TextField("Type a command…", text: $stdin)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($stdinFocused)
                .onSubmit(submit)
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
