// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PQRCACP
import SwiftUI

/// EldrChat bridge: pair the Configurator's coding agent into EldrChat conversations
/// so a group (your phone, teammates) sees the agent's activity over the existing
/// PQRC E2EE stack. Agent messages always render as AI-authored (invariant 8).
struct BridgeView: View {
    @EnvironmentObject private var store: ConfigurationStore
    // WS-B2: owned by HuginnApp now (shared with the Relay tab) — was a private
    // @StateObject here.
    @EnvironmentObject private var bridge: ACPBridgeService
    // WS-B3: owned by HuginnApp now (shared with the menu-bar StatusBarView's
    // pending-approval badge + the notification observer) — was a private
    // @StateObject here.
    @EnvironmentObject private var a2aHost: A2AServerHost
    /// Are-you-sure step for A2A auto-approve (mirrors the Security tab's
    /// ungated-tools dialog): ON only through explicit confirmation, OFF instantly.
    @State private var confirmA2AAutoApprove = false
    @State private var copied = false
    @State private var manualOwnerHex = ""
    @State private var a2aBearerField = ""
    /// AC94: the executable-override field for the selected `.stdioSpawn` harness.
    @State private var harnessCommandField = ""
    /// AC104: spilled tool-results size under the current workdir (nil = probing).
    @State private var spillBytes: Int64?
    @State private var confirmCleanSpill = false
    @State private var spillNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Bridge (phone tether)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))

                Text("Add the coding agent to an EldrChat conversation as a first-class participant. The activity you opt into is delivered over the same post-quantum, end-to-end-encrypted PQRC channel EldrChat already uses — no server required to start.")
                    .foregroundStyle(.secondary)

                tetherCard
                stateBox
                if case .advertising = bridge.bridgeState { pairingBox }
                if !bridge.activeConversations.isEmpty { conversationsBox }
                if !bridge.activeConversations.isEmpty || bridge.ownerIdentityHex != nil {
                    ownerBox
                }
                projectDirBox
                togglesBox
                controls

                Text("Privacy: nothing is shared until you pair, pick a conversation, and enable a message type. The agent never self-activates — you are sharing your own coding session.")
                    .font(.caption).foregroundStyle(.secondary)

                a2aServingBox
            }
            .padding(20)
            // Wide enough to actually use a desktop window (the old 640 left half a
            // 1200-pt window as dead margin); the cap only bites on very wide panes.
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            // Wire the A2A server's dependencies to this Bridge's live selections — same
            // backend the phone's remote-drive session uses (WS3c), so serving one agent
            // over A2A answers with whatever the operator has configured here.
            a2aHost.descriptorProvider = {
                ConfigurationStore.resolvedHarnessDescriptor(id: bridge.relayHarnessID) ?? .builtIn
            }
            a2aHost.llmProvider = {
                let config = ACPBridgeService.relayHostLLMConfig()
                return InspectingLLMClient(
                    wrapping: OpenAICompatibleLLMClient(config: config), model: config.model)
            }
            a2aHost.toolEnvironmentProvider = {
                ToolEnvironment(
                    workdir: bridge.agentWorkdir, baseEnvironment: ProcessInfo.processInfo.environment)
            }
            // Always `.default` here, deliberately NOT the operator's tuned `store.agentConfig`
            // (which may carry `allowUngatedTools: true`): a remote HTTP caller's tasks stay
            // fail-closed regardless of that Mac-local convenience toggle — the ONLY thing that
            // authorizes a mutating tool on this surface is the per-task "allow tool use"
            // checkbox in the approval UI (default off), or — for auto-approved headless
            // tasks — the operator's confirmed AC108 toggle via the provider below.
            a2aHost.agentConfigProvider = { .default }
            a2aHost.autoApproveProvider = { store.a2aAutoApprove }
            a2aHost.autoApproveAllowsToolsProvider = {
                ACPBridgeService.operatorAllowsUngatedTools()
            }
        }
    }

    // MARK: - A2A serving (surface b — this Mac serves an A2A endpoint other clients call)

    /// ON routes through the are-you-sure dialog; OFF applies immediately (same
    /// shape as `ConfigurationView.ungatedToolsBinding`).
    private var a2aAutoApproveBinding: Binding<Bool> {
        Binding(
            get: { store.a2aAutoApprove },
            set: { on in
                if on {
                    confirmA2AAutoApprove = true
                } else {
                    store.a2aAutoApprove = false
                }
            })
    }

    private var a2aServingBox: some View {
        GroupBox("A2A serving") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Expose this Mac's coding agent as an Agent2Agent (A2A) v1.0 endpoint other tools can call. Off by default — every submitted task still needs your explicit approval below before it runs."
                )
                .font(.caption).foregroundStyle(.secondary)

                Toggle(
                    "Serve A2A",
                    isOn: Binding(
                        get: { a2aHost.isServing },
                        set: { newValue in Task { newValue ? await a2aHost.start() : await a2aHost.stop() } }
                    ))

                Toggle("Auto-approve inbound tasks (headless/CLI)", isOn: a2aAutoApproveBinding)
                    .confirmationDialog(
                        "Run inbound A2A tasks without asking?",
                        isPresented: $confirmA2AAutoApprove, titleVisibility: .visible
                    ) {
                        Button("Enable — I accept the risk", role: .destructive) {
                            store.a2aAutoApprove = true
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "Any local process holding the bearer token can run tasks on your agent immediately, with no approval prompt. Tool use inside those tasks still follows Security ▸ \u{201C}Run tools without asking permission\u{201D}. This does not expire; it stays on until you switch it off here."
                        )
                    }
                if store.a2aAutoApprove {
                    Label(
                        "Inbound tasks run WITHOUT per-task approval. Tool use follows the Security tab's ungated-tools toggle.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }

                LabeledContent("Port") {
                    TextField(
                        "port", value: $a2aHost.port, format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .disabled(a2aHost.isServing)
                }

                HStack {
                    Text("Token").font(.caption.weight(.medium))
                    Text(a2aHost.bearerToken).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(a2aHost.bearerToken, forType: .string)
                    }.controlSize(.small)
                    Button("Regenerate") { a2aHost.regenerateToken() }.controlSize(.small)
                }

                if a2aHost.isServing {
                    Label(
                        "Serving on http://127.0.0.1:\(a2aHost.port)/a2a",
                        systemImage: "checkmark.circle.fill"
                    ).font(.caption).foregroundStyle(.green)
                }
                if let error = a2aHost.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                if !a2aHost.pendingApprovals.isEmpty {
                    Divider()
                    Text("Pending task approvals").font(.caption.weight(.medium))
                    ForEach(a2aHost.pendingApprovals) { item in
                        pendingApprovalRow(item)
                    }
                }

                Divider()
                Text("Caution: anyone on this Mac who has the token can submit tasks to this agent.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            .padding(4)
        }
    }

    private func pendingApprovalRow(_ item: InboundTaskGate.PendingApproval) -> some View {
        PendingApprovalRow(item: item, a2aHost: a2aHost)
    }

    private var stateBox: some View {
        GroupBox {
            HStack(spacing: 10) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(stateText).font(.callout.weight(.medium))
                Spacer()
            }
            .padding(4)
        }
    }

    /// WS-B4: the tether's home. `relayACPServing` was published but rendered nowhere
    /// (the old `tetherChip` this replaces was a late add-on, easy to miss) — this is a
    /// proper card up top so "is my phone actually tethered to this Mac right now, and
    /// when did it last talk?" has a one-glance answer without checking logs. Serving =
    /// the phone's REMOTE-drive session (the full ACP protocol served over the relay by
    /// `ACPRelayHost`, distinct from the watch-along mirror below); Paired = a device has
    /// paired with this Mac (persisted owner pin, or a live paired conversation this
    /// session — the same signal `ownerBox` already gates on); Last activity =
    /// `lastTetherActivity`, host/timing only, never payload (invariant 12).
    private var tetherCard: some View {
        GroupBox("Phone tether") {
            VStack(alignment: .leading, spacing: 8) {
                tetherRow(
                    label: "Serving",
                    isOn: bridge.relayACPServing,
                    onText: "Your phone can drive this agent remotely over the relay",
                    offText: "Pin an owner + configure a model to serve the phone's remote-drive session")
                tetherRow(
                    label: "Paired",
                    isOn: isPhonePaired,
                    onText: "A phone has paired with this Mac",
                    offText: "No phone has paired yet — scan the QR code below to pair one")
                HStack(spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Group {
                        if let last = bridge.lastTetherActivity {
                            HStack(spacing: 4) {
                                Text("Last activity:")
                                Text(last, style: .relative)
                                Text("ago")
                            }
                        } else {
                            Text("Last activity: none yet")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(4)
        }
    }

    private func tetherRow(label: String, isOn: Bool, onText: String, offText: String)
        -> some View
    {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption.weight(.medium))
                Text(isOn ? onText : offText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Whether a phone has paired with this Mac: either a live paired conversation this
    /// session, or a persisted owner pin from a prior session (the same "configured vs
    /// not" signal `ownerBox`'s visibility already gates on below) — `bridgeState` alone
    /// only reflects the CURRENT link/advertising status, not whether pairing ever
    /// happened, so it isn't the right source for this.
    private var isPhonePaired: Bool {
        !bridge.activeConversations.isEmpty || bridge.ownerIdentityHex != nil
    }

    private var pairingBox: some View {
        GroupBox("Pair with EldrChat") {
            HStack(alignment: .top, spacing: 14) {
                if let link = bridge.pairingLink, let image = Self.qrImage(link) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 140, height: 140)
                        .background(Color.white)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("On another device: open EldrChat ▸ New conversation ▸ Scan and point it at this code. The agent pairs as a contact you can add to any conversation.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("On this Mac, EldrChat can't scan its own screen — copy the link or open it directly:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            guard let link = bridge.pairingLink else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                            copied = true
                        } label: {
                            Label(
                                copied ? "Copied" : "Copy pairing link",
                                systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Button {
                            guard let link = bridge.pairingLink, let url = URL(string: link) else {
                                return
                            }
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open in EldrChat", systemImage: "arrow.up.forward.app")
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(4)
        }
        .onChange(of: bridge.pairingLink) { _, _ in copied = false }
    }

    private var conversationsBox: some View {
        GroupBox("Conversations") {
            ForEach($bridge.activeConversations) { $conversation in
                Toggle(conversation.name, isOn: $conversation.enabled)
            }
            .padding(4)
        }
    }

    /// Path 2 §7 — designate the device whose owner controls this agent. The owner sees
    /// the agent's RAW answers (incl. secrets it reads); every other participant sees the
    /// redacted copy. No owner pinned ⇒ the agent stays silent (fails closed).
    private var ownerBox: some View {
        GroupBox("Owner device") {
            VStack(alignment: .leading, spacing: 8) {
                Text("This agent acts only while the owner's AI is active. The owner sees raw answers; everyone else sees secrets redacted.")
                    .font(.caption).foregroundStyle(.secondary)

                if let owner = bridge.ownerIdentityHex {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.shield.checkmark.fill")
                            .foregroundStyle(.green)
                        Text("Owner: \(ownerLabel(owner))").font(.callout.weight(.medium))
                        Spacer()
                        Button("Re-assign") { bridge.setOwnerIdentity(nil) }
                            .controlSize(.small)
                    }
                } else {
                    Label(
                        "No owner pinned — the agent stays silent (fails closed).",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout).foregroundStyle(.orange)
                }

                if !bridge.activeConversations.isEmpty {
                    Divider()
                    Text("Choose from paired devices:").font(.caption).foregroundStyle(.secondary)
                    ForEach(bridge.activeConversations) { convo in
                        HStack(spacing: 8) {
                            Button {
                                bridge.setOwnerIdentity(convo.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(
                                        systemName: bridge.ownerIdentityHex == convo.id
                                            ? "largecircle.fill.circle" : "circle"
                                    )
                                    .foregroundStyle(bridge.ownerIdentityHex == convo.id ? .green : .secondary)
                                    Text(convo.name)
                                    Text(Self.shortHex(convo.id))
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            // Delete a paired device (clears the owner if it was pinned —
                            // fail-closed). It can re-pair later.
                            Button(role: .destructive) {
                                bridge.removePairedConversation(identityHex: convo.id)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this paired device")
                        }
                    }
                }

                Divider()
                // Advanced/dev escape hatch: pin the owner by raw identity hex
                // before they appear in the paired-devices list. Tucked behind a
                // collapsed disclosure so the clean path stays QR + the list above.
                DisclosureGroup("Advanced — pin by identity hex") {
                    HStack {
                        TextField("owner identity hex", text: $manualOwnerHex)
                            .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                        Button("Pin") {
                            bridge.setOwnerIdentity(manualOwnerHex)
                            manualOwnerHex = ""
                        }
                        .controlSize(.small)
                        .disabled(manualOwnerHex.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)

                Divider()
                Picker("Watch-along mode", selection: $bridge.watchAlongMode) {
                    Text("Endpoint (hardened)").tag(ACPBridgeService.WatchAlongMode.endpoint)
                    Text("Direct (fallback)").tag(ACPBridgeService.WatchAlongMode.direct)
                }
                .pickerStyle(.segmented)
                Text(
                    bridge.watchAlongMode == .endpoint
                        ? "Endpoint: the Mac drafts to your phone; your phone redacts + voices to the group as your signed agent. The raw secret never reaches anyone but you."
                        : "Direct: the Mac voices to the group itself (owner raw, others redacted). Verified fallback."
                )
                .font(.caption2).foregroundStyle(.secondary)

                Divider()
                Picker("Mac-side responder", selection: $bridge.responder) {
                    Text("eldr-acp (our agent)").tag(ACPBridgeService.Responder.eldrAcp)
                    Text("sybilclaw assistant").tag(ACPBridgeService.Responder.sybilclaw)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("bridge-responder")
                Text(
                    bridge.responder == .sybilclaw
                        ? "Chat to sybilclaw: the owner's messages are forwarded to sybilclaw's OWN assistant (its model, persona, memory, tools) over its local Gateway (default :18789), and the reply comes back over the relay. eldr-acp's LLM isn't used — needs sybilclaw running on this Mac."
                        : "eldr-acp: the owner drives our agent (its own configured LLM) — works even without sybilclaw."
                )
                .font(.caption2).foregroundStyle(.secondary)

                Divider()
                // WS3c — DISTINCT from "Mac-side responder" above: this picks what
                // answers the phone's REMOTE-drive session (full tool-calling ACP,
                // permission cards and all), not what drafts into the watch-along mirror.
                Picker("Cloud coding agent", selection: $bridge.relayHarnessID) {
                    ForEach(HarnessRegistry.all) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("bridge-relay-harness")
                Text(relayHarnessCaption)
                    .font(.caption2).foregroundStyle(.secondary)

                if let selected = HarnessRegistry.descriptor(id: bridge.relayHarnessID),
                    selected.kind == .a2aRemote
                {
                    LabeledContent("Bearer token (optional)") {
                        SecureField("(leave blank if the agent needs no auth)", text: $a2aBearerField)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: a2aBearerField) { _, newValue in
                                store.setA2ABearerToken(newValue, for: selected.id)
                            }
                    }
                    .task(id: selected.id) { a2aBearerField = store.a2aBearerToken(for: selected.id) }
                    Text(
                        "Sent as `Authorization: Bearer …` to \(selected.a2aCardURL ?? "the agent's card URL"). Stored in the Keychain, never this app's environment."
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }

                if let selected = HarnessRegistry.descriptor(id: bridge.relayHarnessID),
                    selected.kind == .stdioSpawn
                {
                    // AC94: GUI/launchd processes get a minimal PATH (no nvm/npm
                    // dirs), so a bare command name here often can't resolve — let
                    // the operator pin the absolute executable.
                    LabeledContent("Executable") {
                        HStack {
                            TextField(selected.command, text: $harnessCommandField)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout.monospaced())
                                .onChange(of: harnessCommandField) { _, newValue in
                                    store.setHarnessCommandOverride(newValue, for: selected.id)
                                }
                            Button("Browse…") { pickHarnessExecutable() }
                                .controlSize(.small)
                        }
                    }
                    .task(id: selected.id) {
                        harnessCommandField = store.harnessCommandOverride(for: selected.id)
                    }
                    if !harnessCommandField.isEmpty,
                        !FileManager.default.isExecutableFile(atPath: harnessCommandField)
                    {
                        Label(
                            "Nothing executable at that path — the spawn will fail until it points at the real binary.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2).foregroundStyle(.orange)
                    }
                    Text(
                        harnessCommandField.isEmpty
                            ? "Blank = the default (\(selected.command)), resolved on this app's PATH — which for a GUI or launchd launch omits nvm/npm dirs. Pin an absolute path if the CLI lives there; it's also written to the agent env file so delegate_to_cloud_agent finds it."
                            : "Overrides the default (\(selected.command)) for Huginn's spawns AND, via the agent env file, for delegate_to_cloud_agent inside eldr-acp."
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
        }
    }

    private var relayHarnessCaption: String {
        guard let selected = HarnessRegistry.descriptor(id: bridge.relayHarnessID) else { return "" }
        switch selected.kind {
        case .builtIn:
            return "The phone's remote-drive session (full tool access, every action a permission card) runs our built-in agent."
        case .a2aRemote:
            return "Bridges to a remote Agent2Agent (A2A) v1.0 agent over HTTPS JSON-RPC — no subprocess. Every action it takes still surfaces as a permission card on your phone."
        case .stdioSpawn:
            return "Spawns the installed CLI directly (must be on THIS app's PATH). Its vendor key (Settings ▸ Cloud coding agents) is injected ONLY into that process, never this app's shell. Its every file/shell action still surfaces as a permission card on your phone."
        }
    }

    private func ownerLabel(_ hex: String) -> String {
        if let convo = bridge.activeConversations.first(where: { $0.id == hex }) {
            return "\(convo.name) (\(Self.shortHex(hex)))"
        }
        return Self.shortHex(hex)
    }

    static func shortHex(_ hex: String) -> String {
        hex.count > 18 ? "\(hex.prefix(8))…\(hex.suffix(8))" : hex
    }

    /// The project folder the agent's tools (read_file, run_shell, xcodebuild) operate
    /// in. Without it the agent runs in an undefined dir and real tasks fail — so this
    /// is load-bearing for anything beyond "what can you do?".
    private var projectDirBox: some View {
        GroupBox("Agent project folder") {
            VStack(alignment: .leading, spacing: 6) {
                if let dir = bridge.agentWorkdir {
                    Text(dir)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label(
                        "Not set — the agent has no project to read or build. Pick the folder it should work in.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Choose project folder…") { chooseProjectFolder() }
                        .controlSize(.small)
                    if bridge.agentWorkdir != nil {
                        Button("Clear") { bridge.setAgentWorkdir(nil) }
                            .controlSize(.small)
                    }
                }
                // AC104: oversized tool results spill to <workdir>/.eldr/tool-results
                // with no automatic GC — show the size and offer a confirmed clean.
                if let dir = bridge.agentWorkdir {
                    let spillPath = (dir as NSString)
                        .appendingPathComponent(ToolExecutor.spillDirRelative)
                    Divider()
                    HStack(spacing: 8) {
                        Text("Spilled tool results: \(spillSizeLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Clean…") { confirmCleanSpill = true }
                            .controlSize(.small)
                            .disabled((spillBytes ?? 0) == 0)
                        Spacer()
                    }
                    .task(id: dir) { await refreshSpillSize(dir: dir) }
                    .confirmationDialog(
                        "Delete \(spillSizeLabel) of spilled tool results?",
                        isPresented: $confirmCleanSpill
                    ) {
                        Button("Delete \(ToolExecutor.spillDirRelative)", role: .destructive) {
                            cleanSpill(path: spillPath, workdir: dir)
                        }
                    } message: {
                        Text(
                            "Removes \(spillPath) — overflow copies of past tool outputs the agent could read back. The agent recreates the folder when it next spills."
                        )
                    }
                    if let spillNote {
                        Text(spillNote).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .padding(4)
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose the project the coding agent should operate in."
        if panel.runModal() == .OK, let url = panel.url {
            bridge.setAgentWorkdir(url.path)
        }
    }

    /// AC94: pick the harness CLI binary. Hidden files shown — nvm installs live
    /// under dot-directories (`~/.nvm/versions/node/<v>/bin`).
    private func pickHarnessExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use this executable"
        panel.message = "Pick the harness CLI binary (an absolute path survives GUI/launchd PATH)."
        if panel.runModal() == .OK, let url = panel.url {
            harnessCommandField = url.path  // onChange persists + mirrors to the env file
        }
    }

    // MARK: AC104 — spilled tool-results hygiene

    private var spillSizeLabel: String {
        guard let spillBytes else { return "…" }
        return spillBytes == 0 ? "none" : spillBytes.formatted(.byteCount(style: .file))
    }

    private func refreshSpillSize(dir: String) async {
        let path = (dir as NSString).appendingPathComponent(ToolExecutor.spillDirRelative)
        spillBytes = await Task.detached(priority: .utility) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                isDir.boolValue
            else { return Int64(0) }
            return HFCache.directorySize(path)
        }.value
    }

    private func cleanSpill(path: String, workdir: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
            spillNote = nil
        } catch {
            spillNote = "Couldn't delete: \(error.localizedDescription)"
        }
        Task { await refreshSpillSize(dir: workdir) }
    }

    private var togglesBox: some View {
        GroupBox("Share from your coding session") {
            VStack(alignment: .leading) {
                Toggle("Tool calls", isOn: $bridge.shareToolCalls)
                Toggle("Build results", isOn: $bridge.shareBuildResults)
                Toggle("File diffs", isOn: $bridge.shareFileDiffs)
                Toggle("Session summary", isOn: $bridge.shareSessionSummary)
            }
            .padding(4)
        }
    }

    private var controls: some View {
        HStack {
            switch bridge.bridgeState {
            case .unpaired, .error:
                Button("Enable bridge") { bridge.enable() }
            default:
                Button("Stop advertising") { bridge.disable() }
                Button(role: .destructive) { Task { await bridge.unpair() } } label: { Text("Unpair") }
            }
        }
    }

    private var stateColor: Color {
        switch bridge.bridgeState {
        case .paired: return .green
        case .advertising: return .yellow
        case .error: return .red
        case .unpaired: return .secondary
        }
    }

    private var stateText: String {
        switch bridge.bridgeState {
        case .unpaired: return "Not paired"
        case .advertising: return "Advertising — waiting for EldrChat to pair"
        case .paired(let name): return "Paired with \(name)"
        case .error(let message): return "Error: \(message)"
        }
    }

    private struct PendingApprovalRow: View {
        let item: InboundTaskGate.PendingApproval
        @ObservedObject var a2aHost: A2AServerHost
        @State private var allowToolUse = false

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.summary).font(.caption.monospaced()).lineLimit(3)
                Text("from \(item.peer)").font(.caption2).foregroundStyle(.secondary)
                Toggle("Allow this task to use tools (write/edit/shell)", isOn: $allowToolUse)
                    .font(.caption2)
                HStack {
                    Button("Deny", role: .destructive) {
                        Task { await a2aHost.deny(item) }
                    }.controlSize(.small)
                    Button("Approve") {
                        Task { await a2aHost.approve(item, allowToolUse: allowToolUse) }
                    }.controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
            .padding(6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Render the `pqrc:add?npub=…` pairing link as a QR code.
    static func qrImage(_ string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 140, height: 140))
    }
}
