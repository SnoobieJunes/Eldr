// SPDX-License-Identifier: AGPL-3.0-only
// huginn-gtk — Huginn for Linux (WS-N10). GTK 4 via EldrLinux's GtkKit; every service is
// HuginnCore (the same code huginn-cli and the tests drive). All widget work happens on
// the GTK main thread; async results hop back with `onMain`.
import Foundation
import GtkKit
import HuginnCore
import PQRCACP
import PQRCNostr

func checkButton(_ text: String, _ on: Bool) -> Widget {
    let c = gtk_check_button_new_with_label(text)!
    gtk_check_button_set_active(cast(c), on ? 1 : 0)
    return c
}
func isOn(_ c: Widget) -> Bool { gtk_check_button_get_active(cast(c)) != 0 }
func entry(_ text: String, placeholder: String = "") -> Widget {
    let e = gtk_entry_new()!
    setEntryText(e, text)
    if !placeholder.isEmpty { gtk_entry_set_placeholder_text(cast(e), placeholder) }
    return e
}
func row(_ title: String, _ w: Widget) -> Widget {
    let r = hbox(8)
    let l = label(title); gtk_widget_set_size_request(l, 220, -1); append(r, l)
    expand(w, h: true); append(r, w)
    return r
}
func textView(_ text: String, editable: Bool = true) -> Widget {
    let tv = gtk_text_view_new()!
    gtk_text_view_set_wrap_mode(cast(tv), GTK_WRAP_WORD_CHAR)
    gtk_text_view_set_editable(cast(tv), editable ? 1 : 0)
    setTextViewText(tv, text)
    return tv
}
func sized(_ w: Widget, _ h: Int32) -> Widget { gtk_widget_set_size_request(w, -1, h); return w }
/// Strip control characters before showing untrusted text (model output, logs).
func clean(_ s: String) -> String {
    String(s.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
}

final class HuginnUI {
    let paths = HuginnPaths.standard()
    var window: Widget!
    var notebook: Widget!
    var statusLabel: Widget!
    var secrets: (any SecretStore)?
    var settings: HuginnSettings
    var timer: guint = 0
    let supervisor = ChildSupervisor()
    var learner: ContextLearner?
    var agentLog: LogTailer
    var tailers: [String: LogTailer] = [:]
    var chat: TestChatSession?

    // Configuration widgets
    var urlE: Widget!, modelE: Widget!, tokenE: Widget!, stepsE: Widget!, toolsE: Widget!, workdirE: Widget!
    var preambleTV: Widget!, systemTV: Widget!
    var learnC: Widget!, ungatedC: Widget!, visionC: Widget!, cloudC: Widget!
    var healthLabel: Widget!
    // Chat
    var chatList: Widget!, chatEntry: Widget!, chatFakeC: Widget!, chatAutoC: Widget!, approvalsBox: Widget!, rawTV: Widget!, chatRawC: Widget!
    var chatScroll: Widget!
    // Logs
    var logTV: Widget!, logFilter = "all"
    // Bridge
    var ownerE: Widget!, relayE: Widget!, bridgeWorkE: Widget!, responderE: Widget!, bridgeState: Widget!, nodeLogTV: Widget!
    // Buzz
    var buzzList: Widget!
    // Memory
    var memoryList: Widget!
    // World
    var worldArea: Widget!, worldLabel: Widget!
    var world: TownStatusWire?
    // Setup
    var setupLabel: Widget!

    init() {
        settings = HuginnSettings.load(paths: paths)
        agentLog = LogTailer(path: HuginnPaths.standard().logFile, capacity: 1500)
    }

    func status(_ s: String) { setLabel(statusLabel, s) }

    func build(_ app: UnsafeMutablePointer<GtkApplication>) {
        installCSS("""
            .title { font-weight: bold; font-size: 1.2em; }
            .meta { font-size: 0.85em; opacity: 0.75; }
            .warn { color: #c01c28; }
            .ok { color: #26a269; }
            .bubble-user { background: alpha(#3584e4, 0.18); border-radius: 8px; padding: 6px 8px; }
            .bubble-agent { background: alpha(@theme_fg_color, 0.07); border-radius: 8px; padding: 6px 8px; }
            .tool { font-family: monospace; font-size: 0.9em; opacity: 0.85; }
            .mono { font-family: monospace; }
            """)
        window = gtk_application_window_new(app)
        gtk_window_set_title(cast(window), "Huginn")
        gtk_window_set_default_size(cast(window), 1080, 760)
        let outer = vbox(0)
        notebook = gtk_notebook_new()!
        expand(notebook, h: true, v: true)
        addPage(configurationPage(), "Configuration")
        addPage(chatPage(), "Test Chat")
        addPage(inspectorPage(), "Inspector")
        addPage(logsPage(), "Logs")
        addPage(bridgePage(), "Bridge")
        addPage(buzzPage(), "Buzz")
        addPage(relayPage(), "Relay")
        addPage(worldPage(), "World")
        addPage(setupPage(), "Setup")
        append(outer, notebook)
        statusLabel = label("Ready.", wrap: true); addClass(statusLabel, "meta"); margins(statusLabel, 6)
        append(outer, statusLabel)
        gtk_window_set_child(cast(window), outer)
        gtk_window_present(cast(window))
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--open"), i + 1 < argv.count {
            let open = argv[i + 1]
            let names = ["configuration", "chat", "inspector", "logs", "bridge", "buzz", "relay", "world", "setup"]
            if let i = names.firstIndex(of: open) { gtk_notebook_set_current_page(cast(notebook), Int32(i)) }
        }
        unlockKeystore()
        timer = every(seconds: 1) { [unowned self] in self.tick() }
        Task { await self.agentLog.poll(); onMain { [self] in self.renderLogs() } }
        TestChatSession.cleanupStaleWorkspaces()
    }

    func addPage(_ w: Widget, _ title: String) {
        let s = scrolled(w)
        expand(s, h: true, v: true)
        gtk_notebook_append_page(cast(notebook), s, label(title))
    }

    // MARK: - Keystore

    func unlockKeystore(env extra: [String: String] = [:]) {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        do {
            let (store, posture) = try HuginnSecrets.open(paths: paths, environment: env)
            secrets = store
            setEntryText(tokenE, HuginnSecrets.string(store, HuginnSecrets.llmTokenAccount) ?? "")
            // No key ⇒ no learner: reading sealed events without it would skip them for good.
            if let key = try? HuginnSecrets.metadataKey(store) {
                let l = ContextLearner(paths: paths, metadataKey: key)
                learner = l
                Task { await self.refreshMemory() }
            }
            status("Keystore unlocked (\(posture)).")
            refreshBuzz()
        } catch {
            status("Keystore locked: \(error). Secrets (LLM token, Buzz keys) are unavailable until you unlock it.")
            askPassphrase()
        }
    }

    func askPassphrase() {
        let win = gtk_window_new()!
        gtk_window_set_title(cast(win), "Unlock Huginn")
        gtk_window_set_transient_for(cast(win), cast(window))
        gtk_window_set_modal(cast(win), 1)
        let box = vbox(8); margins(box, 14)
        append(box, label("Huginn keeps the LLM token, the project-memory key and Buzz agent keys in an encrypted keystore (\(paths.keystoreDir)). Enter its passphrase — the first time, this sets it.", wrap: true))
        let pw = gtk_password_entry_new()!
        gtk_password_entry_set_show_peek_icon(cast(pw), 1)
        append(box, pw)
        let row = hbox(6)
        append(row, button("Unlock") { [unowned self] in
            let p = entryText(pw)
            gtk_window_destroy(cast(win))
            guard !p.isEmpty else { return }
            self.unlockKeystore(env: ["HUGINN_PASSPHRASE": p])
        })
        append(row, button("Not now") { gtk_window_destroy(cast(win)) })
        append(box, row)
        gtk_window_set_child(cast(win), box)
        gtk_window_present(cast(win))
    }

    // MARK: - Configuration

    func configurationPage() -> Widget {
        let s = settings
        let box = vbox(8); margins(box, 14)
        let t = label("Model endpoint"); addClass(t, "title"); append(box, t)
        urlE = entry(s.llmURL); append(box, row("Endpoint (OpenAI-compatible)", urlE))
        modelE = entry(s.llmModel); append(box, row("Model", modelE))
        tokenE = gtk_password_entry_new()!
        gtk_password_entry_set_show_peek_icon(cast(tokenE), 1)
        append(box, row("Token (kept in the keystore)", tokenE))
        let hrow = hbox(6)
        healthLabel = label("Not checked")
        append(hrow, button("Check endpoint") { [unowned self] in self.checkHealth() })
        append(hrow, healthLabel)
        append(box, hrow)
        let t2 = label("Agent"); addClass(t2, "title"); append(box, t2)
        stepsE = entry(String(s.maxAgentSteps)); append(box, row("Max agent steps", stepsE))
        toolsE = entry(s.tools.joined(separator: ","), placeholder: "read_file,write_file,…")
        append(box, row("Tool allowlist", toolsE))
        workdirE = entry(s.workdir, placeholder: "empty = throwaway scratch folder")
        append(box, row("Workspace folder", workdirE))
        learnC = checkButton("Learn from sessions (project memory, eldr.md)", s.learningEnabled); append(box, learnC)
        ungatedC = checkButton("Allow changes without asking (ungated tools)", s.allowUngatedTools); append(box, ungatedC)
        visionC = checkButton("Model accepts images (vision)", s.visionEnabled); append(box, visionC)
        cloudC = checkButton("Allow delegating to cloud agents", s.cloudAgentDelegationEnabled); append(box, cloudC)
        append(box, label("Prompt preamble"))
        preambleTV = textView(s.promptPreamble); append(box, sized(preambleTV, 70))
        append(box, label("System prompt override (empty = Eldr's default)"))
        systemTV = textView(s.systemPrompt); append(box, sized(systemTV, 90))
        append(box, button("Save configuration") { [unowned self] in self.saveConfiguration() })
        let note = label("Saved to \(paths.envFile) and the files beside it — exactly what eldr-acp reads.", wrap: true)
        addClass(note, "meta"); append(box, note)
        return box
    }

    func readConfiguration() -> HuginnSettings {
        var s = settings
        s.llmURL = entryText(urlE).trimmingCharacters(in: .whitespaces)
        s.llmModel = entryText(modelE).trimmingCharacters(in: .whitespaces)
        s.maxAgentSteps = Int(entryText(stepsE)) ?? s.maxAgentSteps
        s.tools = entryText(toolsE).split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        s.workdir = entryText(workdirE).trimmingCharacters(in: .whitespaces)
        s.learningEnabled = isOn(learnC)
        s.allowUngatedTools = isOn(ungatedC)
        s.visionEnabled = isOn(visionC)
        s.cloudAgentDelegationEnabled = isOn(cloudC)
        s.promptPreamble = textViewText(preambleTV)
        s.systemPrompt = textViewText(systemTV)
        return s
    }

    func saveConfiguration() {
        let s = readConfiguration()
        do { try s.save(paths: paths) } catch { status("⚠ \(error)"); return }
        settings = s
        let tok = entryText(tokenE)
        if let secrets {
            do {
                if tok.isEmpty { secrets.delete(account: HuginnSecrets.llmTokenAccount) }
                else { try secrets.save(Data(tok.utf8), account: HuginnSecrets.llmTokenAccount) }
            } catch { status("⚠ The keystore refused the token: \(error)"); return }
        } else if !tok.isEmpty {
            status("Saved — but the token was NOT stored: the keystore is locked."); return
        }
        status("Saved configuration.")
        Task { await self.chat?.setOptions(self.chatOptions()) }
    }

    var token: String { secrets.flatMap { HuginnSecrets.string($0, HuginnSecrets.llmTokenAccount) } ?? "" }

    func checkHealth() {
        let url = entryText(urlE), tok = entryText(tokenE)
        setLabel(healthLabel, "Checking…")
        Task {
            let r = await LLMHealth.check(url: url, token: tok)
            onMain { [self] in
                var text = r.label
                if case .healthy(let models) = r, !models.isEmpty { text += ": " + models.prefix(6).joined(separator: ", ") }
                setLabel(self.healthLabel, clean(text))
                gtk_widget_remove_css_class(self.healthLabel, r.isHealthy ? "warn" : "ok")
                addClass(self.healthLabel, r.isHealthy ? "ok" : "warn")
            }
        }
    }

    // MARK: - Test Chat

    func chatOptions() -> TestChatSession.Options {
        var agent = settings.agentConfig(paths: paths)
        agent.eventsFilePath = nil  // Test Chat must not teach project memory
        return .init(llm: settings.llmConfig(token: token), agent: agent, workdir: settings.workdir,
                     autoApprove: chatAutoC.map(isOn) ?? false, useFakeLLM: chatFakeC.map(isOn) ?? false,
                     captureRaw: chatRawC.map(isOn) ?? false)
    }

    func chatPage() -> Widget {
        let box = vbox(8); margins(box, 14)
        let top = hbox(8)
        chatFakeC = checkButton("Echo brain (no model)", false)
        chatAutoC = checkButton("Auto-approve tools", false)
        chatRawC = checkButton("Capture raw stream", false)
        for w in [chatFakeC!, chatAutoC!, chatRawC!] {
            append(top, w)
            on(w, "toggled") { [unowned self] in Task { await self.chat?.setOptions(self.chatOptions()) } }
        }
        append(top, button("New session") { [unowned self] in Task { await self.chat?.reset() } })
        append(box, top)
        chatList = gtk_list_box_new()!
        gtk_list_box_set_selection_mode(cast(chatList), GTK_SELECTION_NONE)
        chatScroll = scrolled(chatList)
        expand(chatScroll, h: true, v: true)
        append(box, sized(chatScroll, 420))
        approvalsBox = vbox(4); append(box, approvalsBox)
        let send = hbox(6)
        chatEntry = entry("", placeholder: "Ask the agent to do something in the workspace…")
        expand(chatEntry, h: true)
        append(send, chatEntry)
        append(send, button("Send") { [unowned self] in self.sendChat() })
        on(chatEntry, "activate") { [unowned self] in self.sendChat() }
        append(box, send)
        let note = label("This runs the real eldr-acp agent in-process against your workspace. Mutating tools ask first; unanswered requests are denied after the permission timeout.", wrap: true)
        addClass(note, "meta"); append(box, note)
        return box
    }

    func ensureChat() -> TestChatSession {
        if let chat { return chat }
        let c = TestChatSession(options: chatOptions()) { [weak self] in
            onMain { self?.renderChat() }
        }
        chat = c
        return c
    }

    func sendChat() {
        let text = entryText(chatEntry)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        setEntryText(chatEntry, "")
        let c = ensureChat()
        Task { await c.send(text) }
    }

    func renderChat() {
        guard let c = chat else { return }
        Task {
            let items = await c.items, pending = await c.pendingApprovals, busy = await c.isResponding, raw = await c.rawStream, wd = await c.workdir
            onMain { [self] in
                clearList(self.chatList)
                for it in items {
                    let w: Widget
                    switch it.role {
                    case .user: w = label("You: " + clean(it.text), wrap: true, selectable: true); addClass(w, "bubble-user")
                    case .assistant: w = label(clean(it.text), wrap: true, selectable: true); addClass(w, "bubble-agent")
                    case .toolCall: w = label("⚙ \(it.text) \(clean(it.argsJSON ?? ""))", wrap: true, selectable: true); addClass(w, "tool")
                    case .toolResult: w = label((it.isError ? "✗ " : "→ ") + clean(String(it.text.prefix(2000))), wrap: true, selectable: true); addClass(w, "tool")
                    case .approvalNote: w = label("· " + clean(it.text), wrap: true); addClass(w, "meta")
                    }
                    gtk_list_box_append(cast(self.chatList), w)
                }
                if busy { gtk_list_box_append(cast(self.chatList), label("Agent is working…")) }
                var child = gtk_widget_get_first_child(self.approvalsBox)
                while let ch = child { child = gtk_widget_get_next_sibling(ch); gtk_box_remove(cast(self.approvalsBox), ch) }
                for a in pending {
                    let r = hbox(6)
                    let l = label("Allow: \(clean(a.title)) (\(a.kind))?"); addClass(l, "warn"); append(r, l)
                    append(r, button("Approve") { Task { await c.approve(a) } })
                    append(r, button("Deny") { Task { await c.deny(a) } })
                    append(self.approvalsBox, r)
                }
                setTextViewText(self.rawTV, raw.isEmpty ? "(no raw capture for the last turn — enable “Capture raw stream”)" : clean(raw))
                if !wd.isEmpty { self.status("Test Chat workspace: \(wd)") }
                let adj = gtk_scrolled_window_get_vadjustment(cast(self.chatScroll))
                onMain { gtk_adjustment_set_value(adj, gtk_adjustment_get_upper(adj)) }
            }
        }
    }

    // MARK: - Inspector (raw stream + project memory)

    func inspectorPage() -> Widget {
        let box = vbox(8); margins(box, 14)
        let t = label("Last Test Chat turn, raw model stream"); addClass(t, "title"); append(box, t)
        rawTV = textView("", editable: false); addClass(rawTV, "mono")
        append(box, sized(rawTV, 220))
        let t2 = label("Project memory (eldr.md) learned from agent sessions"); addClass(t2, "title"); append(box, t2)
        memoryList = gtk_list_box_new()!
        append(box, memoryList)
        append(box, button("Refresh") { [unowned self] in Task { await self.refreshMemory() } })
        return box
    }

    func refreshMemory() async {
        guard let l = learner else { return }
        let ps = await l.projects()
        var texts: [String: String] = [:]
        for p in ps { texts[p.path] = await l.memoryText(p) }
        onMain { [self] in
            clearList(self.memoryList)
            if ps.isEmpty { gtk_list_box_append(cast(self.memoryList), label("No project memory yet. It appears after the agent runs in a project with learning on.", wrap: true)) }
            for p in ps {
                let col = vbox(4)
                let h = label(p.cwd, selectable: true); addClass(h, "title"); append(col, h)
                append(col, label(clean(texts[p.path] ?? ""), wrap: true, selectable: true))
                append(col, button("Clear this project's memory") { Task { await l.clear(p); await self.refreshMemory() } })
                gtk_list_box_append(cast(self.memoryList), col)
            }
        }
    }

    // MARK: - Logs

    func logsPage() -> Widget {
        let box = vbox(8); margins(box, 14)
        let top = hbox(6)
        for f in ["all", "error", "llm", "tool"] {
            append(top, button(f.capitalized) { [unowned self] in self.logFilter = f; self.renderLogs() })
        }
        append(top, button("Copy") { [unowned self] in copyToClipboard(self.window, textViewText(self.logTV)) })
        append(box, top)
        append(box, label("Agent log: \(paths.logFile)", selectable: true))
        logTV = textView("", editable: false); addClass(logTV, "mono")
        append(box, sized(logTV, 560))
        return box
    }

    func renderLogs() {
        let f = logFilter
        Task {
            let lines = await agentLog.lines
            let shown = lines.filter { f == "all" || $0.kind.rawValue == f }.suffix(600)
            let text = shown.map { "[\($0.kind.rawValue)] \(clean($0.text))" }.joined(separator: "\n")
            onMain { [self] in setTextViewText(self.logTV, text.isEmpty ? "(no log lines yet)" : text) }
        }
    }

    // MARK: - Bridge

    func bridgePage() -> Widget {
        let b = BridgeSettings.load(paths)
        let box = vbox(8); margins(box, 14)
        let t = label("Serve the agent to your phone (eldr-node)"); addClass(t, "title"); append(box, t)
        append(box, label("Your phone drives the full agent over the relay. Only the owner identity below may — eldr-node enforces it and refuses to start without one.", wrap: true))
        ownerE = entry(b.ownerHex, placeholder: "phone identity hex"); append(box, row("Owner (phone identity)", ownerE))
        relayE = entry(b.relayURL); append(box, row("Relay", relayE))
        bridgeWorkE = entry(b.workdir, placeholder: "project folder the agent works in"); append(box, row("Workdir", bridgeWorkE))
        responderE = entry(b.responder); append(box, row("Responder", responderE))
        let r = hbox(6)
        append(r, button("Save") { [unowned self] in _ = self.readBridge().save(self.paths); self.status("Bridge settings saved.") })
        append(r, button("Start") { [unowned self] in self.startBridge() })
        append(r, button("Stop") { [unowned self] in Task { await self.supervisor.stop(id: "eldr-node") } })
        append(box, r)
        bridgeState = label("Stopped"); append(box, bridgeState)
        nodeLogTV = textView("", editable: false); addClass(nodeLogTV, "mono")
        append(box, sized(nodeLogTV, 300))
        return box
    }

    func readBridge() -> BridgeSettings {
        BridgeSettings(ownerHex: entryText(ownerE), relayURL: entryText(relayE), workdir: entryText(bridgeWorkE), responder: entryText(responderE))
    }

    func binary(_ name: String) -> String {
        let installed = (paths.binDir as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        return ((CommandLine.arguments[0] as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
    }

    func startBridge() {
        let b = readBridge()
        guard b.problems.isEmpty else { status("⚠ " + b.problems.map(\.message).joined(separator: " ")); return }
        _ = b.save(paths)
        var env = ProcessInfo.processInfo.environment
        env["ELDR_LLM_URL"] = settings.llmURL
        env["ELDR_LLM_MODEL"] = settings.llmModel
        if !token.isEmpty { env["ELDR_LLM_TOKEN"] = token }
        let exe = binary("eldr-node"), log = paths.nodeLogFile
        tailers["eldr-node"] = LogTailer(path: log, capacity: 400, startAtEnd: true)
        Task {
            let cmd = BridgeSettings.lineBuffered(exe, b.arguments())
            let st = await supervisor.start(id: "eldr-node", executable: cmd.executable, arguments: cmd.arguments, environment: env, logPath: log, workingDirectory: b.workdir.isEmpty ? nil : b.workdir)
            onMain { [self] in self.status("eldr-node: \(st.label)") }
        }
    }

    // MARK: - Buzz

    func buzzPage() -> Widget {
        let box = vbox(8); margins(box, 14)
        let t = label("Buzz workspaces — your local model as an agent member"); addClass(t, "title"); append(box, t)
        let warn = label("Buzz channels are signed, NOT end-to-end encrypted: whatever the agent posts is readable by the workspace relay. Replies are scrubbed of secret-shaped content by default.", wrap: true)
        addClass(warn, "warn"); append(box, warn)
        buzzList = gtk_list_box_new()!
        append(box, buzzList)
        append(box, label("Add a connection"))
        let relay = entry("", placeholder: "wss://you.communities.buzz.xyz")
        let channels = entry("", placeholder: "channel UUID(s), comma-separated")
        let name = entry("Eldr")
        let ownerKey = gtk_password_entry_new()!
        let ack = checkButton("I understand replies leave end-to-end encryption", false)
        append(box, row("Relay", relay)); append(box, row("Channels", channels)); append(box, row("Display name", name))
        append(box, row("Owner key (optional, used once)", ownerKey)); append(box, ack)
        append(box, button("Create connection") { [unowned self] in
            guard let secrets = self.secrets else { self.status("Unlock the keystore first."); return }
            var c = BuzzConnection()
            c.relayURL = entryText(relay); c.channelIds = BuzzConnectionStore.parseChannelList(entryText(channels))
            c.displayName = entryText(name); c.disclosureAcknowledged = isOn(ack)
            let store = BuzzConnectionStore(path: self.paths.buzzConnectionsFile, secrets: secrets)
            do {
                let made = try store.create(c, ownerPrivateKey: entryText(ownerKey))
                setEntryText(ownerKey, "")
                self.status("Created \(made.displayName). Agent key \(made.agentPubkeyHex.prefix(16))…")
            } catch let e as BuzzConnectionStore.StoreError { self.status("⚠ \(e.message)") } catch { self.status("⚠ \(error)") }
            self.refreshBuzz()
        })
        return box
    }

    func refreshBuzz() {
        guard let secrets, buzzList != nil else { return }
        let store = BuzzConnectionStore(path: paths.buzzConnectionsFile, secrets: secrets)
        let list = store.load()
        Task {
            var states: [String: ChildSupervisor.State] = [:]
            for c in list { states[c.id] = await supervisor.state("buzz-\(c.id)") }
            var counters: [String: BuzzGatewayCounters] = [:]
            for c in list {
                var k = BuzzGatewayCounters()
                for l in await tailers["buzz-\(c.id)"]?.lines ?? [] { k.ingest(line: l.text) }
                counters[c.id] = k
            }
            onMain { [self] in
                clearList(self.buzzList)
                if list.isEmpty { gtk_list_box_append(cast(self.buzzList), label("No connections yet.")) }
                for c in list {
                    let col = vbox(3)
                    let probs = BuzzConnectionStore.problems(with: c, hasKey: store.hasAgentKey(id: c.id))
                    let st = states[c.id] ?? .stopped
                    let k = counters[c.id] ?? BuzzGatewayCounters()
                    let h = label("\(c.displayName) @ \(c.relayHost) · \(st.label)\(k.authenticated ? " · connected" : "") · replies \(k.replies) · tokens \(k.tokens)")
                    addClass(h, "title"); append(col, h)
                    append(col, label("agent \(c.agentPubkeyHex)", selectable: true))
                    if let f = k.lastFailure { let w = label("last failure: " + clean(f), wrap: true); addClass(w, "warn"); append(col, w) }
                    for p in probs { let w = label("! " + p.message, wrap: true); addClass(w, "warn"); append(col, w) }
                    let r = hbox(6)
                    append(r, button(st.isRunning ? "Stop" : "Start") { [unowned self] in
                        if st.isRunning { Task { await self.supervisor.stop(id: "buzz-\(c.id)"); onMain { self.refreshBuzz() } } }
                        else { self.startBuzz(c, store: store) }
                    })
                    append(r, button("Remove") { [unowned self] in
                        Task {
                            await self.supervisor.stop(id: "buzz-\(c.id)")
                            onMain { try? store.remove(id: c.id); self.refreshBuzz() }
                        }
                    })
                    append(col, r)
                    gtk_list_box_append(cast(self.buzzList), col)
                }
            }
        }
    }

    func startBuzz(_ c: BuzzConnection, store: BuzzConnectionStore) {
        let probs = BuzzConnectionStore.problems(with: c, hasKey: store.hasAgentKey(id: c.id))
        guard probs.isEmpty, let key = store.agentPrivateKeyHex(id: c.id) else {
            status("⚠ " + probs.map(\.message).joined(separator: " ")); return
        }
        let env = BuzzConnectionStore.environment(for: c, agentPrivateKeyHex: key, llmURL: settings.llmURL, llmModel: settings.llmModel, llmToken: token)
        let log = paths.buzzLogFile(connectionID: c.id)
        tailers["buzz-\(c.id)"] = LogTailer(path: log, capacity: 500, startAtEnd: true)
        let exe = binary("eldr-buzz-agent")
        Task {
            let cmd = BridgeSettings.lineBuffered(exe, [])
            let st = await supervisor.start(id: "buzz-\(c.id)", executable: cmd.executable, arguments: cmd.arguments, environment: env, logPath: log)
            onMain { [self] in self.status("Buzz \(c.displayName): \(st.label)"); self.refreshBuzz() }
        }
    }

    // MARK: - Relay provisioner

    func relayPage() -> Widget {
        let box = vbox(8); margins(box, 14)
        let t = label("Provision your own relay (khatru, NIP-42 AUTH-gated)"); addClass(t, "title"); append(box, t)
        append(box, label("Generates a script to run on YOUR server. Nothing is sent anywhere; secrets are entered on the host, never pasted here.", wrap: true))
        let domain = entry("", placeholder: "relay.example.com")
        let port = entry("7777")
        let keys = entry("", placeholder: "allowed 64-hex pubkeys, comma-separated")
        let tls = entry("cloudflare", placeholder: "cloudflare | letsEncrypt | none")
        append(box, row("Domain", domain)); append(box, row("Port", port)); append(box, row("AUTH allowlist", keys)); append(box, row("TLS", tls))
        let out = textView("", editable: false); addClass(out, "mono")
        let r = hbox(6)
        append(r, button("Generate install script") { [unowned self] in
            var cfg = RelayProvisioner.Config()
            cfg.domain = entryText(domain)
            cfg.httpPort = Int(entryText(port)) ?? 0
            cfg.allowedPubkeys = entryText(keys).split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            cfg.tlsMode = RelayProvisioner.TLSMode(rawValue: entryText(tls)) ?? .cloudflare
            let p = RelayProvisioner(config: cfg)
            if let s = p.installScriptIfValid() { setTextViewText(out, s); self.status("Script generated.") }
            else { setTextViewText(out, p.validate().map { "✗ " + $0.message }.joined(separator: "\n")) }
        })
        append(r, button("Copy") { [unowned self] in copyToClipboard(self.window, textViewText(out)) })
        append(box, r)
        append(box, sized(out, 420))
        return box
    }

    // MARK: - World

    func worldPage() -> Widget {
        let box = vbox(8); margins(box, 14)
        let t = label("World — towns your node is connected to (read-only)"); addClass(t, "title"); append(box, t)
        worldLabel = label("Not loaded.", wrap: true); append(box, worldLabel)
        append(box, button("Refresh") { [unowned self] in self.refreshWorld() })
        if let area = drawingArea(width: 900, height: 460, { [unowned self] cr, w, h in self.drawWorld(cr, w, h) }) {
            worldArea = area
            expand(area, h: true, v: true)
            append(box, area)
        }
        return box
    }

    func refreshWorld() {
        Task {
            do {
                let w = try await WorldStatusClient.fetch(paths: paths)
                onMain { [self] in
                    self.world = w
                    setLabel(self.worldLabel, "Node \(w.nodeTownID.prefix(12))… · \(w.towns.count) town(s) · \(w.droppedInboundCount) dropped inbound")
                    if let a = self.worldArea { redraw(a) }
                }
            } catch {
                let msg = (error as? WorldStatusError)?.message ?? "\(error)"
                onMain { [self] in self.world = nil; setLabel(self.worldLabel, msg); if let a = self.worldArea { redraw(a) } }
            }
        }
    }

    func drawWorld(_ cr: OpaquePointer, _ w: Int32, _ h: Int32) {
        let cx = Double(w) / 2, cy = Double(h) / 2
        let towns = world?.towns ?? []
        let radius = min(cx, cy) - 60
        cairo_set_font_size(cr, 12)
        for (i, t) in towns.enumerated() {
            let a = 2 * Double.pi * Double(i) / Double(max(towns.count, 1)) - Double.pi / 2
            let x = cx + radius * cos(a), y = cy + radius * sin(a)
            cairo_set_source_rgba(cr, 0.5, 0.5, 0.5, 0.6)
            if !t.wallGranted { let d: [Double] = [4, 4]; cairo_set_dash(cr, d, 2, 0) }
            cairo_move_to(cr, cx, cy); cairo_line_to(cr, x, y); cairo_stroke(cr)
            cairo_set_dash(cr, nil, 0, 0)
            cairo_set_source_rgba(cr, t.delegateGranted ? 0.15 : 0.35, t.wallGranted ? 0.6 : 0.35, 0.3, 1)
            cairo_arc(cr, x, y, 10, 0, 2 * Double.pi); cairo_fill(cr)
            cairo_move_to(cr, x - 30, y + 26)
            cairo_show_text(cr, "\(clean(t.label)) \(t.wallGranted ? "· wall" : "")\(t.delegateGranted ? " · delegate" : "")")
        }
        cairo_set_source_rgba(cr, 0.57, 0.25, 0.67, 1)
        cairo_arc(cr, cx, cy, 14, 0, 2 * Double.pi); cairo_fill(cr)
        cairo_move_to(cr, cx - 24, cy + 32); cairo_show_text(cr, "this node")
        if towns.isEmpty { cairo_move_to(cr, cx - 80, cy - 34); cairo_show_text(cr, world == nil ? "Node not reachable" : "No towns authorized yet") }
    }

    // MARK: - Setup (install + register)

    func setupPage() -> Widget {
        let box = vbox(8); margins(box, 14)
        let t = label("Install the agent and connect your editor"); addClass(t, "title"); append(box, t)
        setupLabel = label("", wrap: true, selectable: true); append(box, setupLabel)
        append(box, button("Install eldr-acp + launcher into \(paths.binDir)") { [unowned self] in
            var dirs = [(CommandLine.arguments[0] as NSString).deletingLastPathComponent]
            if let extra = ProcessInfo.processInfo.environment["HUGINN_BIN_SOURCE"] { dirs = extra.split(separator: ":").map(String.init) + dirs }
            do {
                let r = try HuginnInstaller(paths: self.paths).install(from: dirs)
                self.status("Installed \(r.installed.joined(separator: ", ")).")
            } catch { self.status("⚠ \(error)") }
            self.refreshSetup()
        })
        let r = hbox(6)
        append(r, button("Register with Zed") { [unowned self] in self.register(.zed) })
        append(r, button("Register with acpx / OpenClaw CLI") { [unowned self] in self.register(.acpxGlobal) })
        append(box, r)
        let na = label("""
            Not on Linux (see docs/plan/HUGINN-LINUX.md): MLX (Apple-silicon only — point the endpoint at llama.cpp / Ollama / vLLM instead), \
            Nearby (Multipeer), the menu-bar extra, Secure-Enclave key wrapping (the EldrKeystore TPM/passphrase ladder replaces it), \
            Xcode registration (Zed replaces it).
            """, wrap: true)
        addClass(na, "meta"); append(box, na)
        refreshSetup()
        return box
    }

    func refreshSetup() {
        let inst = HuginnInstaller(paths: paths).isInstalled
        let zed = HarnessRegistration.isRegistered(target: .zed)
        let acpx = HarnessRegistration.isRegistered(target: .acpxGlobal)
        setLabel(setupLabel, """
            Agent installed: \(inst ? "yes — launcher \(paths.launcher)" : "no")
            Zed: \(zed ? "registered" : "not registered")    acpx: \(acpx ? "registered" : "not registered")
            Config dir: \(paths.configDir)
            """)
    }

    func register(_ target: HarnessRegistration.Target) {
        do {
            let plan = try HarnessRegistration.plan(target: target, launcherPath: paths.launcher)
            let out = try HarnessRegistration.apply(plan, gatewayRunning: false)
            status("\(out)")
        } catch {
            let msg = (error as? HarnessRegistration.RegError)?.message ?? "\(error)"
            if target == .zed { copyToClipboard(window, HarnessRegistration.zedSnippet(launcherPath: paths.launcher)) }
            status("⚠ \(msg)\(target == .zed ? " The snippet is on your clipboard." : "")")
        }
        refreshSetup()
    }

    // MARK: - Timer + shutdown

    var tickCount = 0
    func tick() {
        tickCount += 1
        if tickCount % 15 == 1 { refreshWorld() }
        Task {
            let fresh = await agentLog.poll()
            if !fresh.isEmpty { onMain { [self] in self.renderLogs() } }
            if let l = learner { await l.poll(); if tickCount % 5 == 0 { await refreshMemory() } }
            for (id, t) in tailers { let n = await t.poll(); if id == "eldr-node", !n.isEmpty { let all = await t.lines; onMain { [self] in setTextViewText(self.nodeLogTV, all.map { clean($0.text) }.joined(separator: "\n")) } } }
            let node = await supervisor.state("eldr-node")
            onMain { [self] in setLabel(self.bridgeState, node.label); if self.tickCount % 3 == 0 { self.refreshBuzz() } }
        }
    }

    /// Stop every child before the process exits — Huginn never leaves anything running.
    func shutdown() {
        if timer != 0 { g_source_remove(timer); timer = 0 }
        let sup = supervisor
        let done = DispatchSemaphore(value: 0)
        Task.detached { await sup.stopAll(); done.signal() }
        _ = done.wait(timeout: .now() + 10)
    }
}

let ui = HuginnUI()
let app = gtk_application_new("app.eldr.HuginnGtk", G_APPLICATION_NON_UNIQUE)!
on(app, "activate") { ui.build(app) }
on(app, "shutdown") { ui.shutdown() }
for sig in [SIGINT, SIGTERM] {
    g_unix_signal_add_full(G_PRIORITY_DEFAULT, sig, { d in
        g_application_quit(cast(d)); return 0
    }, UnsafeMutableRawPointer(app), nil)
}
let rc = g_application_run(cast(app), 0, nil)
g_object_unref(app)
exit(rc)
