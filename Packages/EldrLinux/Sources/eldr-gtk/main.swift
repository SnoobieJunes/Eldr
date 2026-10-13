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
        gtk_widget_set_visible(sponsorBar, s.isAgent ? 0 : 1)
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
            let who = m.outgoing ? "You" : peerName
            var meta = "\(who) · \(UIFormat.date(m.sentAt))"
            let badge = m.agent ? UIFormat.badge(m.sponsorship, names: s.name(of:)) : ""
            if !badge.isEmpty { meta += " · " + badge }
            let ml = label(meta, wrap: true); addClass(ml, "meta")
            if case .invalid = m.sponsorship { addClass(ml, "warn") }
            if m.agent, case .unsponsored = m.sponsorship { addClass(ml, "warn") }
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
                let r = try await client.send(text, to: id)
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
