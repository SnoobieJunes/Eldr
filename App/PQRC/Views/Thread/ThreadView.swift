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
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var myInviteUntil: Int64? {
        guard let until = model.aiInvites[thread.id]?[model.myIdentityHex], until > now else {
            return nil
        }
        return until
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            if model.loopGuardPaused.contains(thread.id) {
                Label("AIs paused — waiting for a human", systemImage: "pause.circle")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.yellow.opacity(0.15))
                    .accessibilityIdentifier("loop-guard-row")
            }
            composer
        }
        .navigationTitle("✳︎ \(thread.title)")
        .navigationBarTitleDisplayMode(.inline)
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassEffect()
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.threadMessages(thread.id)) { message in
                    MessageBubble(
                        message: message,
                        isMine: message.senderIdentity == model.myIdentityHex,
                        senderName: model.contactNames[message.senderIdentity] ?? "Contact")
                }
            }
            .padding()
        }
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
