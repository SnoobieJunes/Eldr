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

    USAGE: eldr-gtk [--state DIR] [--relay URL] [--auto-accept NPUB] [--auto-accept-identity HEX] [--open world|ais|relays|tour]

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
/// `--open world|ais|relays|tour`: open that window once connected (screenshots, demos).
let openWindow = opt("--open")

func die(_ s: String) -> Never { FileHandle.standardError.write(Data("eldr-gtk: \(s)\n".utf8)); exit(1) }

try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let store: FileIdentityStore
let keystorePosture: KeystorePosture
do { (store, keystorePosture) = try makeClientKeystore(directory: stateDir, environment: env) } catch { die("\(error)") }
if !keystorePosture.isHardwareBacked { FileHandle.standardError.write(Data("eldr-gtk: \(keystorePosture.report)\n".utf8)) }

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
    var mentionHint: Widget!

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
            .unread { font-weight: bold; }
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
        append(toolRow, button("Buzz") { [unowned self] in self.showBuzz() })
        append(toolRow, button("World") { [unowned self] in self.showWorld() })
        append(toolRow, button("Tour") { [unowned self] in self.showTour(0) })
        append(side, toolRow)
        let toolRow2 = hbox(4)
        append(toolRow2, button("My AIs") { [unowned self] in self.showAIHub() })
        append(toolRow2, button("Solo AI chat") { [unowned self] in
            self.act(nil) { c in
                let g = try await c.createSoloAIChat(name: "My AI")
                onMain { [self] in self.selected = UISnapshot.groupPrefix + g.groupID; self.status("Solo AI chat ready: only you and your AIs. Nothing leaves this device except to your AI providers.") }
            }
        })
        append(toolRow2, button("Relays") { [unowned self] in self.showRelays() })
        append(side, toolRow2)
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
            if (self.snap?.unread[self.convIDs[i]] ?? 0) > 0 {
                let conv = self.convIDs[i]
                self.act(nil) { c in try await c.markRead(conv) }
            }
        }
        let cs = scrolled(convList); expand(cs, v: true); append(side, cs)
        reqTitle = label("Requests"); addClass(reqTitle, "meta"); append(side, reqTitle)
        reqList = gtk_list_box_new(); gtk_list_box_set_selection_mode(cast(reqList), GTK_SELECTION_NONE)
        append(side, reqList)
        // Visible, always-on protection indicator (AC218).
        let shield = label((keystorePosture.isHardwareBacked ? "🔒 Keys: " : "⚠️ Keys: ") + keystorePosture.shortLabel, wrap: true)
        gtk_widget_set_tooltip_text(shield, keystorePosture.report)
        if !keystorePosture.isHardwareBacked { addClass(shield, "error") }
        append(side, shield)
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
        append(sponsorBar, button("Contact…") { [unowned self] in self.showContact() })
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
        append(aiBar, button("AIs here…") { [unowned self] in self.showAIsHere() })
        append(aiBar, button("What my AI sees") { [unowned self] in self.showAISees() })
        append(aiBar, button("Send as my AI") { [unowned self] in self.sendAsAI() })
        append(aiBar, button("Add last to AI context") { [unowned self] in
            guard let id = self.selected else { return }
            let tid = UISnapshot.threadID(id), conv = self.conversationForAI(id)
            self.act("Your last message here is now in your AI's context (they were told).") { c in
                _ = try await c.markAIContext(in: conv, thread: tid, message: "last", true)
            }
        })
        append(aiBar, button("Share context 1h") { [unowned self] in self.shareContext(axis: "human", seconds: 3600) })
        append(aiBar, button("Share AI replies 1h") { [unowned self] in self.shareContext(axis: "ai", seconds: 3600) })
        append(aiBar, button("Stop sharing") { [unowned self] in
            self.shareContext(axis: "human", seconds: nil); self.shareContext(axis: "ai", seconds: nil)
        })
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
        mentionHint = label("", wrap: true); addClass(mentionHint, "meta"); append(main, mentionHint)
        let hint = label("Enter = new line · Ctrl+Enter = send · @name mentions · paste Markdown of any size"); addClass(hint, "meta")
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
            let tl = label((c.isAgent ? "🤖 " : "") + c.displayTitle)
            if c.unread > 0 { addClass(tl, "unread") }
            append(row, tl)
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
        gtk_widget_set_visible(reqTitle, s.requests.isEmpty && s.groupInvites.isEmpty ? 0 : 1)
        for g in s.groupInvites {
            let row = hbox(4); margins(row, 4)
            let l = label("👥 \(UIFormat.sanitizeLine(g.name)) (\(g.members.count))"); expand(l, h: true)
            append(row, l)
            let id = g.groupID
            append(row, button("Join") { [unowned self] in self.act("Joined.") { try await $0.acceptGroupInvite(id) } })
            append(row, button("Decline") { [unowned self] in self.act("Declined.") { try await $0.declineGroupInvite(id) } })
            gtk_list_box_append(cast(reqList), row)
        }
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
        setLabel(mentionHint, s.ais.isEmpty && s.contacts.isEmpty ? "" : "Mention: " + (s.ais.map { "@" + $0 } + (isGroup ? (s.groups.first { UISnapshot.groupPrefix + $0.groupID == id }?.members ?? []).compactMap { s.name(of: $0) }.filter { $0 != "you" }.map { "@" + ($0.split(separator: " ").first.map(String.init) ?? $0) } : [])).joined(separator: " ")
            + (s.solo.contains(id) ? "  ·  Solo AI chat: your AIs answer every message" : "")
            + (s.contextModes[conversationForAI(id)].map { "  ·  AI context: \($0)" } ?? ""))
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
            if m.failed == true {
                let mid = m.id
                append(col, button("Not sent — retry") { [unowned self] in self.act("Re-sent.") { c in _ = try await c.retry(mid) } })
            }
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

    /// Bilateral AI context sharing (SPEC N24): flows only while the other human shares too.
    func shareContext(axis: String, seconds: Int64?) {
        guard let id = selected else { status("Pick a conversation first."); return }
        let tid = UISnapshot.threadID(id), conv = conversationForAI(id)
        act(seconds == nil ? "Context sharing (\(axis)) stopped." : "Context sharing (\(axis)) on for 1h; it flows only while they share too.") { c in
            _ = try await c.setContextSharing(in: conv, thread: tid, axis: axis, seconds: seconds)
        }
    }

    /// Contact details (iOS ConversationDetailsView): rename, safety code, verify,
    /// block, pin, delete local history.
    func showContact() {
        guard let id = selected, UISnapshot.threadID(id) == nil, UISnapshot.groupID(id) == nil,
            let c = snap?.contacts.first(where: { $0.identityHex == id }) else { return }
        let win = gtk_window_new()!
        gtk_window_set_title(cast(win), "Contact")
        gtk_window_set_transient_for(cast(win), cast(window))
        gtk_window_set_default_size(cast(win), 460, -1)
        let box = vbox(6); margins(box, 12)
        append(box, label("Name"))
        let nameE = gtk_entry_new()!; setEntryText(nameE, c.name ?? ""); append(box, nameE)
        append(box, label("Identity " + c.identityHex, wrap: true, selectable: true))
        append(box, label("Safety code — compare it in person or on a call:"))
        let code = label("…", wrap: true, selectable: true); addClass(code, "title"); append(box, code)
        act(nil) { cl in let s = try await cl.safetyCode(with: id); onMain { setLabel(code, s) } }
        let row1 = hbox(6)
        append(row1, button("Save name") { [unowned self] in
            let n = entryText(nameE)
            self.act("Renamed.") { cl in try await cl.renameContact(id, to: n) }
        })
        append(row1, button(c.verified == true ? "Clear verified" : "Mark verified") { [unowned self] in
            self.act(c.verified == true ? "Verification cleared." : "Marked verified.") { cl in try await cl.setVerified(id, c.verified != true) }
            gtk_window_destroy(cast(win))
        })
        append(row1, button(c.pinned == true ? "Unpin" : "Pin") { [unowned self] in
            self.act(nil) { cl in try await cl.setPinned(id, c.pinned != true) }
            gtk_window_destroy(cast(win))
        })
        append(box, row1)
        let row2 = hbox(6)
        append(row2, button(c.blocked == true ? "Unblock" : "Block") { [unowned self] in
            self.act(c.blocked == true ? "Unblocked." : "Blocked. Their messages are dropped; they are not told.") { cl in
                try await cl.setBlocked(id, c.blocked != true)
            }
            gtk_window_destroy(cast(win))
        })
        append(row2, button("Delete history on this device") { [unowned self] in
            self.act("History deleted on this device. The contact stays.") { cl in try await cl.deleteHistory(with: id) }
            gtk_window_destroy(cast(win))
        })
        append(box, row2)
        gtk_window_set_child(cast(win), box)
        gtk_window_present(cast(win))
    }

    /// Buzz workspaces (iOS BuzzJoinWorkspaceView + BuzzChannelView). Signed, NOT
    /// end-to-end encrypted: the disclosure banner is always on screen.
    func showBuzz() {
        let win = gtk_window_new()!
        gtk_window_set_title(cast(win), "Buzz workspaces")
        gtk_window_set_transient_for(cast(win), cast(window))
        gtk_window_set_default_size(cast(win), 760, 560)
        let box = vbox(6); margins(box, 12)
        let warn = label("⚠ " + EldrClient.buzzDisclosure, wrap: true); addClass(warn, "banner"); append(box, warn)
        let joinRow = hbox(6)
        let linkE = gtk_entry_new()!; gtk_entry_set_placeholder_text(cast(linkE), "Invite link (https://…/invite/… or buzz://join?…)")
        expand(linkE, h: true); append(joinRow, linkE)
        let note = label("", wrap: true); addClass(note, "meta")
        let wsList = gtk_list_box_new()!, chList = gtk_list_box_new()!, msgList = gtk_list_box_new()!
        var current: (ws: String, ch: String)?
        func loadMessages() {
            guard let cur = current else { return }
            act(nil) { c in
                let bc = try await c.buzzClient(cur.ws)
                let ms = try await bc.history(channelID: cur.ch, limit: 100)
                onMain {
                    clearList(msgList)
                    for m in ms { gtk_list_box_append(cast(msgList), label("[\(m.authorPubkey.prefix(8))] " + UIFormat.sanitizeLine(m.content), wrap: true, selectable: true)) }
                }
            }
        }
        func loadWorkspaces() {
            act(nil) { c in
                let ws = await c.buzzWorkspaces
                onMain {
                    clearList(wsList)
                    if ws.isEmpty { gtk_list_box_append(cast(wsList), label("No workspaces yet.")) }
                    for w in ws {
                        let row = hbox(4)
                        append(row, button("\(w.name) · \(w.host)") { [unowned self] in
                            setLabel(note, "Connecting to \(w.host)…")
                            self.act(nil) { c in
                                let chs = try await c.buzzClient(w.id).channels().filter { !$0.isHidden }
                                onMain {
                                    clearList(chList); setLabel(note, "")
                                    for ch in chs {
                                        gtk_list_box_append(cast(chList), button("#" + UIFormat.sanitizeLine(ch.name)) {
                                            current = (w.id, ch.id); loadMessages()
                                        })
                                    }
                                }
                            }
                        })
                        append(row, button("Forget") { [unowned self] in
                            self.act("Forgot \(w.name); its key was destroyed.") { c in try await c.buzzForget(w.id) }
                            loadWorkspaces()
                        })
                        gtk_list_box_append(cast(wsList), row)
                    }
                }
            }
        }
        append(joinRow, button("Join") { [unowned self] in
            let l = entryText(linkE)
            setLabel(note, "Claiming the invite…")
            self.act(nil) { c in
                do { let w = try await c.buzzJoin(link: l); onMain { setLabel(note, "Joined \(w.name) as \(w.role)."); setEntryText(linkE, ""); loadWorkspaces() } }
                catch { onMain { setLabel(note, "⚠ \(error)") } }
            }
        })
        append(box, joinRow); append(box, note)
        let panes = hbox(8)
        let left = vbox(4); append(left, label("Workspaces")); append(left, wsList); append(left, label("Channels"))
        let cs = scrolled(chList); expand(cs, v: true); append(left, cs)
        gtk_widget_set_size_request(left, 240, -1); append(panes, left)
        let right = vbox(4)
        let ms = scrolled(msgList); expand(ms, h: true, v: true); append(right, ms)
        let sendRow = hbox(4)
        let msgE = gtk_entry_new()!; gtk_entry_set_placeholder_text(cast(msgE), "Message (readable by the workspace operator)")
        expand(msgE, h: true); append(sendRow, msgE)
        append(sendRow, button("Send") { [unowned self] in
            guard let cur = current else { setLabel(note, "Pick a channel first."); return }
            let t = entryText(msgE); guard !t.isEmpty else { return }
            self.act(nil) { c in _ = try await c.buzzClient(cur.ws).send(t, to: cur.ch); onMain { setEntryText(msgE, ""); loadMessages() } }
        })
        append(right, sendRow); expand(right, h: true); append(panes, right)
        expand(panes, v: true); append(box, panes)
        gtk_window_set_child(cast(win), box)
        gtk_window_present(cast(win))
        loadWorkspaces()
    }

    func showWorld() {
        act(nil) { c in
            let rows = WorldDerivation.townRows(await c.townGrants(), now: Int64(Date().timeIntervalSince1970))
            let ws = await c.buzzWorkspaces, p = await c.providerConfig
            onMain { [self] in
                let win = gtk_window_new()!
                gtk_window_set_title(cast(win), "World")
                gtk_window_set_transient_for(cast(win), cast(self.window))
                gtk_window_set_default_size(cast(win), 540, 700)
                let box = vbox(6); margins(box, 12)
                let h1 = label("Towns you've authorized"); addClass(h1, "title"); append(box, h1)
                let n1 = label("This is what you granted from this device. Whether a town is connected is visible only on the node running it.", wrap: true)
                addClass(n1, "meta"); append(box, n1)
                if rows.isEmpty { append(box, label("No town access granted yet. Use eldr-chat town-grant issue.")) }
                for r in rows { append(box, label("\(r.title)  ·  \(r.planes)  ·  \(r.status.label)")) }
                let mapRows = rows
                let me = String(self.snap?.me.prefix(8) ?? "me")
                if let map = drawingArea(width: 480, height: 300, { cr, w, h in
                    WorldMapDraw.draw(cr, Double(w), Double(h), rows: mapRows, me: me, now: Int64(Date().timeIntervalSince1970),
                                      time: Date().timeIntervalSince1970)
                }) {
                    append(box, map)
                    if mapRows.contains(where: { if case .expiringSoon = $0.status { return true }; return false }) {
                        // Only an expiring grant animates; nothing else moves on this map.
                        let src = every(seconds: 1) { redraw(map) }
                        on(win, "destroy") { g_source_remove(src) }
                    }
                    let mn = label("Dashed everywhere: this device sees what you authorized, not whether a town is connected.", wrap: true)
                    addClass(mn, "meta"); append(box, mn)
                }
                let h2 = label("Buzz workspaces"); addClass(h2, "title"); append(box, h2)
                let n2 = label("Workspace messages are readable by the workspace's operator. Eldr conversations are not.", wrap: true)
                addClass(n2, "meta"); append(box, n2)
                if ws.isEmpty { append(box, label("No workspaces joined.")) }
                for w in ws { append(box, label("\(UIFormat.sanitizeLine(w.name))  ·  \(w.host)  ·  \(w.role)")) }
                let h3 = label("Your AI"); addClass(h3, "title"); append(box, h3)
                append(box, label(p.map { "\($0.effectiveKind) · \($0.model.isEmpty ? "default model" : $0.model)" } ?? "Not set up (Settings)."))
                gtk_window_set_child(cast(win), scrolled(box))
                gtk_window_present(cast(win))
            }
        }
    }

    /// iOS "Draft with AI ▸ Send as my AI": the composer text goes out as a
    /// co-authored AI message ("made with you & your AI").
    func sendAsAI() {
        guard let id = selected else { return }
        let text = textViewText(composer)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status("Draft something first."); return }
        let tid = UISnapshot.threadID(id), conv = conversationForAI(id)
        act("Sent as your AI (marked “made with you & your AI”).") { c in
            _ = try await c.sendAsMyAI(text, in: conv, thread: tid)
            onMain { [self] in setTextViewText(self.composer, "") }
        }
    }

    func showAISees() {
        guard let id = selected else { status("Pick a conversation first."); return }
        let tid = UISnapshot.threadID(id), conv = conversationForAI(id)
        act(nil) { c in
            let t = try await c.aiContextPreview(in: conv, thread: tid)
            let text = t.isEmpty ? "Your AI is off here, so it sees nothing."
                : t.map { "\($0.senderDisplayName)\($0.participantType == .agent ? " (AI)" : ""): \($0.text)" }.joined(separator: "\n\n")
            onMain { [self] in
                let win = gtk_window_new()!
                gtk_window_set_title(cast(win), "What my AI sees (read-only)")
                gtk_window_set_transient_for(cast(win), cast(self.window))
                gtk_window_set_default_size(cast(win), 560, 480)
                let l = label(UIFormat.sanitizeLine(text).isEmpty ? "" : text, wrap: true, selectable: true)
                let sc = scrolled(l); margins(sc, 10)
                gtk_window_set_child(cast(win), sc)
                gtk_window_present(cast(win))
            }
        }
    }

    /// The onboarding tour (text shared with iOS via OnboardingTourText).
    func showTour(_ i: Int) {
        let steps = OnboardingTourText.steps
        guard steps.indices.contains(i) else { return }
        let win = gtk_window_new()!
        gtk_window_set_title(cast(win), "Welcome to Eldr — \(i + 1) of \(steps.count)")
        gtk_window_set_transient_for(cast(win), cast(window))
        gtk_window_set_default_size(cast(win), 520, -1)
        let box = vbox(8); margins(box, 16)
        let t = label(steps[i].title); addClass(t, "title"); append(box, t)
        append(box, label(steps[i].subtitle, wrap: true))
        append(box, label(steps[i].body, wrap: true))
        if !steps[i].fieldNote.isEmpty { let n = label(steps[i].fieldNote, wrap: true); addClass(n, "meta"); append(box, n) }
        let row = hbox(6)
        if i > 0 { append(row, button("Back") { [unowned self] in gtk_window_destroy(cast(win)); self.showTour(i - 1) }) }
        append(row, button(i + 1 < steps.count ? "Next" : "Set sail") { [unowned self] in
            gtk_window_destroy(cast(win)); if i + 1 < steps.count { self.showTour(i + 1) }
        })
        append(row, button("Skip") { gtk_window_destroy(cast(win)) })
        append(box, row)
        gtk_window_set_child(cast(win), box)
        gtk_window_present(cast(win))
    }

    // MARK: AI hub (iOS AIHubSheet), per-conversation AI settings, relay panel

    func smallWindow(_ title: String, _ w: Int32 = 520) -> (Widget, Widget) {
        let win = gtk_window_new()!
        gtk_window_set_title(cast(win), title)
        gtk_window_set_transient_for(cast(win), cast(window))
        gtk_window_set_default_size(cast(win), w, -1)
        let box = vbox(6); margins(box, 12)
        gtk_window_set_child(cast(win), box)
        return (win, box)
    }

    func showAIHub() {
        let (win, box) = smallWindow("My AIs")
        let t = label("My AIs"); addClass(t, "title"); append(box, t)
        let listBox = vbox(4); append(box, listBox)
        let note = label("", wrap: true); addClass(note, "meta")
        func load() {
            act(nil) { c in
                let ais = await c.myAIs()
                onMain {
                    var child = gtk_widget_get_first_child(listBox)
                    while let ch = child { child = gtk_widget_get_next_sibling(ch); gtk_box_remove(cast(listBox), ch) }
                    if ais.isEmpty { append(listBox, label("No AI yet. Set the primary one in Settings.")) }
                    for a in ais {
                        let row = hbox(6)
                        let l = label("\(a.name) · \(a.kind)\(a.id == EldrClient.primaryAIID ? " · primary (Settings)" : "")\(a.autonomous ? "" : " · draft-only")")
                        expand(l, h: true); append(row, l)
                        if a.id != EldrClient.primaryAIID {
                            append(row, button("Remove") { [unowned self] in
                                self.act("Removed \(a.name) and its key.") { c in try await c.removeAI(a.id) }; load()
                            })
                        }
                        append(listBox, row)
                    }
                }
            }
        }
        append(box, label("Primary AI name"))
        let pn = gtk_entry_new()!; append(box, pn)
        append(box, button("Rename primary") { [unowned self] in let n = entryText(pn); self.act("Renamed.") { c in try await c.renamePrimaryAI(n) }; load() })
        let h = label("Add another AI"); addClass(h, "title"); append(box, h)
        func field(_ ph: String, password: Bool = false) -> Widget {
            let e = password ? gtk_password_entry_new()! : gtk_entry_new()!
            if !password { gtk_entry_set_placeholder_text(cast(e), ph) } else { append(box, label(ph)) }
            append(box, e); return e
        }
        let nameE = field("Name (letters, digits, - or _; used for @mentions)")
        let kindE = field("Kind: custom, claude, openai, gemini, openrouter, groq")
        let baseE = field("Base URL (custom only)")
        let modelE = field("Model (blank = vendor default)")
        let instrE = field("Instructions (optional)")
        let keyE = field("API key (saved encrypted)", password: true)
        let auto = gtk_check_button_new_with_label("Takes autonomous turns (off = draft-only)")!
        gtk_check_button_set_active(cast(auto), 1); append(box, auto)
        append(box, button("Add AI") { [unowned self] in
            let n = entryText(nameE), k = entryText(kindE).isEmpty ? "custom" : entryText(kindE).lowercased()
            let cfg = AIProviderConfig(baseURL: entryText(baseE), model: entryText(modelE), instructions: entryText(instrE).isEmpty ? nil : entryText(instrE), kind: k)
            let key = entryText(keyE), on = gtk_check_button_get_active(cast(auto)) != 0
            self.act(nil) { c in
                do { _ = try await c.addAI(name: n, config: cfg, apiKey: key.isEmpty ? nil : key, autonomous: on); onMain { setLabel(note, "Added \(n)."); setEntryText(keyE, ""); load() } }
                catch { onMain { setLabel(note, "⚠ \(error)") } }
            }
        })
        append(box, note)
        load()
        gtk_window_present(cast(win))
    }

    /// Per-conversation: which AIs reply and in what order, ordered critique, context mode.
    func showAIsHere() {
        guard let id = selected, let s = snap else { status("Pick a conversation first."); return }
        let tid = UISnapshot.threadID(id), conv = conversationForAI(id)
        let (win, box) = smallWindow("AIs in this conversation")
        append(box, label("Reply order (comma-separated names). all = every autonomous AI; none = silence.", wrap: true))
        append(box, label("Your AIs: " + (s.ais.isEmpty ? "(none)" : s.ais.joined(separator: ", ")), wrap: true))
        let rosterE = gtk_entry_new()!; gtk_entry_set_placeholder_text(cast(rosterE), "all"); append(box, rosterE)
        append(box, button("Save order") { [unowned self] in
            let t = entryText(rosterE).trimmingCharacters(in: .whitespaces)
            let names: [String]? = t.isEmpty || t == "all" ? nil : (t == "none" ? [] : t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            self.act("Reply order saved.") { c in try await c.setAIRoster(names, in: conv, thread: tid) }
        })
        if tid == nil {
            let crit = gtk_check_button_new_with_label("AIs reply in order: primary → reviewer/critic → synthesizer")!
            gtk_check_button_set_active(cast(crit), s.critique.contains(conv) ? 1 : 0)
            on(crit, "toggled") { [unowned self] in
                let v = gtk_check_button_get_active(cast(crit)) != 0
                self.act(v ? "Ordered critique on." : "Ordered critique off.") { c in try await c.setOrderedCritique(v, in: conv) }
            }
            append(box, crit)
            append(box, label("What my AIs may read here (now: \(s.contextModes[conv] ?? "default")):"))
            let row = hbox(4)
            for (t, m) in [("Off (silent)", "off"), ("Only marked", "marked"), ("Full", "full"), ("Default", "")] {
                append(row, button(t) { [unowned self] in
                    self.act("AI context here: \(m.isEmpty ? "default" : m).") { c in try await c.setContextMode(m.isEmpty ? nil : m, in: conv) }
                    gtk_window_destroy(cast(win))
                })
            }
            append(box, row)
        }
        gtk_window_present(cast(win))
    }

    func mentionChoice(_ conv: String, _ name: String) {
        let (win, box) = smallWindow("@\(name)")
        append(box, label("@\(name) isn't live in this conversation. A private draft only you see, or turn your AI on here (everyone is told)?", wrap: true))
        let row = hbox(6)
        append(row, button("Private draft") { [unowned self] in
            gtk_window_destroy(cast(win))
            self.act(nil) { c in
                let d = try await c.draftWithMyAI(in: conv, ai: name)
                onMain { [self] in setTextViewText(self.composer, d); self.status("Draft from \(name) ready — edit, then Ctrl+Enter.") }
            }
        })
        append(row, button("Turn on 1h") { [unowned self] in
            gtk_window_destroy(cast(win))
            self.act("Your AI answers here for 1h; everyone here sees it.") { c in _ = try await c.startAIWindow(in: conv, seconds: 3600) }
        })
        append(row, button("Cancel") { gtk_window_destroy(cast(win)) })
        append(box, row)
        gtk_window_present(cast(win))
    }

    func showRelays() {
        let (win, box) = smallWindow("Relays")
        let st = label("…", wrap: true, selectable: true); append(box, st)
        func load(_ check: Bool) {
            act(nil) { c in
                let r = await c.relayStatus(check: check)
                onMain { setLabel(st, "Configured (next launch): " + r.relays.joined(separator: ", ") + "\nLive connection \(relayURL): \(r.status.label)") }
            }
        }
        append(box, button("Check now") { load(true) })
        let n = label("Observational only: delivery never depends on this indicator; unsent messages show “Not sent — retry”.", wrap: true)
        addClass(n, "meta"); append(box, n)
        load(false)
        gtk_window_present(cast(win))
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
        append(box, label("AI endpoint"))
        let kindE = field("Kind: custom (OpenAI-compatible URL), claude, openai, gemini, openrouter, groq", s.provider?.effectiveKind ?? "custom")
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
            let kd = entryText(kindE).trimmingCharacters(in: .whitespaces).lowercased()
            self.act("Settings saved.") { c in
                try await c.updateSettings(st)
                try await c.setRelays(relayList)
                if b.isEmpty && (kd.isEmpty || kd == "custom") { try await c.configureProvider(nil, apiKey: nil) }
                else {
                    try await c.configureProvider(
                        AIProviderConfig(baseURL: b, model: m, instructions: i.isEmpty ? nil : i,
                                         kind: kd.isEmpty || kd == "custom" ? nil : kd),
                        apiKey: k.isEmpty ? nil : k)
                }
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
                if fresh { try await c.announce(); onMain { [self] in self.showTour(0) } }
                let events = try await c.start()
                onMain { [self] in
                    self.client = c; self.status("Connected."); self.refresh()
                    switch openWindow {
                    case "world": self.showWorld()
                    case "ais": self.showAIHub()
                    case "relays": self.showRelays()
                    case "tour": self.showTour(0)
                    default: break
                    }
                }
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
                    case .groupInvite(let g, let from):
                        note = "👥 \(from.name ?? "A contact") invited you to “\(UIFormat.sanitizeLine(g.name))” — see Requests."
                    case .groupChanged(let g):
                        note = "👥 Group “\(UIFormat.sanitizeLine(g.name))” roster updated (\(g.members.count) members)."
                    case .aiWindow, .aiInvite, .threadCreated: note = nil
                    case .aiContextGrant(_, _, _, let axis, let until): note = "🔗 AI context sharing (\(axis)) \(until == nil ? "stopped" : "enabled")"
                    case .myAI(_, _, let err): note = err.map { "⚠ My AI failed: " + $0 }
                    case .aiMentionChoice(let conv, let name):
                        note = "@\(name) isn't live here."
                        onMain { [self] in self.mentionChoice(conv, name) }
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

/// Cairo drawing of the World map (WorldMapLayout geometry, tested in EldrUIModel).
enum WorldMapDraw {
    static func draw(_ cr: OpaquePointer, _ w: Double, _ h: Double, rows: [WorldTownRow], me: String, now: Int64, time: Double) {
        let cx = w / 2, cy = h / 2, r = WorldMapLayout.ringRadius(width: w, height: h)
        cairo_set_line_width(cr, 1.5)
        for (i, row) in rows.enumerated() {
            let u = WorldMapLayout.unitPosition(index: i, count: rows.count)
            let x = cx + u.x * r, y = cy + u.y * r
            var dash: [Double] = [5, 4]
            cairo_set_dash(cr, &dash, 2, 0)
            cairo_set_source_rgba(cr, 0.5, 0.5, 0.5, 0.8)
            cairo_move_to(cr, cx, cy); cairo_line_to(cr, x, y); cairo_stroke(cr)
            cairo_set_dash(cr, nil, 0, 0)
            let frac = WorldMapLayout.lifetimeFraction(expiresAt: WorldMapLayout.until(row.status), now: now)
            let urgent: Bool = { if case .expiringSoon = row.status { return true }; return false }()
            let b = WorldMapLayout.breath(time: time, urgent: urgent)
            cairo_set_source_rgba(cr, urgent ? 0.9 : 0.2, urgent ? 0.5 : 0.6, 0.2, 0.5 + 0.5 * b)
            cairo_arc(cr, x, y, 14, -Double.pi / 2, -Double.pi / 2 + 2 * Double.pi * max(frac, 0.02)); cairo_stroke(cr)
            cairo_set_source_rgba(cr, 0.35, 0.35, 0.35, 1)
            cairo_arc(cr, x, y, 8, 0, 2 * Double.pi); cairo_fill(cr)
            cairo_move_to(cr, x - 30, y + 28); cairo_show_text(cr, "\(row.title) · \(row.status.label)")
        }
        cairo_set_source_rgba(cr, 0.57, 0.25, 0.67, 1)
        cairo_arc(cr, cx, cy, 12, 0, 2 * Double.pi); cairo_fill(cr)
        cairo_move_to(cr, cx - 14, cy + 28); cairo_show_text(cr, me == "me" ? "you" : "you · " + me)
        if rows.isEmpty { cairo_move_to(cr, cx - 70, cy - 30); cairo_show_text(cr, "No towns authorized yet") }
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
