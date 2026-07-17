import AppKit
import SwiftUI

/// In-app chat that drives a real in-process `ACPAgent` against the configured LLM,
/// so the user can confirm tool-calling works before wiring Xcode.
struct TestChatView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var health: LLMHealthChecker
    // WS-B3: owned by HuginnApp now (shared with the menu-bar StatusBarView's
    // pending-approval badge + the notification observer) — was a private
    // @StateObject here.
    @EnvironmentObject private var session: TestChatSession
    @State private var draft = ""
    /// Whether the raw-stream disclosure is expanded. Independent of the toggle that
    /// enables capture: the panel only appears when `session.showRawStream` is on, and
    /// starts collapsed so it stays out of the way.
    @State private var rawExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.items.isEmpty && session.pendingApprovals.isEmpty {
                            Text("Send a message to exercise your LLM and the agent's tools in the workspace above. Try: “create a file hello.txt that says hi, then read it back”.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(session.items) { item in
                            chatRow(item).id(item.id)
                        }
                        ForEach(session.pendingApprovals) { approval in
                            PendingToolApprovalRow(approval: approval, session: session)
                                .id(approval.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: session.items.count) { _, _ in
                    if let last = session.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: session.pendingApprovals.count) { _, _ in
                    if let last = session.pendingApprovals.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if session.showRawStream {
                Divider()
                rawStreamPanel
            }
            Divider()
            composer
        }
        .task {
            // Wire the session's config seams to this store's live selections before
            // anything runs, and show the resolved workspace immediately (without
            // bootstrapping the agent) so the header is accurate from the first frame.
            session.workspaceProvider = { store.testChatWorkspacePath }
            session.autoApproveProvider = { store.testChatAutoApprove }
            session.refreshWorkdirDisplay()
        }
        .onChange(of: store.testChatWorkspacePath) { _, _ in
            session.reset()
            session.refreshWorkdirDisplay()
        }
        .onChange(of: store.testChatAutoApprove) { _, _ in session.reset() }
    }

    /// Collapsible view of the LAST turn's RAW model output — what the model emitted
    /// BEFORE reasoning-trace stripping, so the reasoning chain (`<think>…`,
    /// `<|channel>thought…`) is visible. Only shown while the toggle is on; collapsed
    /// by default so it stays out of the way.
    private var rawStreamPanel: some View {
        DisclosureGroup(isExpanded: $rawExpanded) {
            ScrollView {
                Text(session.rawStream.isEmpty
                    ? "No raw output captured yet. Send a message to capture this turn's raw stream."
                    : session.rawStream)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(session.rawStream.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain").font(.caption)
                Text("Raw LLM stream (pre-strip, last turn)").font(.caption.weight(.semibold))
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Test Chat").font(.headline)
                Spacer()
                Toggle("Offline echo", isOn: $session.useFakeLLM)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: session.useFakeLLM) { _, _ in session.reset() }
                Toggle("Raw LLM stream", isOn: $session.showRawStream)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show the model's raw output BEFORE reasoning-trace stripping — "
                        + "e.g. a reasoning model's <think>… / <|channel>thought… chain-of-thought. "
                        + "Off by default. Rebuilds the session so the next turn is captured.")
                    .onChange(of: session.showRawStream) { _, _ in session.reset() }
                Button("Reset") { session.reset() }
                    .controlSize(.small)
            }
            HStack(spacing: 10) {
                Label(
                    session.workdir.isEmpty ? "Workspace not set" : session.workdir,
                    systemImage: "folder"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                Button("Choose folder…") { chooseWorkspaceFolder() }
                    .controlSize(.small)
                if !store.testChatWorkspacePath.isEmpty {
                    Button("Use scratch dir") { store.testChatWorkspacePath = "" }
                        .controlSize(.small)
                }
                Spacer()
                Label(
                    store.testChatAutoApprove ? "Auto-approve ON" : "Approvals required",
                    systemImage: store.testChatAutoApprove ? "bolt.fill" : "hand.raised.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(store.testChatAutoApprove ? .orange : .secondary)
                Toggle("Auto-approve (test mode)", isOn: $store.testChatAutoApprove)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("When ON, every tool permission request is granted automatically "
                        + "(still logged in the transcript). When OFF, each mutating tool call "
                        + "waits for you to Approve/Deny, and fails closed on timeout.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Same NSOpenPanel pattern as `BridgeView.chooseProjectFolder()` — pick the
    /// folder Test Chat's tools (read_file/write_file/run_shell) operate in.
    private func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose the folder Test Chat's tools should operate in."
        if panel.runModal() == .OK, let url = panel.url {
            store.testChatWorkspacePath = url.path
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "paperplane.fill")
            }
            // NB: the TextField's `.onSubmit(sendDraft)` already handles Return. Do
            // NOT also bind `.keyboardShortcut(.return)` here — that fired BOTH on a
            // single Return press, starting two concurrent sends. Clicking the button
            // still works; Return goes through onSubmit only.
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isResponding)
        }
        .padding(12)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        // Keep the agent's config providers current with the store before each turn.
        session.llmConfigProvider = { store.llmConfig }
        session.agentConfigProvider = { store.agentConfig }
        session.workspaceProvider = { store.testChatWorkspacePath }
        session.autoApproveProvider = { store.testChatAutoApprove }
        Task { await session.send(text) }
    }

    @ViewBuilder
    private func chatRow(_ item: TestChatItem) -> some View {
        switch item.role {
        case .user:
            bubble(item.text, align: .trailing, bg: Color.accentColor.opacity(0.18))
        case .assistant:
            bubble(item.text, align: .leading, bg: Color.secondary.opacity(0.12))
        case .toolCall:
            ToolCallCard(name: item.toolName ?? "tool", argsJSON: item.argsJSON ?? "{}")
        case .toolResult:
            ToolResultCard(text: item.text, isError: item.isError)
        case .approvalNote:
            ApprovalNoteRow(text: item.text)
        }
    }

    private func bubble(_ text: String, align: HorizontalAlignment, bg: Color) -> some View {
        HStack {
            if align == .trailing { Spacer(minLength: 40) }
            Text(text.isEmpty ? " " : text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(bg, in: RoundedRectangle(cornerRadius: 12))
            if align == .leading { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: align == .trailing ? .trailing : .leading)
    }
}

/// An expandable card for one tool call (name + pretty-printed arguments).
private struct ToolCallCard: View {
    let name: String
    let argsJSON: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver.fill").font(.caption)
                    Text(name).font(.caption.weight(.semibold))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(argsJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolResultCard: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (isError ? Color.red : Color.green).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A pending `session/request_permission` the agent is waiting on, with explicit
/// Approve/Deny actions — mirrors `BridgeView.PendingApprovalRow`'s pattern for the
/// A2A-serving surface, applied here to Test Chat's own tool-call gate.
private struct PendingToolApprovalRow: View {
    let approval: TestChatSession.PendingToolApproval
    @ObservedObject var session: TestChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.caption).foregroundStyle(.orange)
                Text(approval.title).font(.caption.weight(.semibold))
                Spacer()
            }
            if !approval.kind.isEmpty {
                Text("kind: \(approval.kind)").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Deny", role: .destructive) {
                    Task { await session.deny(approval) }
                }.controlSize(.small)
                Button("Approve") {
                    Task { await session.approve(approval) }
                }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small audit note for a resolved permission gate (auto-approved, approved/denied
/// by the user, or timed out) — visually distinct from the tool call/result cards so
/// it reads as a log line, not agent output.
private struct ApprovalNoteRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield").font(.caption2)
            Text(text).font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
