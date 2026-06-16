import SwiftUI

/// In-app chat that drives a real in-process `ACPAgent` against the configured LLM,
/// so the user can confirm tool-calling works before wiring Xcode.
struct TestChatView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var health: LLMHealthChecker
    @StateObject private var session = TestChatSession()
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.items.isEmpty {
                            Text("Send a message to exercise your LLM and the agent's tools in a scratch directory. Try: “create a file hello.txt that says hi, then read it back”.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(session.items) { item in
                            chatRow(item).id(item.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: session.items.count) { _, _ in
                    if let last = session.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack {
            Text("Test Chat").font(.headline)
            Spacer()
            Toggle("Offline echo", isOn: $session.useFakeLLM)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: session.useFakeLLM) { _, _ in session.reset() }
            Button("Reset") { session.reset() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            .keyboardShortcut(.return, modifiers: [])
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
