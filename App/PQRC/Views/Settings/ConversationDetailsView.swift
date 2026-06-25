import PQRCCore
import SwiftUI

/// Per-conversation details: verification (D13), block & report (D8).
struct ConversationDetailsView: View {
    @Bindable var model: AppModel
    let conversationID: String
    @Environment(\.dismiss) private var dismiss
    @State private var safetyCode = ""
    @State private var verified = false
    @State private var showReport = false
    @State private var blocked = false
    /// Gate the destructive Block direction behind a confirm (§2.6); Unblock is
    /// recoverable and fires immediately, so it is NOT gated.
    @State private var showBlockConfirm = false
    @State private var nickname = ""
    /// Per-conversation AI context override: "default" (use each AI's own
    /// setting) | "off" | "marked" | "full".
    @State private var aiContextMode = "default"
    /// Per-conversation egress-firewall override: "default" (inherit the account
    /// setting) | "on" (redact) | "off" (raw — a private chat with your own agents).
    @State private var firewallOverride = "default"
    /// Read-only echo of the primary AI's effective mode / remoteness / firewall
    /// for this conversation, refreshed when the override changes.
    @State private var summary: (mode: String, isRemote: Bool, firewallOn: Bool) =
        ("active", false, true)
    /// Whether this contact is a paired Mac coding-agent node — gates the
    /// autonomous-changes consent section (only meaningful for such a node).
    @State private var isCodingAgent = false
    /// Per-node AUTONOMOUS-CHANGES consent (statusreport §2.3): lets the paired Mac
    /// agent create/modify files and run shell commands without asking each time.
    /// OFF by default — when off, the phone fails closed on every mutating tool.
    @State private var autonomousChanges = false
    /// Per-node REMOTE DEV-CONTROL consent (ACPRouterplan Phase 3): whether the phone may
    /// drive this paired Mac node's ACP agent over the relay at all. OFF by default — the
    /// relay path is inert until this is on.
    @State private var remoteDevControl = false
    /// Per-node SHARE-CHAT-CONTEXT consent (Phase D3): whether this paired Mac's coding
    /// agent may USE the phone's MCP chat tools (read REDACTED conversations, draft,
    /// search; `send_as_my_ai` only inside a live AI window). OFF by default — separate
    /// from dev-control (chat context ≠ dev-control). Off ⇒ the phone refuses to serve
    /// MCP frames AND refuses to advertise the tools to the node.
    @State private var shareChatContext = false
    /// Collapses the coding-agent consent switches behind a single "Mac agent
    /// control" disclosure (closed by default), so Details opens on a calm
    /// summary rather than a wall of switches.
    @State private var showAgentControls = false

    /// One-line summary shown on the collapsed "Mac agent control" disclosure so
    /// the current consent posture is legible without expanding it.
    private var agentControlSummary: String {
        guard remoteDevControl else { return "Off — not driving this Mac agent" }
        var parts = ["Driving this Mac agent"]
        parts.append(autonomousChanges ? "autonomous changes ON" : "asks before each change")
        if shareChatContext { parts.append("chat context shared") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(
                        "Local name for this contact", text: $nickname,
                        prompt: Text(model.contactNames[conversationID] ?? "Contact"))
                    .accessibilityIdentifier("contact-nickname")
                    .onSubmit {
                        Task {
                            await model.renameContact(
                                conversationID, nickname: nickname.isEmpty ? nil : nickname)
                        }
                    }
                    Text("Only you see this name — local to your device, never broadcast. If you've turned on a remote AI, a name you set here is included in prompts sent to that provider. If they've chosen an alias, it shows when you clear this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text(safetyCode.isEmpty ? "—" : safetyCode)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("safety-code")
                    Text("Compare these 60 digits in person or over a call you trust. They are derived from both of your identity keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    QRView(content: safetyCode)
                        .frame(width: 120, height: 120)
                        .accessibilityLabel("Safety code QR for comparison")
                    Toggle("Mark as verified", isOn: $verified)
                        .accessibilityIdentifier("mark-verified")
                        .onChange(of: verified) { _, newValue in
                            // Persisted (D13): the shield badge survives
                            // relaunch and clears safety-change warnings.
                            Task { await model.setVerified(conversationID, verified: newValue) }
                        }
                } header: {
                    Text("Verify \(model.contactNames[conversationID] ?? "contact")")
                        .helpInfo("Confirm you're really talking to this person, not an impostor. Read the 60 digits aloud in person or over a trusted call — if they match on both phones, you're verified and get a green shield. If the code ever changes, a red banner warns you before you trust new messages.")
                }
                Section {
                    // Unified vocabulary (matches the per-AI "Gathers" picker and
                    // the in-chat "AI here" chip): Use default · Off · Marked only
                    // · Live. Tags stay the engine's "default"/"off"/"marked"/
                    // "full" — only the labels are unified.
                    Picker("AI context here", selection: $aiContextMode) {
                        Text("Use default").tag("default")
                        Text("Off in this conversation").tag("off")
                        Text("Marked only — messages I add to context").tag("marked")
                        Text("Live — full conversation while active").tag("full")
                    }
                    .accessibilityIdentifier("conversation-ai-mode")
                    .onChange(of: aiContextMode) { _, newValue in
                        AppSession.setConversationContextMode(
                            newValue == "default" ? nil : newValue, conversationID: conversationID,
                            siloID: model.siloID)
                        summary = model.primaryAIContextSummary(conversationID)
                    }
                    // Live echo of what the AI actually does here + the firewall/
                    // consent indicator whenever a REMOTE AI is active (privacy
                    // cardinal rule: any widening of what a remote AI sees keeps
                    // the firewall state visible).
                    AIContextEcho(summary: summary)
                    if summary.mode != "off" && summary.isRemote {
                        RemoteAIFirewallRow(firewallOn: summary.firewallOn)
                    }
                    Picker("Egress firewall here", selection: $firewallOverride) {
                        // A consented coding-agent node defaults the firewall OFF
                        // (it's your own trusted device); every other chat follows
                        // the account default.
                        Text("Use default (\(remoteDevControl ? "off — trusted node" : (AppSession.firewallEnabled ? "on" : "off")))").tag("default")
                        Text("On — redact before a cloud AI").tag("on")
                        Text("Off — send raw (your own agents)").tag("off")
                    }
                    .accessibilityIdentifier("conversation-firewall-mode")
                    .onChange(of: firewallOverride) { _, newValue in
                        AppSession.setConversationFirewall(
                            newValue == "default" ? nil : (newValue == "on"),
                            conversationID: conversationID, siloID: model.siloID)
                        summary = model.primaryAIContextSummary(conversationID)
                    }
                    Text("Only affects a REMOTE (cloud) AI. \"Off\" lets this chat's real names and content reach that AI raw — for a private chat with your own agents. \"On\" redacts before anything leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("AI in this conversation — overrides your AI's default (now: \(AIContextVocab.glance(summary)))")
                } footer: {
                    Text("Overrides your AIs' own context setting, just here. \"Off\" keeps every AI from gathering anything from this conversation.")
                }
                if isCodingAgent {
                    Section {
                        // Progressive disclosure: a coding-agent node's consent
                        // switches (including the destructive autonomous-changes
                        // toggle) live behind a collapsed "Mac agent control" row,
                        // so opening Details lands on a calm summary, not a wall of
                        // switches one tap from granting file/shell autonomy.
                        DisclosureGroup(isExpanded: $showAgentControls) {
                            Toggle("Drive this agent from here", isOn: $remoteDevControl)
                                .accessibilityIdentifier("acp-remote-dev-control")
                                .onChange(of: remoteDevControl) { _, newValue in
                                    AppSession.setRemoteDevControlConsent(
                                        newValue, nodeID: conversationID, siloID: model.siloID)
                                    // Bind the live relay-ACP provider (ON) / revert to the inert
                                    // stub (OFF) with no reboot.
                                    let nodeHex = conversationID
                                    Task { await model.runtime.refreshACPBindings() }
                                    if !newValue {
                                        // Revoking dev-control also drops the transport + denies
                                        // any pending prompts for this node (fail-closed). Phase D3:
                                        // chat-context sharing presupposes dev-control, so also tear
                                        // down any live relay-MCP host (the gate `isMCPSharingNode`
                                        // now fails, but stop the running host immediately too).
                                        Task { await model.runtime.teardownRelayACPTransport(nodeHex: nodeHex) }
                                        Task { await model.runtime.teardownRelayMCPHost(nodeHex: nodeHex) }
                                    }
                                }
                            Label(
                                remoteDevControl
                                    ? "ON — your phone can drive this Mac's coding agent over the relay. Read-only by default; mutating actions are governed below."
                                    : "OFF — this paired Mac agent is fully inert; nothing here can drive it.",
                                systemImage: remoteDevControl
                                    ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("acp-remote-dev-control-status")

                            Toggle("Allow autonomous file & shell changes", isOn: $autonomousChanges)
                                .accessibilityIdentifier("acp-autonomous-changes")
                                .disabled(!remoteDevControl)
                                .onChange(of: autonomousChanges) { _, newValue in
                                    // Per-node, per-silo — the conversationID IS the node's hex.
                                    AppSession.setAutonomousChangesConsent(
                                        newValue, nodeID: conversationID, siloID: model.siloID)
                                }
                            Label(
                                autonomousChanges
                                    ? "ON — the paired Mac agent can create/modify files and run shell commands on its node without asking each time."
                                    : "OFF — each create/modify/run request prompts you here (Allow once / Allow always / Deny). Read-only inspection still works.",
                                systemImage: autonomousChanges ? "lock.open.trianglebadge.exclamationmark" : "lock.shield")
                                .font(.caption)
                                .foregroundStyle(autonomousChanges ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .accessibilityIdentifier("acp-autonomous-changes-status")

                            Toggle("Share my chat context with this agent", isOn: $shareChatContext)
                                .accessibilityIdentifier("acp-share-chat-context")
                                .disabled(!remoteDevControl)
                                .onChange(of: shareChatContext) { _, newValue in
                                    // Per-node, per-silo — the conversationID IS the node's hex.
                                    AppSession.setShareChatContextConsent(
                                        newValue, nodeID: conversationID, siloID: model.siloID)
                                    let nodeHex = conversationID
                                    // Re-bind the ACP provider so the next session advertises (or
                                    // stops advertising) the chat tools to the node…
                                    Task { await model.runtime.refreshACPBindings() }
                                    // …and, when turning OFF, tear down any live relay-MCP host so
                                    // the node's chat-tool channel goes dark immediately.
                                    if !newValue {
                                        Task { await model.runtime.teardownRelayMCPHost(nodeHex: nodeHex) }
                                    }
                                }
                            Label(
                                shareChatContext
                                    ? "ON — this agent can read your REDACTED conversations (codenames only), draft replies, and search. It can post as your AI ONLY while you have an AI window open."
                                    : "OFF — this agent cannot see or search any of your chats. (Your real names are never shared either way — reads are always redacted.)",
                                systemImage: shareChatContext ? "bubble.left.and.text.bubble.right" : "bubble.left.and.bubble.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("acp-share-chat-context-status")
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac agent control")
                                    Text(agentControlSummary)
                                        .font(.caption)
                                        .foregroundStyle(autonomousChanges ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                }
                            } icon: {
                                Image(systemName: "desktopcomputer")
                            }
                        }
                        .accessibilityIdentifier("acp-advanced-disclosure")
                    } header: {
                        Text("Mac coding agent")
                            .helpInfo("Two switches, both off by default. The first lets your phone drive this paired Mac's coding agent over the relay at all. The second lets it create/modify files and run shell commands WITHOUT prompting — with it off, every mutating action asks you here, and your phone is the last brake before a destructive change runs on that Mac.")
                    } footer: {
                        Text("Off by default (privacy-first). Open “Mac agent control” to drive the agent; leave autonomous changes off to be asked before each file/shell change.")
                    }
                }
                Section("Safety") {
                    Button(blocked ? "Unblock" : "Block", role: .destructive) {
                        if blocked {
                            // Unblock is recoverable — apply immediately, no confirm.
                            blocked = false
                            Task { await model.runtime.setBlocked(conversationID, blocked: false) }
                        } else {
                            // Block drops their messages — confirm first (§2.6).
                            showBlockConfirm = true
                        }
                    }
                    .accessibilityIdentifier("block-contact")
                    Button("Report a problem") {
                        showReport = true
                    }
                    .accessibilityIdentifier("report-contact")
                }
            }
            .navigationTitle("Details")
            .task {
                safetyCode = await model.runtime.safetyCode(with: conversationID)
                let info = await model.runtime.contactInfo(conversationID)
                verified = info.verified
                blocked = info.blocked
                aiContextMode =
                    AppSession.conversationContextMode(conversationID, siloID: model.siloID) ?? "default"
                firewallOverride =
                    AppSession.conversationFirewall(conversationID, siloID: model.siloID)
                    .map { $0 ? "on" : "off" } ?? "default"
                summary = model.primaryAIContextSummary(conversationID)
                isCodingAgent = await model.runtime.contactType(conversationID) == "coding_agent"
                autonomousChanges = AppSession.autonomousChangesConsent(
                    nodeID: conversationID, siloID: model.siloID)
                remoteDevControl = AppSession.remoteDevControlConsent(
                    nodeID: conversationID, siloID: model.siloID)
                shareChatContext = AppSession.shareChatContextConsent(
                    nodeID: conversationID, siloID: model.siloID)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showReport) {
                ReportSheet()
            }
            // Confirm the destructive Block direction (§2.6) — same alert shape
            // as Settings (destructive confirm + Cancel). The button reflects
            // `blocked` only after this confirms, so a cancelled Block leaves the
            // toggle reading "Block".
            .alert(
                "Block \(model.contactNames[conversationID] ?? "contact")?",
                isPresented: $showBlockConfirm
            ) {
                Button("Block", role: .destructive) {
                    blocked = true
                    Task { await model.block(conversationID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll stop receiving their messages, and their pending messages are dropped on this device — without notifying them. You can unblock them here at any time.")
            }
        }
        // Details is a "page you navigate", not a quick action: let it fill the
        // window on Mac/iPad (and stay full-height on iPhone). This view is
        // presented as a plain `.sheet`, so it already defaults to full-height on
        // iPhone; `.page` is what makes it large on Mac/Catalyst.
        .presentationSizing(.page)
    }
}

/// Shared vocabulary for the AI-context surfaces (Details section, the in-chat
/// "AI here" chip, the chip sheet) so they always read the same. Input is the
/// engine `mode` ("off" | "strict" | "active") from
/// `AppModel.primaryAIContextSummary`; output is the user-facing wording.
enum AIContextVocab {
    /// Compact glance label for a chip / header: "AI off here", "AI: marked",
    /// "AI: live". Mirrors PersonaRuntime's resolution (off / strict / active).
    static func glance(_ summary: (mode: String, isRemote: Bool, firewallOn: Bool)) -> String {
        switch summary.mode {
        case "off": return "AI off here"
        case "strict": return "AI: marked"
        default: return "AI: live"  // "active"
        }
    }

    /// One-line "Your AI sees: …" echo describing what the AI gathers here.
    static func sees(_ summary: (mode: String, isRemote: Bool, firewallOn: Bool)) -> String {
        switch summary.mode {
        case "off": return "Your AI sees: nothing from this conversation."
        case "strict": return "Your AI sees: only messages you add to context."
        default: return "Your AI sees: the full recent conversation while it's active."
        }
    }
}

/// One-line echo of what the AI actually gathers in a conversation. Read-only.
struct AIContextEcho: View {
    let summary: (mode: String, isRemote: Bool, firewallOn: Bool)
    var body: some View {
        Label(AIContextVocab.sees(summary), systemImage: "eye")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-sees-echo")
    }
}

/// Firewall/consent indicator shown whenever a REMOTE AI is active for a
/// conversation — the privacy cardinal rule requires the egress-firewall state
/// stay visible anywhere a remote AI's exposure can widen. Read-only (the toggle
/// itself lives in Settings ▸ AI).
struct RemoteAIFirewallRow: View {
    let firewallOn: Bool
    var body: some View {
        Label(
            firewallOn
                ? "Remote AI · egress firewall ON — names redacted, context bounded before it leaves your device."
                : "Remote AI · egress firewall OFF — real names and full context leave your device unredacted.",
            systemImage: firewallOn ? "lock.shield" : "lock.open")
            .font(.caption)
            .foregroundStyle(firewallOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .accessibilityIdentifier("remote-ai-firewall-row")
    }
}

/// Report flow (D8, Guideline 1.2): explains E2EE, nothing is auto-shared;
/// offers a voluntary export the user emails to the maintainer.
struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Reporting in an E2EE app", systemImage: "hand.raised")
                    .font(.headline)
                Text(
                    "EldrChat messages are end-to-end encrypted: nothing is shared automatically with anyone, including the app maintainer. If you want to report abuse, you can voluntarily export selected messages and email them to the maintainer. Blocking the contact stops their messages immediately, on this device, without notifying them."
                )
                .font(.subheadline)
                ShareLink(item: "EldrChat report — attach exported messages here.") {
                    Label("Export & report", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
