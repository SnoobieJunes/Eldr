// SPDX-License-Identifier: Apache-2.0
import PQRCNostr
import SwiftUI

/// WS-BM3 — one Buzz workspace channel.
///
/// Deliberately does **not** reuse `MessageBubble`. A Buzz channel message is
/// signed but not encrypted: the workspace's operator reads it. Rendering it in
/// the same chrome as a PQ-ratcheted Eldr message would make the single most
/// important security difference in the product invisible. The header carries
/// the boundary, and the first send requires acknowledging it.
struct BuzzChannelView: View {
    let workspace: BuzzWorkspaceRecord
    let channel: BuzzChannel
    let workspaces: BuzzWorkspaceModel

    @State private var draftText = ""
    @State private var justSent: (text: String, at: Date)?
    @State private var sending = false
    @State private var showDisclosure = false
    @AppStorage("buzzDisclosureAcknowledged") private var disclosureAcknowledged = false

    private var messageKey: String { BuzzWorkspaceModel.key(workspace.id, channel.id) }
    private var messages: [BuzzMessage] { workspaces.messages[messageKey] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            plaintextBanner
            transcript
            composer
        }
        .navigationTitle(channel.name)
        #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDisclosure = true
                } label: {
                    Label("About this workspace", systemImage: "info.circle")
                }
                .accessibilityIdentifier("buzz-channel-info")
            }
        }
        .alert("Not end-to-end encrypted", isPresented: $showDisclosure) {
            Button("OK") {}
        } message: {
            Text(BuzzWorkspaceModel.disclosure)
        }
        .task(id: channel.id) {
            await workspaces.openChannel(channel.id, in: workspace.id)
        }
        .onDisappear { workspaces.closeChannel(channel.id, in: workspace.id) }
    }

    /// Always visible, never a footnote — the same posture as the `ai_window`
    /// indicator: a standing capability the user must be able to see at a glance.
    private var plaintextBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
            Text("Readable by \(workspace.host)")
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.18))
        .accessibilityIdentifier("buzz-plaintext-banner")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Messages here are readable by the operator of \(workspace.host). Not end-to-end encrypted.")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        Text("No messages yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(messages) { message in
                        BuzzMessageRow(
                            message: message,
                            author: workspaces.displayName(message.authorPubkey, in: workspace.id),
                            isMine: workspaces.isMine(message, in: workspace.id))
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Reading width, per the responsive rules in CLAUDE.md — chat
                // must not sprawl edge to edge on a 27" display.
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let error = workspaces.lastError[workspace.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("buzz-send-error")
            }
            HStack(spacing: 8) {
                TextField("Message #\(channel.name)", text: $draftText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("buzz-composer-field")
                    // Same guard as ConversationView: the UITextView-backed field
                    // commits stale content back through the binding after a
                    // programmatic clear, refilling the box with what was just
                    // sent. Any real keystroke differs and disarms it.
                    .onChange(of: draftText) { _, newValue in
                        guard let sent = justSent else { return }
                        if Date().timeIntervalSince(sent.at) < 2,
                            newValue == sent.text
                                || (!newValue.isEmpty && newValue.allSatisfy(\.isWhitespace))
                        {
                            draftText = ""
                            return
                        }
                        if !newValue.isEmpty { justSent = nil }
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityIdentifier("buzz-composer-send")
                .accessibilityLabel("Send to workspace")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        let outgoing = draftText
        // Acknowledge the boundary once per install before the first workspace
        // send. Consent for plaintext is not implied by having joined.
        guard disclosureAcknowledged else {
            showDisclosure = true
            disclosureAcknowledged = true
            return
        }
        draftText = ""
        justSent = (outgoing, Date())
        sending = true
        Task {
            let ok = await workspaces.send(outgoing, to: channel.id, in: workspace.id)
            sending = false
            // A failed send must not silently eat the text.
            if !ok { draftText = outgoing; justSent = nil }
        }
    }
}

/// One workspace message. Flat and plain by design — this is not an Eldr bubble.
private struct BuzzMessageRow: View {
    let message: BuzzMessage
    let author: String
    let isMine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(isMine ? "You" : author)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isMine ? Color.accentColor : .primary)
                Text(Date(timeIntervalSince1970: TimeInterval(message.createdAt)), style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if message.isSystem {
                    Text("system")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(message.isSystem ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
