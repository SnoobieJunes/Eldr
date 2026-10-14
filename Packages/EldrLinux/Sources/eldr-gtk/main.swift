// SPDX-License-Identifier: Apache-2.0
// eldr-gtk — the native Linux Eldr desktop app (Milestone 3). GTK 4 through its C API
// (module CGtk4 + our thin GtkKit), on the same EldrClientCore engine as eldr-chat.
// It shares eldr-chat's state directory and keystore; only one of them can hold a
// given state directory at a time (DirectoryLock).
import EldrClientCore
import EldrKeystore
import EldrUIModel
import Foundation
import GtkKit
import PQRCCore
import PQRCNostr

let usage = """
    eldr-gtk — Eldr post-quantum messenger, Linux desktop

    USAGE: eldr-gtk [--state DIR] [--relay URL] [--auto-accept NPUB] [--auto-accept-identity HEX]

    State + keystore are the same as eldr-chat (default $ELDR_CHAT_DIR or
    ~/.local/share/eldr-chat; passphrase from ELDR_CHAT_PASSPHRASE[_FILE] or the TTY).
    A new identity is created and announced on first run.
    """

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
if args.contains("--help") || args.contains("-h") { print(usage); exit(0) }
let env = ProcessInfo.processInfo.environment
let relayURL = opt("--relay") ?? env["ELDR_CHAT_RELAY"] ?? "wss://relay.lerants.com"
let stateDir: URL = {
    if let s = opt("--state") ?? env["ELDR_CHAT_DIR"] { return URL(fileURLWithPath: s) }
    let base = env["XDG_DATA_HOME"] ?? ((env["HOME"] ?? ".") + "/.local/share")
    return URL(fileURLWithPath: base).appendingPathComponent("eldr-chat")
}()
let autoAccept = opt("--auto-accept").flatMap { PairingLink.parse($0)?.nostrPubkeyHex }
let autoAcceptIdentity = opt("--auto-accept-identity")

func die(_ s: String) -> Never { FileHandle.standardError.write(Data("eldr-gtk: \(s)\n".utf8)); exit(1) }

try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let store: FileIdentityStore
do { store = try makeClientKeystore(directory: stateDir, environment: env).0 } catch { die("\(error)") }

/// All UI state. Touched ONLY on the GTK main thread (callbacks and `onMain`).
// @unchecked Sendable: GTK is single-threaded; every access is on the main loop
// (callbacks + `onMain`), never from a background task.
final class AppUI: @unchecked Sendable {
    var client: EldrClient?
    var snap: UISnapshot?
    var selected: String?
    var convIDs: [String] = []
    var rebuilding = false
    var pendingSponsor: (id: String, days: Int, at: Date)?

    var window: Widget!
    var meLabel: Widget!
    var bannerLabel: Widget!
    var addEntry: Widget!
    var groupEntry: Widget!
    var convList: Widget!
    var reqList: Widget!
    var reqTitle: Widget!
    var statusLabel: Widget!
    var headerLabel: Widget!
    var sponsorBar: Widget!
    var reconnectBar: Widget!
    var msgList: Widget!
    var msgScroll: Widget!
    var composer: Widget!
    var sendButton: Widget!
    var aiBar: Widget!
    var aiLabel: Widget!
    var threadEntry: Widget!
    var threadButton: Widget!
    var groupBar: Widget!
    var renameEntry: Widget!

    func status(_ s: String) { setLabel(statusLabel, UIFormat.sanitizeLine(s)) }

    // MARK: Build

    func build(_ app: UnsafeMutablePointer<GtkApplication>) {
        installCSS("""
            .bubble-in { background: alpha(@theme_fg_color, 0.07); border-radius: 10px; padding: 8px 10px; }
            .bubble-out { background: alpha(#3584e4, 0.18); border-radius: 10px; padding: 8px 10px; }
            .bubble-ai { border-left: 3px solid #9141ac; }
            .meta { font-size: 0.82em; opacity: 0.7; }
            .banner { background: alpha(#9141ac, 0.15); border-radius: 6px; padding: 6px; }
            .warn { color: #c01c28; }
            .title { font-weight: bold; font-size: 1.2em; }
            """)
        window = gtk_application_window_new(app)
        gtk_window_set_title(cast(window), "Eldr")
        gtk_window_set_default_size(cast(window), 1100, 740)

        let paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_position(cast(paned), 330)

        // Sidebar
        let side = vbox(8); margins(side, 10)
        let title = label("Eldr"); addClass(title, "title"); append(side, title)
        meLabel = label("Opening…", wrap: true, selectable: true); addClass(meLabel, "meta"); append(side, meLabel)
        append(side, button("Copy my pairing link") { [unowned self] in
            if let l = self.snap?.link { copyToClipboard(self.window, l); self.status("Pairing link copied.") }
        })
        let toolRow = hbox(4)
        append(toolRow, button("Show QR") { [unowned self] in self.showQR() })
        append(toolRow, button("Settings") { [unowned self] in self.showSettings() })
        append(side, toolRow)
        bannerLabel = label("", wrap: true); addClass(bannerLabel, "banner"); gtk_widget_set_visible(bannerLabel, 0)
        append(side, bannerLabel)
        let addRow = hbox(4)
        addEntry = gtk_entry_new()
        gtk_entry_set_placeholder_text(cast(addEntry), "npub or pqrc:add link  [name]")
        expand(addEntry, h: true)
        on(addEntry, "activate") { [unowned self] in self.addContact() }
        append(addRow, addEntry)
        append(addRow, button("Add") { [unowned self] in self.addContact() })
        append(side, addRow)
        let groupRow = hbox(4)
        groupEntry = gtk_entry_new()
        gtk_entry_set_placeholder_text(cast(groupEntry), "Group name: contact, contact…")
        expand(groupEntry, h: true)
        on(groupEntry, "activate") { [unowned self] in self.createGroup() }
        append(groupRow, groupEntry)
        append(groupRow, button("New group") { [unowned self] in self.createGroup() })
        append(side, groupRow)
        let ct = label("Conversations"); addClass(ct, "meta"); append(side, ct)
        convList = gtk_list_box_new()
        on(convList, "row-selected") { [unowned self] (row: UnsafeMutableRawPointer?) in
            guard !self.rebuilding, let row else { return }
            let i = Int(gtk_list_box_row_get_index(cast(row)))
            guard self.convIDs.indices.contains(i) else { return }
            let changed = self.selected != self.convIDs[i]
            self.selected = self.convIDs[i]
            self.renderConversation(scrollToEnd: changed)
        }
        let cs = scrolled(convList); expand(cs, v: true); append(side, cs)
        reqTitle = label("Requests"); addClass(reqTitle, "meta"); append(side, reqTitle)
        reqList = gtk_list_box_new(); gtk_list_box_set_selection_mode(cast(reqList), GTK_SELECTION_NONE)
        append(side, reqList)
        statusLabel = label("", wrap: true, selectable: true); addClass(statusLabel, "meta"); append(side, statusLabel)
        gtk_paned_set_start_child(cast(paned), side)
        gtk_paned_set_shrink_start_child(cast(paned), 0)

        // Conversation pane
        let main = vbox(6); margins(main, 10)
        headerLabel = label("Select a conversation", wrap: true, selectable: true); addClass(headerLabel, "title")
        append(main, headerLabel)
        sponsorBar = hbox(6)
        append(sponsorBar, label("AI sponsorship:"))
        for d in EldrClient.sponsorshipDayChoices {
            append(sponsorBar, button("Sponsor \(d) day\(d == 1 ? "" : "s")") { [unowned self] in self.sponsor(days: d) })
        }
        append(sponsorBar, button("Revoke") { [unowned self] in self.revoke() })
        gtk_widget_set_visible(sponsorBar, 0)
        append(main, sponsorBar)
        // My AI (SPEC §13): a window in a conversation, an invite in a thread. Every
        // live AI is shown in the header for its whole duration (invariant 9).
        aiBar = hbox(6)
        aiLabel = label("My AI here:"); append(aiBar, aiLabel)
        for (t, secs) in [("1h", Int64(3600)), ("8h", Int64(8 * 3600)), ("24h", Int64(24 * 3600))] {
            append(aiBar, button(t) { [unowned self] in self.myAI(seconds: secs) })
        }
        append(aiBar, button("Off") { [unowned self] in self.myAI(seconds: 0) })
        append(aiBar, button("Draft privately") { [unowned self] in self.draft() })
        threadEntry = gtk_entry_new()
        gtk_entry_set_placeholder_text(cast(threadEntry), "New thread title")
        expand(threadEntry, h: true)
        on(threadEntry, "activate") { [unowned self] in self.startThread() }
        append(aiBar, threadEntry)
        threadButton = button("Start thread") { [unowned self] in self.startThread() }
        append(aiBar, threadButton)
        append(main, aiBar)
        groupBar = hbox(6)
        renameEntry = gtk_entry_new()
        gtk_entry_set_placeholder_text(cast(renameEntry), "Rename group to…")
        expand(renameEntry, h: true)
        append(groupBar, renameEntry)
        append(groupBar, button("Rename") { [unowned self] in self.renameGroup() })
        append(groupBar, button("Leave group") { [unowned self] in self.leaveGroup() })
        gtk_widget_set_visible(groupBar, 0)
        append(main, groupBar)
        reconnectBar = hbox(6)
        let rl = label("This contact reset their app and wants to reconnect. Check their safety code first.", wrap: true)
        addClass(rl, "banner"); expand(rl, h: true); append(reconnectBar, rl)
        append(reconnectBar, button("Reconnect") { [unowned self] in self.reconnect(accept: true) })
        append(reconnectBar, button("Decline") { [unowned self] in self.reconnect(accept: false) })
        gtk_widget_set_visible(reconnectBar, 0)
        append(main, reconnectBar)
        msgList = gtk_list_box_new(); gtk_list_box_set_selection_mode(cast(msgList), GTK_SELECTION_NONE)
        msgScroll = scrolled(msgList); expand(msgScroll, h: true, v: true); append(main, msgScroll)

        composer = gtk_text_view_new()
        gtk_text_view_set_wrap_mode(cast(composer), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(cast(composer), 1)
        let key = gtk_event_controller_key_new()!
        onKeyPressed(key) { [unowned self] kv, st in
            let enter = kv == 0xff0d || kv == 0xff8d  // GDK_KEY_Return / KP_Enter
            let ctrl = (st.rawValue & GDK_CONTROL_MASK.rawValue) != 0
            if UIFormat.composerShouldSend(isEnter: enter, ctrl: ctrl) { self.send(); return true }
            return false
        }
        gtk_widget_add_controller(composer, key)
        let compScroll = scrolled(composer)
        gtk_widget_set_size_request(compScroll, -1, 130)
        append(main, compScroll)
        let sendRow = hbox(6)
        let hint = label("Enter = new line · Ctrl+Enter = send · paste Markdown of any size"); addClass(hint, "meta")
        expand(hint, h: true); append(sendRow, hint)
        sendButton = button("Send") { [unowned self] in self.send() }
        append(sendRow, sendButton)
        append(main, sendRow)
        gtk_paned_set_end_child(cast(paned), main)

        gtk_window_set_child(cast(window), paned)
        gtk_window_present(cast(window))
    }

    // MARK: Render

    func refresh() {
        guard let c = client else { return }
        Task {
            let s = await UISnapshot.capture(c)
            onMain { [self] in self.snap = s; self.render() }
        }
    }

    func render() {
        guard let s = snap else { return }
        setLabel(meLabel, "You: \(s.npub)\nidentity \(s.me.prefix(16))…")
        if let b = s.agentBanner { setLabel(bannerLabel, b) }
        gtk_widget_set_visible(bannerLabel, s.agentBanner == nil ? 0 : 1)

        rebuilding = true
        clearList(convList)
        let convs = s.conversations()
        convIDs = convs.map(\.identityHex)
        for c in convs {
            let row = vbox(2); margins(row, 6)
            append(row, label((c.isAgent ? "🤖 " : "") + c.title))
            let p = label(c.preview); addClass(p, "meta")
            gtk_label_set_ellipsize(cast(p), PANGO_ELLIPSIZE_END)
            append(row, p)
            gtk_list_box_append(cast(convList), row)
        }
        if let sel = selected, let i = convIDs.firstIndex(of: sel) {
            gtk_list_box_select_row(cast(convList), gtk_list_box_get_row_at_index(cast(convList), Int32(i)))
        }
        rebuilding = false

        clearList(reqList)
        gtk_widget_set_visible(reqTitle, s.requests.isEmpty ? 0 : 1)
        for r in s.requests {
            let row = hbox(4); margins(row, 4)
            let l = label("✉ \(Bech32.npub(r.nostrPubkeyHex).prefix(20))… ×\(r.count)"); expand(l, h: true)
            append(row, l)
            let n = r.nostrPubkeyHex
            append(row, button("Accept") { [unowned self] in self.act("Accepted.") { try await $0.accept(n) } })
            append(row, button("Decline") { [unowned self] in self.act("Declined.") { try await $0.decline(n) } })
            gtk_list_box_append(cast(reqList), row)
        }
        renderConversation(scrollToEnd: false)
    }

    /// `scrollToEnd`: jump to the newest message (a different conversation was picked).
    /// Otherwise follow new messages only if the reader was already near the bottom,
    /// and keep their place if they had scrolled up.
    func renderConversation(scrollToEnd: Bool) {
        guard let s = snap, let id = selected else { return }
        setLabel(headerLabel, s.header(for: id))
        let isGroup = UISnapshot.groupID(id) != nil
        let isThread = UISnapshot.threadID(id) != nil
        gtk_widget_set_visible(sponsorBar, s.isAgent || isGroup || isThread ? 0 : 1)
        gtk_widget_set_visible(groupBar, isGroup ? 1 : 0)
        gtk_widget_set_visible(aiBar, s.isAgent ? 0 : 1)
        gtk_widget_set_visible(threadEntry, isThread ? 0 : 1)
        gtk_widget_set_visible(threadButton, isThread ? 0 : 1)
        setLabel(aiLabel, s.provider == nil ? "My AI (set it up in Settings):" : (isThread ? "Invite my AI:" : "My AI answers here for:"))
        gtk_widget_set_visible(reconnectBar, s.pendingReconnects.contains(id) ? 1 : 0)
        let adj = gtk_scrolled_window_get_vadjustment(cast(msgScroll))
        let follow = scrollToEnd || UIFormat.shouldFollow(
            value: gtk_adjustment_get_value(adj), pageSize: gtk_adjustment_get_page_size(adj),
            upper: gtk_adjustment_get_upper(adj))
        let keep = gtk_adjustment_get_value(adj)
        clearList(msgList)
        let peerName = s.name(of: id) ?? "them"
        for m in s.messages(with: id).suffix(300) {
            let col = vbox(2); margins(col, 4)
            let who = m.outgoing ? "You" : ((isGroup || isThread) ? (s.name(of: m.peerIdentityHex) ?? String(m.peerIdentityHex.prefix(8)) + "…") : peerName)
            var meta = "\(who) · \(UIFormat.date(m.sentAt))"
            let badge = UIFormat.rowBadge(m, names: s.name(of:))
            if !badge.text.isEmpty { meta += " · " + badge.text }
            let ml = label(meta, wrap: true); addClass(ml, "meta")
            if badge.warn { addClass(ml, "warn") }
            append(col, ml)
            let (text, truncated) = UIFormat.renderBody(m.text)
            let body = label("", wrap: true, selectable: true)
            setMarkup(body, UIFormat.markdownToPango(text), fallback: text)
            addClass(body, m.outgoing ? "bubble-out" : "bubble-in")
            if m.agent { addClass(body, "bubble-ai") }
            append(col, body)
            if truncated {
                let full = m.text
                append(col, button("Showing first \(UIFormat.maxRenderedChars) characters — copy full message") { [unowned self] in
                    copyToClipboard(self.window, full); self.status("Full message copied.")
                })
            }
            gtk_widget_set_halign(col, m.outgoing ? GTK_ALIGN_END : GTK_ALIGN_START)
            gtk_widget_set_size_request(col, -1, -1)
            gtk_list_box_append(cast(msgList), col)
        }
        // The list relayouts asynchronously; apply the position once it has settled.
        let box = ScrollTarget(adj: adj, toEnd: follow, value: keep)
        _ = g_timeout_add_full(G_PRIORITY_DEFAULT, 150, { d in
            let t = Unmanaged<ScrollTarget>.fromOpaque(d!).takeRetainedValue()
            gtk_adjustment_set_value(t.adj, t.toEnd ? gtk_adjustment_get_upper(t.adj) : t.value)
            return 0
        }, Unmanaged.passRetained(box).toOpaque(), nil)
    }

    func reconnect(accept: Bool) {
        guard let id = selected else { return }
        let who = snap?.name(of: id) ?? "contact"
        if accept {
            act(nil) { c in
                let ok = try await c.approveReconnect(id)
                onMain { [self] in
                    self.status(ok ? "🔄 Reconnected with \(who)." : "Approved: the next reconnect from \(who) will be accepted.")
                }
            }
        } else {
            act("Declined; the existing session with \(who) is kept.") { c in try await c.declineReconnect(id) }
        }
    }

    // MARK: Actions (async work off the main thread, results hopped back)

    func act(_ ok: String?, _ f: @escaping @Sendable (EldrClient) async throws -> Void) {
        guard let c = client else { status("Still connecting…"); return }
        Task {
            do {
                try await f(c)
                onMain { [self] in if let ok { self.status(ok) }; self.refresh() }
            } catch {
                onMain { [self] in self.status("⚠ \(error)"); self.refresh() }
            }
        }
    }

    func addContact() {
        let parts = entryText(addEntry).split(separator: " ", maxSplits: 1).map(String.init)
        guard let link = parts.first, PairingLink.parse(link) != nil else {
            status("Paste an npub, pqrc:add link or 64-hex key (optionally followed by a name)."); return
        }
        let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        status("Looking up \(link.prefix(16))… on the relay")
        act(nil) { c in
            let rec = try await c.addContact(link, name: name)
            onMain { [self] in
                setEntryText(self.addEntry, "")
                self.selected = rec.identityHex
                self.status("Added \(rec.name ?? "contact") — keys verified.")
            }
        }
    }

    func send() {
        guard let id = selected else { status("Pick a conversation first."); return }
        guard let client else { status("Still connecting…"); return }
        let text = textViewText(composer)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        gtk_widget_set_sensitive(sendButton, 0)
        status(text.utf8.count > 16_000 ? "Sending large message in parts…" : "Sending…")
        Task { [self] in
            do {
                let r: String
                if let tid = UISnapshot.threadID(id) {
                    let n = try await client.say(text, in: "", thread: tid)
                    r = "to \(n.reached) member(s)"
                } else if let gid = UISnapshot.groupID(id) {
                    let n = try await client.sendToGroup(text, group: gid)
                    r = "to \(n.reached) member(s)" + (n.skipped > 0 ? ", \(n.skipped) not in your contacts" : "")
                } else { r = "\(try await client.send(text, to: id))" }
                onMain { [self] in
                    // Only clear if the user hasn't typed something new meanwhile.
                    if textViewText(self.composer) == text { setTextViewText(self.composer, "") }
                    gtk_widget_set_sensitive(self.sendButton, 1)
                    self.status("Sent (\(r)).")
                    self.refresh()
                }
            } catch {
                // Keep the text so a large paste is never lost.
                onMain { [self] in gtk_widget_set_sensitive(self.sendButton, 1); self.status("⚠ Not sent: \(error)") }
            }
        }
    }

    func conversationForAI(_ id: String) -> String {
        if let g = UISnapshot.groupID(id) { return UIConversation.group(g) }
        return id
    }

    /// 1h/8h/24h opens my window (conversation) or invite (thread); 0 turns it off.
    func myAI(seconds: Int64) {
        guard let id = selected else { status("Pick a conversation first."); return }
        if snap?.provider == nil && seconds > 0 { status("Set up an AI endpoint in Settings first."); return }
        if let tid = UISnapshot.threadID(id) {
            act(seconds == 0 ? "Your AI left the thread (everyone was told)." : "Your AI joined the thread; everyone there sees it.") { c in
                if seconds == 0 { try await c.withdrawMyAI(thread: tid) } else { _ = try await c.inviteMyAI(thread: tid, seconds: seconds) }
            }
        } else {
            let conv = conversationForAI(id)
            act(seconds == 0 ? "Your AI is off (everyone was told)." : "Your AI answers here for \(seconds / 3600)h; everyone here sees it.") { c in
                if seconds == 0 { try await c.endAIWindow() } else { _ = try await c.startAIWindow(in: conv, seconds: seconds) }
            }
        }
    }

    /// A private draft from my AI goes into the composer, and nothing is sent.
    func draft() {
        guard let id = selected else { return }
        status("Asking your AI for a private draft…")
        let tid = UISnapshot.threadID(id), conv = conversationForAI(id)
        act(nil) { c in
            let d = try await c.draftWithMyAI(in: conv, thread: tid)
            onMain { [self] in setTextViewText(self.composer, d); self.status("Draft ready — edit it, then Ctrl+Enter to send.") }
        }
    }

    func startThread() {
        guard let id = selected, UISnapshot.threadID(id) == nil else { return }
        let title = entryText(threadEntry).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { status("Type a thread title first."); return }
        let conv = conversationForAI(id)
        act(nil) { c in
            let t = try await c.createThread(in: conv, title: title)
            onMain { [self] in
                setEntryText(self.threadEntry, ""); self.selected = UISnapshot.threadPrefix + t.threadID
                self.status("Started thread “\(UIFormat.sanitizeLine(t.title))”.")
            }
        }
    }

    func renameGroup() {
        guard let id = selected, let gid = UISnapshot.groupID(id) else { return }
        let name = entryText(renameEntry)
        act("Group renamed.") { c in _ = try await c.reviseGroup(gid, rename: name) }
        setEntryText(renameEntry, "")
    }

    func leaveGroup() {
        guard let id = selected, let gid = UISnapshot.groupID(id) else { return }
        selected = nil
        act("You left the group (history kept on this device).") { c in try await c.leaveGroup(gid) }
    }

    // MARK: QR + Settings windows

    func showQR() {
        guard let link = snap?.link, let q = try? QRCode.encode(link) else { status("No pairing link yet."); return }
        let (w, px) = q.rgba(scale: 6)
        let win = gtk_window_new()!
        gtk_window_set_title(cast(win), "Scan to add me")
        gtk_window_set_transient_for(cast(win), cast(window))
        let box = vbox(8); margins(box, 12)
        let bytes = px.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        let tex = gdk_memory_texture_new(Int32(w), Int32(w), GDK_MEMORY_R8G8B8A8, bytes, gsize(w * 4))
        g_bytes_unref(bytes)
        let pic = gtk_picture_new_for_paintable(tex)!
        g_object_unref(UnsafeMutableRawPointer(tex))  // the picture holds its own ref
        gtk_widget_set_size_request(pic, Int32(w), Int32(w))
        append(box, pic)
        append(box, label(link, wrap: true, selectable: true))
        append(box, button("Copy link") { [unowned self] in copyToClipboard(self.window, link); self.status("Pairing link copied.") })
        gtk_window_set_child(cast(win), box)
        gtk_window_present(cast(win))
    }

    func showSettings() {
        guard let s = snap else { return }
        let win = gtk_window_new()!
        gtk_window_set_title(cast(win), "Settings")
        gtk_window_set_transient_for(cast(win), cast(window))
        gtk_window_set_default_size(cast(win), 520, -1)
        let box = vbox(6); margins(box, 12)
        func field(_ title: String, _ value: String, password: Bool = false) -> Widget {
            append(box, label(title))
            let e = password ? gtk_password_entry_new()! : gtk_entry_new()!
            setEntryText(e, value)
            append(box, e)
            return e
        }
        let name = field("Display name (shown to your AI)", s.settings.displayName ?? "")
        let guardE = field("Loop guard: consecutive AI messages before AIs pause (0 = off)",
                           String(s.settings.loopGuardLimit ?? EldrClient.defaultLoopGuardLimit))
        let relays = field("Relays (comma-separated; used from the next launch)", relayURL)
        append(box, label("AI endpoint (OpenAI-compatible: LM Studio, Ollama, vLLM, OpenAI, OpenRouter…)"))
        let base = field("Base URL, e.g. http://127.0.0.1:11434/v1", s.provider?.baseURL ?? "")
        let model = field("Model", s.provider?.model ?? "")
        let instr = field("Instructions (optional system prompt)", s.provider?.instructions ?? "")
        let key = field("API key (blank keeps the stored one; saved encrypted)", "", password: true)
        let row = hbox(6)
        let note = label("", wrap: true); addClass(note, "meta")
        append(row, button("Save") { [unowned self] in
            let st = ClientSettings(displayName: entryText(name).isEmpty ? nil : entryText(name),
                                    loopGuardLimit: Int(entryText(guardE)))
            let relayList = entryText(relays).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let b = entryText(base).trimmingCharacters(in: .whitespaces), m = entryText(model), i = entryText(instr), k = entryText(key)
            self.act("Settings saved.") { c in
                try await c.updateSettings(st)
                try await c.setRelays(relayList)
                if b.isEmpty { try await c.configureProvider(nil, apiKey: nil) }
                else { try await c.configureProvider(AIProviderConfig(baseURL: b, model: m, instructions: i.isEmpty ? nil : i), apiKey: k.isEmpty ? nil : k) }
            }
            setEntryText(key, "")
        })
        append(row, button("Test AI") { [unowned self] in
            setLabel(note, "Testing…")
            self.act(nil) { c in
                do { let r = try await c.testProvider(); onMain { setLabel(note, "AI says: " + UIFormat.sanitizeLine(r)) } }
                catch { onMain { setLabel(note, "⚠ \(error)") } }
            }
        })
        append(box, row)
        append(box, note)
        gtk_window_set_child(cast(win), box)
        gtk_window_present(cast(win))
    }

    /// "Name: contact, contact" → a new group announced to those contacts.
    func createGroup() {
        let raw = entryText(groupEntry)
        guard let colon = raw.firstIndex(of: ":") else { status("Type: Group name: contact, contact…"); return }
        let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
        let members = raw[raw.index(after: colon)...].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !name.isEmpty, !members.isEmpty else { status("A group needs a name and at least one contact."); return }
        act(nil) { c in
            let (g, n) = try await c.createGroup(name: name, members: members)
            onMain { [self] in
                setEntryText(self.groupEntry, "")
                self.selected = UISnapshot.groupPrefix + g.groupID
                self.status("Created \"\(g.name)\"; announced to \(n) member(s).")
            }
        }
    }

    func sponsor(days: Int) {
        guard let id = selected, let s = snap else { return }
        let who = s.name(of: id) ?? "this contact"
        if let p = pendingSponsor, p.id == id, p.days == days, Date().timeIntervalSince(p.at) < 8 {
            pendingSponsor = nil
            act("Sponsorship sent: you vouch for \(who)'s AI account for \(days) day(s).") { c in
                _ = try await c.sponsor(id, days: days)
            }
        } else {
            pendingSponsor = (id, days, Date())
            status("Click “Sponsor \(days) day\(days == 1 ? "" : "s")” again to sign a sponsorship for \(who) as an AI account you answer for.")
        }
    }

    func revoke() {
        guard let id = selected else { return }
        act("Sponsorship revoked.") { c in _ = try await c.revokeSponsorship(id) }
    }

    // MARK: Engine

    func connect() {
        status("Connecting to \(relayURL)…")
        Task { [self] in
            do {
                let fresh = !EldrClient.exists(in: store)
                if fresh { try EldrClient.initialize(store: store, relays: [relayURL]) }
                let c = try await EldrClient(store: store, transport: defaultTransportFactory(url: relayURL))
                if let autoAccept { await c.setAutoAccept(nostrPubkeyHex: autoAccept, identityHex: autoAcceptIdentity) }
                if fresh { try await c.announce() }
                let events = try await c.start()
                onMain { [self] in self.client = c; self.status("Connected."); self.refresh() }
                for await ev in events {
                    let note: String?
                    switch ev {
                    case .sponsorship(let n): note = "🛡 " + n
                    case .request(let n, let auto): note = auto ? nil : "✉ New message request from \(Bech32.npub(n).prefix(20))…"
                    case .bindingIdentityChanged(let rec, _):
                        note = "⚠ SAFETY: \(rec.name ?? "a contact")'s npub now binds a different identity. Kept the old one; verify out-of-band."
                    case .saveFailed(let e): note = "⚠ Save failed: \(e)"
                    case .protocolViolation(_, let r): note = "⚠ Protocol violation: \(r)"
                    case .relayReconnected: note = "Relay reconnected."
                    case .reconnectRequest(let rec, let auto):
                        note = auto ? "🔄 \(rec.name ?? "A contact") reset; reconnected."
                            : "🔄 \(rec.name ?? "A contact") reset their app and wants to reconnect. Check their safety code, then use Reconnect in their conversation."
                    case .groupChanged(let g):
                        note = "👥 Group “\(UIFormat.sanitizeLine(g.name))” roster updated (\(g.members.count) members)."
                    case .aiWindow, .aiInvite, .threadCreated: note = nil
                    case .myAI(_, _, let err): note = err.map { "⚠ My AI failed: " + $0 }
                    case .message, .quarantined: note = nil
                    }
                    onMain { [self] in if let note { self.status(note) }; self.refresh() }
                }
            } catch {
                onMain { [self] in self.status("⚠ Could not open: \(error)") }
            }
        }
    }

    func shutdown() {
        guard let c = client else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await c.stop(); sem.signal() }
        _ = sem.wait(timeout: .now() + 4)
    }
}

final class ScrollTarget {
    let adj: UnsafeMutablePointer<GtkAdjustment>?
    let toEnd: Bool
    let value: Double
    init(adj: UnsafeMutablePointer<GtkAdjustment>?, toEnd: Bool, value: Double) { self.adj = adj; self.toEnd = toEnd; self.value = value }
}

let ui = AppUI()
let app = gtk_application_new("app.eldr.EldrGtk", G_APPLICATION_NON_UNIQUE)!
on(app, "activate") {
    ui.build(app)
    ui.connect()
}
on(app, "shutdown") { ui.shutdown() }
// SIGINT/SIGTERM quit through GTK so `shutdown` saves state and releases the lock.
for sig in [SIGINT, SIGTERM] {
    g_unix_signal_add_full(G_PRIORITY_DEFAULT, sig, { d in
        g_application_quit(cast(d)); return 0
    }, UnsafeMutableRawPointer(app), nil)
}
let rc = g_application_run(cast(app), 0, nil)
g_object_unref(app)
exit(rc)
