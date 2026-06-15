import PQRCCore
import SwiftUI

/// Full-screen embedded AI thread (APP-SPEC §8): pinned header with live AI
/// status per human, invite/withdraw control with bounded durations, loop
/// guard state, and the recorded agent exchange.
struct ThreadView: View {
    @Bindable var model: AppModel
    let thread: ThreadVM

    @State private var draftText = ""
    @State private var showInvitePicker = false
    @State private var now = Int64(Date().timeIntervalSince1970)
    /// Markdown/HTML message currently open in the full-screen reader.
    @State private var fullScreenContent: FullScreenContent?
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var myInviteUntil: Int64? {
        guard let until = model.aiInvites[thread.id]?[model.myIdentityHex], until > now else {
            return nil
        }
        return until
    }

    private var threadScope: AIContextGrant.Scope { .thread(thread.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
                // Bottom bars as a safe-area inset, not VStack siblings: when
                // the loop-guard row appears mid-conversation the inset grows
                // and the anchored scroll shifts up with it — a sibling would
                // occlude the last bubble in place (which also reads as a
                // contrast-audit failure, A7).
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if model.loopGuardPaused.contains(thread.id) {
                            Label("AIs paused — waiting for a human", systemImage: "pause.circle")
                                .font(.callout.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                // Opaque tint: translucent fills break the
                                // contrast auditor's background sampling (A7).
                                .background(Color.yellow.mix(with: Color(.systemBackground), by: 0.85))
                                .accessibilityIdentifier("loop-guard-row")
                        }
                        composer
                    }
                }
        }
        .navigationTitle("✳︎ \(thread.title)")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $fullScreenContent) { content in
            FullScreenReaderView(text: content.text)
        }
        .onReceive(ticker) { _ in
            now = Int64(Date().timeIntervalSince1970)
        }
        .confirmationDialog("Invite my AI", isPresented: $showInvitePicker) {
            ForEach([15, 30, 60, 120], id: \.self) { minutes in
                Button("\(minutes) minutes") {
                    Task { await model.inviteAI(threadID: thread.id, minutes: minutes) }
                }
            }
        } message: {
            Text("Your AI will converse in this thread only. Everything it says or shares is recorded here.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array((model.aiInvites[thread.id] ?? [:]).keys.sorted()), id: \.self) { identityHex in
                if let until = model.aiInvites[thread.id]?[identityHex], until > now {
                    Label(
                        "\(model.contactNames[identityHex] ?? "Contact")'s AI active · \((until - now) / 60)m left",
                        systemImage: "sparkles")
                    .font(.caption)
                    .accessibilityIdentifier("thread-ai-status")
                }
            }
            HStack {
                if myInviteUntil != nil {
                    Button("Withdraw my AI") {
                        Task { await model.withdrawAI(threadID: thread.id) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("withdraw-ai")
                } else {
                    Button {
                        showInvitePicker = true
                    } label: {
                        Label("Invite my AI", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("invite-ai")
                }
                if model.iGrantedContext(scope: threadScope, now: now) {
                    Button("Stop sharing context") {
                        Task { await model.withdrawContextSharing(scope: threadScope) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("withdraw-context")
                } else {
                    Button {
                        Task {
                            await model.grantContextSharing(
                                scope: threadScope, minutes: 30,
                                conversationID: thread.conversationID, threadID: thread.id)
                        }
                    } label: {
                        Label("Share context", systemImage: "brain")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("grant-context")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        // Opaque card, not .glassEffect(): the glass shadow/blur spills over
        // the first scroll rows and leaves the contrast auditor with an
        // indeterminate background for anything near it (A7).
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.threadMessages(thread.id)) { message in
                        MessageBubble(
                            message: message,
                            isMine: message.senderIdentity == model.myIdentityHex,
                            senderName: model.contactNames[message.senderIdentity] ?? "Contact",
                            agentName: message.agentName ?? model.aiNames[message.senderIdentity],
                            onToggleAIContext: {
                                Task {
                                    await model.markAIContext(
                                        messageIDs: [message.id], value: !message.aiContext,
                                        conversationID: thread.conversationID)
                                }
                            },
                            onFullScreen: { fullScreenContent = FullScreenContent(text: $0) },
                            onRetry: { Task { await model.retry(message) } })
                    }
                }
                .padding()
            }
            // Explicit scroll-to-last (same as ConversationView): the lazy
            // stack's estimated height defeats defaultScrollAnchor alone, and
            // a last bubble left under the loop-guard band also reads as a
            // contrast-audit failure (A7).
            .onAppear {
                if let last = model.threadMessages(thread.id).last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: model.threadMessages(thread.id).count) {
                if let last = model.threadMessages(thread.id).last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        // Hard bottom edge: the soft scroll-edge blur leaves bubbles near the
        // loop-guard/composer bars without a determinable background, which
        // the contrast auditor hard-fails (A7).
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        // Open at the latest message (same as conversations, A8). Also
        // audit-load-bearing: an unanchored list can leave the last bubble
        // clipped mid-text under the loop-guard band, which reads as a
        // contrast failure.
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("thread-message-list")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the thread", text: $draftText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("thread-composer-field")
            Button {
                let text = draftText
                draftText = ""
                Task {
                    await model.send(text, conversationID: thread.conversationID, threadID: thread.id)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(draftText.isEmpty)
            .accessibilityLabel("Send to thread")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
