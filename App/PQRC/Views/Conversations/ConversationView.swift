import PQRCCore
import SwiftUI

/// The message view (APP-SPEC §6.2): bubbles, agent styling, system rows,
/// ai_window banner, thread chips, composer with the large-paste chip.
struct ConversationView: View {
    @Bindable var model: AppModel
    let conversationID: String

    @State private var draftText = ""
    /// Large-paste state: > 16 KB collapses into a chip (APP-SPEC §6.3).
    @State private var largePaste: String?
    @State private var aiDraft: String?
    @State private var showDraftSheet = false
    @State private var showWindowPicker = false
    @State private var showThreadSheet = false
    @State private var showDetails = false
    @State private var now = Int64(Date().timeIntervalSince1970)

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if model.safetyCodeChangedFor.contains(conversationID) {
                // Persistent until re-verified (APP-SPEC §6.2).
                Label(
                    "Safety code changed — verify \(model.contactNames[conversationID] ?? "this contact") again before trusting new messages",
                    systemImage: "exclamationmark.shield.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.red)
                .accessibilityIdentifier("safety-change-banner")
            }
            if let banner = model.activeWindowBanner(conversationID: conversationID, now: now) {
                AIWindowBanner(name: banner.name, until: banner.until, now: now)
            }
            threadChips
            messageList
            composer
        }
        .navigationTitle(model.contactNames[conversationID] ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        // Opaque bar: the title fails the contrast audit over scrolled content.
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--uitest-bigpaste"), largePaste == nil {
                largePaste = String(repeating: "PQRC large paste demo line.\n", count: 8000)
            }
        }
        .onReceive(ticker) { _ in
            now = Int64(Date().timeIntervalSince1970)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showThreadSheet = true
                } label: {
                    Image(systemName: "text.bubble")
                }
                .accessibilityLabel("Start AI thread")
                .accessibilityIdentifier("thread-create-button")
                Button {
                    showWindowPicker = true
                } label: {
                    Image(systemName: "sparkles")
                }
                .accessibilityLabel("AI options")
                .accessibilityIdentifier("ai-window-button")
                Button {
                    showDetails = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Conversation details")
            }
        }
        .confirmationDialog("Always-on AI", isPresented: $showWindowPicker) {
            ForEach([15, 30, 60, 120], id: \.self) { minutes in
                Button("My AI responds for \(minutes) min") {
                    Task { await model.startWindow(conversationID: conversationID, minutes: minutes) }
                }
            }
            Button("Draft a reply privately") {
                Task {
                    aiDraft = await model.draft(conversationID: conversationID)
                    showDraftSheet = aiDraft != nil
                }
            }
        } message: {
            Text("Everyone in the conversation will see that your AI is active.")
        }
        .sheet(isPresented: $showDraftSheet) {
            DraftSheet(model: model, conversationID: conversationID, draft: aiDraft ?? "")
        }
        .sheet(isPresented: $showThreadSheet) {
            ThreadCreateSheet(model: model, conversationID: conversationID)
        }
        .sheet(isPresented: $showDetails) {
            ConversationDetailsView(model: model, conversationID: conversationID)
        }
    }

    private var threadChips: some View {
        Group {
            if let threads = model.threadsByConversation[conversationID], !threads.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(threads) { thread in
                            NavigationLink {
                                ThreadView(model: model, thread: thread)
                            } label: {
                                Label(
                                    "✳︎ \(thread.title) · \(thread.messageCount)",
                                    systemImage: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                // Opaque fill: translucent materials fail the
                                // contrast audit under busy content.
                                .background(Color(.secondarySystemBackground), in: Capsule())
                            }
                            .accessibilityLabel("AI thread \(thread.title), \(thread.messageCount) messages")
                            .accessibilityIdentifier("thread-chip-\(thread.title)")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.messages(for: conversationID)) { message in
                        MessageBubble(
                            message: message,
                            isMine: message.senderIdentity == model.myIdentityHex,
                            senderName: model.contactNames[message.senderIdentity] ?? "Contact")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("message-list")
            // Hard bottom edge near the composer — soft-blur zones fail the
            // contrast audit (see ThreadView).
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            // Conversations open at the latest message (iMessage behavior).
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages(for: conversationID).count) {
                if let last = model.messages(for: conversationID).last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let paste = largePaste {
                // The chip: the field never visibly chokes on a 200 KB paste.
                // Copy is honest about the two paths (review L1): only > 64 KB
                // takes the encrypted-attachment pointer; 16–64 KB still goes
                // inline, padded to a size bucket like any other message.
                HStack {
                    Label(
                        paste.utf8.count > 65536
                            ? "Large text · \(paste.utf8.count / 1024) KB · sends as encrypted attachment"
                            : "Large text · \(paste.utf8.count / 1024) KB · sends padded inline",
                        systemImage: "doc.zipper")
                    .font(.caption)
                    .lineLimit(1)
                    Spacer()
                    Button {
                        largePaste = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Remove large text attachment")
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("large-paste-chip")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draftText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("composer-field")
                    .onChange(of: draftText) { _, newValue in
                        // > 16 KB collapses into the chip (APP-SPEC §6.3).
                        if newValue.utf8.count > 16384 {
                            largePaste = newValue
                            draftText = ""
                        }
                    }
                Button {
                    let outgoing = largePaste ?? draftText
                    largePaste = nil
                    draftText = ""
                    Task { await model.send(outgoing, conversationID: conversationID) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(draftText.isEmpty && largePaste == nil)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("composer-send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// "AI is present" reads as a distinct material (APP-SPEC §11).
struct AIWindowBanner: View {
    let name: String
    let until: Int64
    let now: Int64

    var body: some View {
        let remaining = max(0, until - now)
        Label(
            "\(name)'s AI is active · \(remaining / 60)m \(remaining % 60)s left",
            systemImage: "sparkles")
        .font(.callout.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassEffect()
        .accessibilityIdentifier("ai-window-banner")
        .accessibilityLabel("\(name)'s AI is active for \(remaining / 60) more minutes")
    }
}

/// AI draft preview: "Send as my AI" (agent-signed + labeled) or
/// "Edit & send as me" (human message, human-signed) — APP-SPEC §9.
struct DraftSheet: View {
    @Bindable var model: AppModel
    let conversationID: String
    @State var draft: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Draft from your AI", systemImage: "sparkles")
                    .font(.headline)
                TextEditor(text: $draft)
                    .frame(minHeight: 120)
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("draft-editor")
                Button {
                    Task {
                        await model.sendAsAI(draft, conversationID: conversationID)
                        dismiss()
                    }
                } label: {
                    Label("Send as my AI", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("send-as-ai")
                Button {
                    Task {
                        await model.send(draft, conversationID: conversationID)
                        dismiss()
                    }
                } label: {
                    Text("Edit & send as me")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("send-as-me")
                Spacer()
            }
            .padding()
            .navigationTitle("AI Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ThreadCreateSheet: View {
    @Bindable var model: AppModel
    let conversationID: String
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Thread title", text: $title)
                    .accessibilityIdentifier("thread-title")
                Button("Create AI thread") {
                    Task {
                        _ = await model.createThread(conversationID: conversationID, title: title)
                        dismiss()
                    }
                }
                .disabled(title.isEmpty)
                .accessibilityIdentifier("thread-create-confirm")
            }
            .navigationTitle("New AI Thread")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
