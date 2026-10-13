// SPDX-License-Identifier: Apache-2.0
// eldr-chat — the Linux Eldr command-line client (Milestone 1). Human- and agent-drivable:
// every command accepts --json for machine-readable output, and `listen` has an
// inbox/outbox file mode so an AI agent can chat without a TTY.
import EldrClientCore
import Foundation
import PQRCCore
import PQRCNostr
import PQRCAgent

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

let usage = """
    eldr-chat — Eldr post-quantum messenger, Linux CLI

    USAGE: eldr-chat [--state DIR] [--relay URL] [--json] <command> [args]

      init [--no-announce]          create a new identity and publish its keys
      whoami                        identity hex, npub and pqrc:add pairing link
      announce                      re-publish keys (10420/10421/10050)
      add <link|npub|hex> [--name N] [--expect-identity HEX]
      contacts                      list contacts
      requests                      list pending message requests (non-contacts)
      accept <npub|prefix> [--name N]
      decline <npub|prefix>
      send <contact> <text…>        send one message and exit (text "-" reads stdin)
      chat <contact>                interactive chat (type lines; /quit to exit)
      listen [--inbox FILE.jsonl] [--outbox DIR] [--auto-accept <npub|link>]
             [--auto-accept-identity HEX] [--for SECONDS]
                                    receive (and send outbox files) until stopped
      agent-mode on --owner HEX | off   mark this identity as an AI account that
                                    needs its owner's sponsorship to send
      sponsor <contact> [--days 1|7|30] [--label NAME]
                                    sponsor a contact's AI account (human only)
      revoke <sponsorship-id|contact> [--notify c1,c2]
      reconnect <contact> [--decline]  approve (or refuse) ONE new session from a
                                    contact that reset after its one-time prekeys ran out
      history <contact> [--last N]  recent messages with sponsorship status
      sponsorships                  this account's sponsorship + ones you issued
      group create <name> <contact…> create a group (pairwise fan-out, APP-SPEC §7)
      group add|remove <group> <contact…>   new roster revision to old+new members
      group send <group> <text…>    send to every member you have as a contact
      group history <group> [--last N]
      group rename <group> <name…>  |  group leave <group>
      groups                        list groups (rosters are "asserted by" someone)
      thread create <conv> <title…> start a thread in a contact or group conversation
      thread send <thread> <text…>  |  thread history <thread>  |  threads
      ai-window <conv> 1h|8h|24h|off  my AI answers humans in <conv> for that long
                                    (one conversation at a time; off = signed close)
      ai-invite <thread> 1h|8h|24h|off  invite / withdraw my AI in a thread
      ai-status [<conv>|--thread T]  live windows/invites (every AI shown, SPEC §13)
      ai-config --base-url URL --model M [--key-stdin] [--instructions TEXT]
                [--timeout S] | --show | --clear
                                    OpenAI-compatible endpoint (LM Studio, Ollama,
                                    vLLM, OpenAI, OpenRouter…); the key is read from
                                    stdin into the encrypted keystore, or from
                                    $ELDR_AI_API_KEY at run time — never from argv
      ai-test                       one test completion (nothing is sent to anyone)
      ai-draft <conv> [--thread T]  a private draft from my AI (nothing is sent)
      town-grant issue <contact> --planes wall,delegate --days 1|3|7|14|30
                 [--messages N --bytes N --tasks N]  |  revoke <grant-id>  |  list
      settings [--name N] [--loop-guard N] [--relays URL,URL]   (no flags = show)
      qr                            show my pairing link as a QR code
      <conv> = contact, group name/id, or group:<id>.  listen runs my AI when enabled.

    <contact> = name, identity-hex prefix (≥6), npub, or nostr-hex prefix.
    Outbox: *.json {"to": "<contact>", "text": "..."} (or {"group": "<group>", ...}) files are sent then moved to
    DIR/sent (or DIR/failed). Inbox: one JSON object per received message.

    Keystore: AES-256-GCM files under --state (default $ELDR_CHAT_DIR or
    ~/.local/share/eldr-chat), master key wrapped by scrypt(passphrase) from
    ELDR_CHAT_PASSPHRASE / ELDR_CHAT_PASSPHRASE_FILE / TTY prompt, or a TPM-sealed
    systemd credential (eldr-chat-master).
    """

// MARK: - Args

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
@MainActor func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
nonisolated(unsafe) var signalSources: [any DispatchSourceSignal] = []
let env = ProcessInfo.processInfo.environment
let json = takeFlag("--json")
let relay = takeOption("--relay") ?? env["ELDR_CHAT_RELAY"] ?? "wss://relay.lerants.com"
let stateDir: URL = {
    if let s = takeOption("--state") ?? env["ELDR_CHAT_DIR"] { return URL(fileURLWithPath: s) }
    let base = env["XDG_DATA_HOME"].map { $0 } ?? ((env["HOME"] ?? ".") + "/.local/share")
    return URL(fileURLWithPath: base).appendingPathComponent("eldr-chat")
}()

func emit(_ obj: [String: Any], human: String) {
    if json {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
            let s = String(data: d, encoding: .utf8)
        { out(s) }
    } else {
        out(sanitizeForTerminal(human))
    }
}
/// Human-mode output of UNTRUSTED text (peer messages) must not carry terminal control
/// sequences (ANSI/OSC escapes can rewrite the screen or set the window title).
func sanitizeForTerminal(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map { u -> Unicode.Scalar in
        let v = u.value
        if v == 0x0A || v == 0x09 { return u }
        if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) { return "\u{FFFD}" }
        return u
    }))
}
func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func fail(_ msg: String) -> Never {
    if json { emit(["type": "error", "error": msg], human: "") } else {
        FileHandle.standardError.write(Data("eldr-chat: \(msg)\n".utf8))
    }
    exit(1)
}
func short(_ h: String) -> String { String(h.prefix(12)) + "…" }
func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

func openStore() -> FileIdentityStore {
    do {
        let (store, posture) = try makeClientKeystore(directory: stateDir, environment: env)
        if posture == .passphraseOnDisk && !json {
            FileHandle.standardError.write(Data("eldr-chat: \(posture.report)\n".utf8))
        }
        return store
    } catch { fail("\(error)") }
}
func openClient(_ store: FileIdentityStore) async -> EldrClient {
    guard EldrClient.exists(in: store) else { fail("\(EldrClientError.notInitialized)") }
    do { return try await EldrClient(store: store, transport: defaultTransportFactory(url: relay)) }
    catch { fail("\(error)") }
}

func messageObject(_ c: ContactRecord, _ m: ReceivedMessage) -> [String: Any] {
    var o: [String: Any] = [
        "type": "message", "from": c.name ?? short(c.identityHex), "fromIdentity": c.identityHex,
        "fromNpub": Bech32.npub(c.nostrPubkeyHex), "text": m.body.text, "sentAt": m.body.sentAt,
        "receivedAt": iso(Date()), "participant": "\(m.participantType)", "wrap": m.wrapEventID,
    ]
    if let id = m.body.messageID { o["messageID"] = id }
    if m.body.isContext == true { o["isContext"] = true }
    if let g = m.body.group { o["group"] = "\(g)" }
    if let t = m.body.thread { o["thread"] = "\(t)" }
    if let ch = m.body.chunk { o["chunk"] = "\(ch)" }
    if m.contentPointer != nil { o["hasAttachment"] = true }
    if m.aiWindow != nil { o["aiWindow"] = true }
    return o
}
func eventObject(_ ev: ClientEvent) -> ([String: Any], String) {
    switch ev {
    case .message(let c, let m, let gid):
        var o = messageObject(c, m)
        if let gid { o["groupID"] = gid }
        return (o, "[\(gid.map { "#\($0.prefix(8)) " } ?? "")\(c.name ?? short(c.identityHex))] \(m.body.text)")
    case .groupChanged(let g):
        return (["type": "group", "groupID": g.groupID, "name": g.name, "members": g.members,
                 "assertedBy": g.assertedBy, "revision": g.revision],
            "👥 group \"\(g.name)\" (\(g.groupID.prefix(8))) now \(g.members.count) members, asserted by \(short(g.assertedBy)) rev \(g.revision)")
    case .request(let n, let auto):
        return (["type": "request", "npub": Bech32.npub(n), "autoAccepted": auto],
            auto ? "✓ auto-accepted request from \(Bech32.npub(n))"
                : "✉ message request from \(Bech32.npub(n)) — `eldr-chat accept \(n.prefix(12))`")
    case .quarantined(let w, let r):
        return (["type": "quarantined", "wrap": w, "reason": r], "⚠ quarantined \(w.prefix(8)): \(r)")
    case .protocolViolation(let s, let r):
        return (["type": "violation", "from": s, "reason": r], "⚠ protocol violation from \(short(s)): \(r)")
    case .relayReconnected:
        return (["type": "relay", "status": "reconnected"], "· relay reconnected")
    case .bindingIdentityChanged(let c, let newHex):
        return (["type": "warning", "warning": "identity_changed", "contact": c.name ?? c.identityHex,
                 "storedIdentity": c.identityHex, "relayIdentity": newHex],
            "⚠ SAFETY: \(c.name ?? short(c.identityHex))'s npub now binds a DIFFERENT identity \(short(newHex)). "
                + "Keeping the old one. Verify with them out-of-band before trusting anything new.")
    case .saveFailed(let e):
        return (["type": "error", "error": "save failed: \(e)"], "⚠ SAVE FAILED: \(e)")
    case .reconnectRequest(let c, let auto):
        let who = c.name ?? short(c.identityHex)
        return (["type": "reconnect", "contact": who, "identity": c.identityHex, "autoAccepted": auto],
            auto ? "🔄 \(who) reset; reconnected (you approved it)."
                : "🔄 \(who) reset their app and wants to reconnect. Verify their safety code, then `eldr-chat reconnect \(who)`.")
    case .sponsorship(let note):
        return (["type": "sponsorship", "note": note], "🛡 \(note)")
    case .aiWindow(let who, let conv, let until):
        return (["type": "aiWindow", "identity": who, "conversation": conv, "until": until as Any],
            "🤖 \(short(who))'s AI \(until.map { "is ON here until \(iso(Date(timeIntervalSince1970: TimeInterval($0))))" } ?? "is off")")
    case .aiInvite(let who, let t, let until):
        return (["type": "aiInvite", "identity": who, "thread": t, "until": until as Any],
            "🤖 \(short(who))'s AI \(until.map { "joined thread \(t.prefix(8)) until \(iso(Date(timeIntervalSince1970: TimeInterval($0))))" } ?? "left thread \(t.prefix(8))")")
    case .threadCreated(let t):
        return (["type": "thread", "threadID": t.threadID, "conversation": t.conversationID, "title": t.title],
            "🧵 new thread \"\(t.title)\" (\(t.threadID.prefix(8)))")
    case .myAI(let conv, let t, let err):
        return (["type": "myAI", "conversation": conv, "thread": t as Any, "error": err as Any],
            err.map { "⚠ my AI failed: \($0)" } ?? "🤖 my AI posted\(t.map { " in thread \($0.prefix(8))" } ?? "")")
    }
}

// MARK: - Commands

guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "help", "-h", "--help":
    print(usage)

case "init":
    let noAnnounce = takeFlag("--no-announce")
    let store = openStore()
    do { try EldrClient.initialize(store: store, relays: [relay]) } catch { fail("\(error)") }
    let client = await openClient(store)
    if !noAnnounce {
        do { try await client.announce() } catch { fail("identity created but publishing keys failed: \(error)") }
    }
    let link = await client.pairingLink.uri
    emit(["type": "init", "identity": client.identityHex, "npub": await client.npub, "link": link,
          "announced": !noAnnounce],
         human: "Created identity \(client.identityHex)\nnpub: \(await client.npub)\nlink: \(link)")

case "whoami":
    let client = await openClient(openStore())
    let link = await client.pairingLink.uri
    emit(["type": "whoami", "identity": client.identityHex, "npub": await client.npub,
          "nostr": client.nostrPubkeyHex, "link": link, "relays": await client.state.relays],
         human: "identity: \(client.identityHex)\nnpub:     \(await client.npub)\nlink:     \(link)")

case "announce":
    let client = await openClient(openStore())
    do { try await client.announce() } catch { fail("\(error)") }
    emit(["type": "announced"], human: "Published 10420/10421/10050 to \(relay)")

case "add":
    let name = takeOption("--name")
    let expect = takeOption("--expect-identity")
    guard let target = args.first else { fail("add needs a link, npub or hex") }
    let client = await openClient(openStore())
    do {
        let c = try await client.addContact(target, name: name, expectedIdentityHex: expect)
        emit(["type": "contact", "name": c.name as Any, "identity": c.identityHex,
              "npub": Bech32.npub(c.nostrPubkeyHex)],
             human: "Added \(c.name ?? "contact") identity \(c.identityHex)")
    } catch { fail("\(error)") }

case "contacts":
    let client = await openClient(openStore())
    let cs = await client.contacts
    if json {
        emit(["type": "contacts", "contacts": cs.map {
            ["name": $0.name as Any, "identity": $0.identityHex, "npub": Bech32.npub($0.nostrPubkeyHex),
             "session": $0.session != nil]
        }], human: "")
    } else {
        if cs.isEmpty { print("(no contacts)") }
        for c in cs {
            print("\(c.name ?? "-")\t\(c.identityHex)\t\(Bech32.npub(c.nostrPubkeyHex))\t\(c.session != nil ? "session" : "no session")")
        }
    }

case "requests":
    let client = await openClient(openStore())
    let rs = await client.requests
    if json {
        emit(["type": "requests", "requests": rs.map {
            ["npub": Bech32.npub($0.nostrPubkeyHex), "nostr": $0.nostrPubkeyHex,
             "firstSeen": iso($0.firstSeen), "count": $0.count]
        }], human: "")
    } else {
        if rs.isEmpty { print("(no pending requests — requests are seen while `listen`/`chat` runs)") }
        for r in rs { print("\(Bech32.npub(r.nostrPubkeyHex))\tfirst \(iso(r.firstSeen))\t×\(r.count)") }
    }

case "accept", "decline":
    let name = takeOption("--name")
    guard let target = args.first else { fail("\(command) needs an npub or prefix") }
    let client = await openClient(openStore())
    do {
        if command == "accept" {
            let c = try await client.accept(target, name: name)
            emit(["type": "accepted", "identity": c.identityHex],
                 human: "Accepted \(c.identityHex). Held messages arrive on the next listen/chat.")
        } else {
            try await client.decline(target)
            emit(["type": "declined"], human: "Declined.")
        }
    } catch { fail("\(error)") }

case "send":
    guard args.count >= 2 else { fail("send <contact> <text…>") }
    let to = args[0]
    var text = args.dropFirst().joined(separator: " ")
    if text == "-" { text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" }
    guard !text.isEmpty else { fail("empty message") }
    let client = await openClient(openStore())
    do {
        let route = try await client.send(text, to: to)
        emit(["type": "sent", "to": to, "route": "\(route)", "chars": text.count], human: "Sent (\(route)).")
    } catch { fail("\(error)") }

case "chat":
    guard let to = args.first else { fail("chat <contact>") }
    let client = await openClient(openStore())
    let peer: ContactRecord
    do { peer = try await client.contact(matching: to) } catch { fail("\(error)") }
    let events: AsyncStream<ClientEvent>
    do { events = try await client.start() } catch { fail("\(error)") }
    if !json { print("Chatting with \(peer.name ?? short(peer.identityHex)). /quit to exit.") }
    Task {
        for await ev in events {
            if case .message(let c, _, let gid) = ev, c.identityHex != peer.identityHex || gid != nil { continue }
            let (o, h) = eventObject(ev)
            emit(o, human: h)
        }
    }
    let lines = AsyncStream<String> { cont in
        Thread.detachNewThread {
            while let l = readLine() { cont.yield(l) }
            cont.finish()
        }
    }
    for await line in lines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if t == "/quit" { break }
        do { try await client.send(line, to: peer.identityHex) }
        catch { emit(["type": "error", "error": "\(error)"], human: "⚠ send failed: \(error)") }
    }
    await client.stop()

case "listen":
    let inbox = takeOption("--inbox").map { URL(fileURLWithPath: $0) }
    let outbox = takeOption("--outbox").map { URL(fileURLWithPath: $0) }
    let autoAccept = takeOption("--auto-accept")
    let autoIdentity = takeOption("--auto-accept-identity")
    let forSeconds = takeOption("--for").flatMap(Double.init)
    let client = await openClient(openStore())
    if let a = autoAccept {
        guard let link = PairingLink.parse(a) else { fail("bad --auto-accept value") }
        await client.setAutoAccept(nostrPubkeyHex: link.nostrPubkeyHex, identityHex: autoIdentity)
    }
    let events: AsyncStream<ClientEvent>
    do { events = try await client.start() } catch { fail("\(error)") }
    emit(["type": "listening", "identity": client.identityHex, "relay": relay],
         human: "Listening as \(short(client.identityHex)) on \(relay)…")
    if let outbox {
        let sent = outbox.appendingPathComponent("sent"), failed = outbox.appendingPathComponent("failed")
        for d in [outbox, sent, failed] {
            try? FileManager.default.createDirectory(
                at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        }
        Task {
            while true {
                let files = ((try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for f in files {
                    let stamp = "\(Int(Date().timeIntervalSince1970))-\(f.lastPathComponent)"
                    guard let d = try? Data(contentsOf: f),
                        let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                        let to = (o["to"] as? String) ?? (o["group"] as? String).map { "group:" + $0 },
                        let text = o["text"] as? String, !text.isEmpty
                    else {
                        try? FileManager.default.moveItem(at: f, to: failed.appendingPathComponent(stamp))
                        emit(["type": "error", "error": "bad outbox file \(f.lastPathComponent)"], human: "⚠ bad outbox file \(f.lastPathComponent)")
                        continue
                    }
                    do {
                        let r: String
                        if to.hasPrefix("group:") {
                            let n = try await client.sendToGroup(text, group: String(to.dropFirst(6)))
                            r = "group(\(n.reached) reached, \(n.skipped) skipped)"
                        } else { r = "\(try await client.send(text, to: to))" }
                        try? FileManager.default.moveItem(at: f, to: sent.appendingPathComponent(stamp))
                        emit(["type": "sent", "to": to, "route": "\(r)", "file": f.lastPathComponent], human: "→ sent \(f.lastPathComponent) to \(to)")
                    } catch {
                        try? FileManager.default.moveItem(at: f, to: failed.appendingPathComponent(stamp))
                        emit(["type": "error", "error": "send \(f.lastPathComponent): \(error)"], human: "⚠ send failed \(f.lastPathComponent): \(error)")
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    if let forSeconds {
        Task { try? await Task.sleep(for: .seconds(forSeconds)); await client.stop(); exit(0) }
    }
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { Task { try? await client.persist(); exit(0) } }
        src.resume()
        signalSources.append(src)
    }
    for await ev in events {
        let (o, h) = eventObject(ev)
        emit(o, human: h)
        if let inbox, case .message = ev,
            var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
        {
            d.append(0x0A)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inbox.path)
            if let fh = try? FileHandle(forWritingTo: inbox) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
            else { FileManager.default.createFile(atPath: inbox.path, contents: d, attributes: [.posixPermissions: 0o600]) }
        }
    }

case "agent-mode":
    let owner = takeOption("--owner")
    guard let mode = args.first, mode == "on" || mode == "off" else { fail("agent-mode on --owner HEX | off") }
    let client = await openClient(openStore())
    do {
        try await client.setAgentMode(mode == "on", ownerIdentityHex: owner)
        emit(["type": "agentMode", "on": mode == "on", "owner": owner as Any],
             human: mode == "on" ? "Agent mode ON. Owner \(short(owner ?? "")). Sends need a live sponsorship." : "Agent mode OFF.")
    } catch { fail("\(error)") }

case "sponsor":
    let days = takeOption("--days").flatMap(Int.init) ?? 7
    let label = takeOption("--label")
    guard let target = args.first else { fail("sponsor <contact> [--days N] [--label NAME]") }
    let client = await openClient(openStore())
    do {
        let sp = try await client.sponsor(target, days: days, label: label)
        emit(["type": "sponsored", "id": sp.sponsorshipID, "agent": sp.agent, "activeUntil": sp.activeUntil],
             human: "Sponsored \(short(sp.agent)) until \(iso(Date(timeIntervalSince1970: TimeInterval(sp.activeUntil)))) (id \(sp.sponsorshipID.prefix(8)))")
    } catch { fail("\(error)") }

case "revoke":
    let notify = takeOption("--notify")?.split(separator: ",").map(String.init) ?? []
    guard let target = args.first else { fail("revoke <sponsorship-id|contact>") }
    let client = await openClient(openStore())
    do {
        let ids = try await client.revokeSponsorship(target, alsoNotify: notify)
        emit(["type": "revoked", "ids": ids], human: "Revoked \(ids.map { String($0.prefix(8)) }.joined(separator: ", ")).")
    } catch { fail("\(error)") }

case "history":
    let limit = takeOption("--last").flatMap(Int.init) ?? 20
    guard let target = args.first else { fail("history <contact> [--last N]") }
    let client = await openClient(openStore())
    let c: ContactRecord
    do { c = try await client.contact(matching: target) } catch { fail("\(error)") }
    let entries = await client.history(with: c.identityHex).suffix(limit)
    func status(_ s: SponsorshipStatus) -> String {
        switch s {
        case .human: return "human"
        case .unsponsored: return "agent-unsponsored"
        case .sponsored(let by, _, let until): return "agent-sponsored-by-\(by.prefix(12))-until-\(until)"
        case .invalid(let r): return "agent-invalid(\(r))"
        }
    }
    func label(_ e: HistoryEntry) -> String {
        if e.mine == true { return "my-ai" }
        if let u = e.aiAuthorizedUntil { return "their-ai-window-until-\(u)" }
        return status(e.sponsorship)
    }
    for e in entries {
        emit(["type": "history", "outgoing": e.outgoing, "sentAt": e.sentAt, "chars": e.text.count,
              "sponsorship": label(e), "text": e.text.count > 200 ? String(e.text.prefix(200)) + "…" : e.text],
             human: "\(e.outgoing ? "→" : "←") [\(label(e))] \(e.text.count > 120 ? String(e.text.prefix(120)) + "… (\(e.text.count) chars)" : e.text)")
    }

case "reconnect":
    let decline = takeFlag("--decline")
    guard let target = args.first else { fail("reconnect <contact> [--decline]") }
    let client = await openClient(openStore())
    do {
        if decline {
            try await client.declineReconnect(target)
            emit(["type": "reconnect", "declined": true], human: "Reconnect refused; the old session stays.")
        } else {
            let now = try await client.approveReconnect(target)
            emit(["type": "reconnect", "applied": now],
                 human: now ? "Reconnected." : "Approved. Their pending request is applied on the next `listen`/`chat`.")
        }
    } catch { fail("\(error)") }

case "sponsorships":
    let client = await openClient(openStore())
    let mine = await client.mySponsorship
    let issued = await client.issuedSponsorships
    let live = (try? await client.liveSponsorship()) != nil
    if json {
        emit(["type": "sponsorships", "agentMode": await client.isAgent, "owner": await client.ownerIdentityHex as Any,
              "mine": mine.map { ["id": $0.sponsorshipID, "sponsor": $0.enabledBy.hexString, "activeUntil": $0.activeUntil, "live": live] } as Any,
              "issued": issued.map { ["id": $0.sponsorship.sponsorshipID, "agent": $0.sponsorship.agent,
                                      "activeUntil": $0.sponsorship.activeUntil, "revokedAt": $0.revokedAt as Any] }], human: "")
    } else {
        print("agent mode: \(await client.isAgent ? "on (owner \(short(await client.ownerIdentityHex ?? "")))" : "off")")
        if let m = mine { print("my sponsorship: \(m.sponsorshipID.prefix(8)) by \(short(m.enabledBy.hexString)) until \(iso(Date(timeIntervalSince1970: TimeInterval(m.activeUntil)))) \(live ? "LIVE" : "NOT LIVE")") }
        for i in issued {
            print("issued \(i.sponsorship.sponsorshipID.prefix(8)) → \(short(i.sponsorship.agent)) until \(iso(Date(timeIntervalSince1970: TimeInterval(i.sponsorship.activeUntil))))\(i.revokedAt != nil ? " REVOKED" : "")")
        }
    }

case "groups":
    let client = await openClient(openStore())
    let gs = await client.groups
    if json {
        emit(["type": "groups", "groups": gs.map { ["groupID": $0.groupID, "name": $0.name, "members": $0.members,
                                                     "assertedBy": $0.assertedBy, "revision": $0.revision] }], human: "")
    } else {
        if gs.isEmpty { print("(no groups)") }
        for g in gs { print(sanitizeForTerminal("\(g.groupID.prefix(8))\t\(g.name)\t\(g.members.count) members\tasserted by \(short(g.assertedBy)) rev \(g.revision)")) }
    }

case "group":
    guard let sub = args.first else { fail("group create|add|remove|send|history …") }
    args.removeFirst()
    let limit = takeOption("--last").flatMap(Int.init) ?? 20
    let client = await openClient(openStore())
    do {
        switch sub {
        case "create":
            guard args.count >= 2 else { fail("group create <name> <contact…>") }
            let (g, n) = try await client.createGroup(name: args[0], members: Array(args.dropFirst()))
            emit(["type": "group", "groupID": g.groupID, "name": g.name, "members": g.members, "reached": n],
                 human: "Created group \"\(g.name)\" \(g.groupID) (\(g.members.count) members, announced to \(n)).")
        case "rename":
            guard args.count >= 2 else { fail("group rename <group> <name…>") }
            let g = try await client.reviseGroup(args[0], rename: args.dropFirst().joined(separator: " "))
            emit(["type": "group", "groupID": g.groupID, "name": g.name, "revision": g.revision], human: "Renamed to \"\(g.name)\".")
        case "leave":
            guard let q = args.first else { fail("group leave <group>") }
            try await client.leaveGroup(q)
            emit(["type": "left"], human: "Left the group (history kept).")
        case "add", "remove":
            guard args.count >= 2 else { fail("group \(sub) <group> <contact…>") }
            let g = try await client.reviseGroup(args[0], add: sub == "add" ? Array(args.dropFirst()) : [],
                                                 remove: sub == "remove" ? Array(args.dropFirst()) : [])
            emit(["type": "group", "groupID": g.groupID, "members": g.members, "revision": g.revision],
                 human: "Group \"\(g.name)\" is now \(g.members.count) members (rev \(g.revision)).")
        case "send":
            guard args.count >= 2 else { fail("group send <group> <text…>") }
            var text = args.dropFirst().joined(separator: " ")
            if text == "-" { text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" }
            guard !text.isEmpty else { fail("empty message") }
            let n = try await client.sendToGroup(text, group: args[0])
            emit(["type": "sent", "group": args[0], "reached": n.reached, "skipped": n.skipped],
                 human: "Sent to \(n.reached) member(s)\(n.skipped > 0 ? "; \(n.skipped) member(s) aren't your contacts and were skipped" : "").")
        case "history":
            guard let q = args.first else { fail("group history <group>") }
            let g = try await client.group(matching: q)
            let names = Dictionary(await client.contacts.map { ($0.identityHex, $0.name ?? short($0.identityHex)) }, uniquingKeysWith: { a, _ in a })
            for e in await client.groupHistory(g.groupID).suffix(limit) {
                let who = e.outgoing ? "me" : (names[e.peerIdentityHex] ?? short(e.peerIdentityHex))
                emit(["type": "history", "groupID": g.groupID, "from": who, "outgoing": e.outgoing, "sentAt": e.sentAt, "text": e.text],
                     human: "\(who): \(e.text.count > 120 ? String(e.text.prefix(120)) + "…" : e.text)")
            }
        default: fail("group create|add|remove|send|history …")
        }
    } catch { fail("\(error)") }

case "threads":
    let client = await openClient(openStore())
    for t in await client.threads {
        emit(["type": "thread", "threadID": t.threadID, "conversation": t.conversationID, "title": t.title],
             human: sanitizeForTerminal("\(t.threadID.prefix(8))\t\(t.title)\tin \(t.conversationID.prefix(20))"))
    }

case "thread":
    guard let sub = args.first else { fail("thread create|send|history …") }
    args.removeFirst()
    let limit = takeOption("--last").flatMap(Int.init) ?? 20
    let client = await openClient(openStore())
    do {
        switch sub {
        case "create":
            guard args.count >= 2 else { fail("thread create <conv> <title…>") }
            let t = try await client.createThread(in: args[0], title: args.dropFirst().joined(separator: " "))
            emit(["type": "thread", "threadID": t.threadID, "title": t.title], human: "Started thread \"\(t.title)\" \(t.threadID)")
        case "send":
            guard args.count >= 2 else { fail("thread send <thread> <text…>") }
            var text = args.dropFirst().joined(separator: " ")
            if text == "-" { text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" }
            let r = try await client.say(text, in: "", thread: args[0])
            emit(["type": "sent", "reached": r.reached, "skipped": r.skipped], human: "Sent to \(r.reached).")
        case "history":
            guard let q = args.first else { fail("thread history <thread>") }
            let t = try await client.thread(matching: q)
            let names = Dictionary(await client.contacts.map { ($0.identityHex, $0.name ?? short($0.identityHex)) }, uniquingKeysWith: { a, _ in a })
            for e in await client.threadHistory(t.threadID).suffix(limit) {
                let who = e.outgoing ? (e.mine == true ? "my AI" : "me") : ((names[e.peerIdentityHex] ?? short(e.peerIdentityHex)) + (e.agent ? "'s AI" : ""))
                emit(["type": "history", "from": who, "agent": e.agent, "text": e.text], human: "\(who): \(e.text)")
            }
        default: fail("thread create|send|history …")
        }
    } catch { fail("\(error)") }

case "ai-window", "ai-invite":
    guard args.count >= 2 else { fail("\(command) <\(command == "ai-window" ? "conv" : "thread")> 1h|8h|24h|off") }
    let client = await openClient(openStore())
    let dur: [String: Int64] = ["1h": 3600, "8h": 8 * 3600, "24h": 24 * 3600]
    do {
        if args[1] == "off" {
            if command == "ai-window" { try await client.endAIWindow() } else { try await client.withdrawMyAI(thread: args[0]) }
            emit(["type": command, "on": false], human: "My AI is off there (peers were told).")
        } else {
            guard let secs = dur[args[1]] else { fail("duration must be 1h, 8h or 24h") }
            let until = command == "ai-window"
                ? try await client.startAIWindow(in: args[0], seconds: secs)
                : try await client.inviteMyAI(thread: args[0], seconds: secs)
            await client.settleAI()
            emit(["type": command, "on": true, "until": until],
                 human: "My AI is ON until \(iso(Date(timeIntervalSince1970: TimeInterval(until)))). Everyone there sees it. Keep `eldr-chat listen` running so it can reply.")
        }
    } catch { fail("\(error)") }

case "ai-status":
    let thread = takeOption("--thread")
    let client = await openClient(openStore())
    do {
        let map: [String: Int64]
        if let thread { map = await client.activeInvites(thread: try await client.thread(matching: thread).threadID) }
        else if let q = args.first { map = await client.activeWindows(in: try await client.resolveConversation(q)) }
        else { map = [:] }
        if let w = await client.myWindowConversation { print("my AI window: \(w.prefix(24))") }
        if let thread, await client.loopGuardActive(thread: try await client.thread(matching: thread).threadID) {
            print("⏸ loop guard: AIs in this thread are paused until a human posts")
        }
        for (who, until) in map.sorted(by: { $0.key < $1.key }) {
            emit(["identity": who, "until": until], human: "🤖 \(who == client.identityHex ? "my AI" : short(who) + "'s AI") until \(iso(Date(timeIntervalSince1970: TimeInterval(until))))")
        }
    } catch { fail("\(error)") }

case "ai-config":
    let client = await openClient(openStore())
    do {
        if takeFlag("--clear") {
            try await client.configureProvider(nil, apiKey: nil)
            emit(["type": "ai-config", "cleared": true], human: "AI provider and key removed.")
        } else if takeFlag("--show") || args.isEmpty {
            let c = await client.providerConfig
            emit(["type": "ai-config", "baseURL": c?.baseURL as Any, "model": c?.model as Any,
                  "keyStored": await client.hasStoredAPIKey, "keyFromEnv": env["ELDR_AI_API_KEY"] != nil],
                 human: c.map { "endpoint \($0.baseURL) model \($0.model)\(env["ELDR_AI_API_KEY"] != nil ? " · key from $ELDR_AI_API_KEY" : "")" } ?? "(no AI provider configured)")
            if let c, !json { print("key stored in keystore: \(await client.hasStoredAPIKey ? "yes" : "no")\(c.instructions.map { "\ninstructions: \($0)" } ?? "")") }
        } else {
            let keyStdin = takeFlag("--key-stdin")
            guard let base = takeOption("--base-url") else { fail("ai-config needs --base-url") }
            let model = takeOption("--model") ?? ""
            let instr = takeOption("--instructions")
            let timeout = takeOption("--timeout").flatMap(Double.init)
            var key: String?
            if keyStdin {
                key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try await client.configureProvider(
                AIProviderConfig(baseURL: base, model: model, instructions: instr, timeoutSeconds: timeout), apiKey: key)
            emit(["type": "ai-config", "baseURL": base, "model": model, "keyStored": key != nil],
                 human: "AI provider set: \(base)\(key != nil ? " (key saved encrypted)" : "")")
        }
    } catch { fail("\(error)") }

case "ai-test":
    let client = await openClient(openStore())
    do { let r = try await client.testProvider(); emit(["type": "ai-test", "reply": r], human: "AI says: \(r)") }
    catch { fail("\(error)") }

case "ai-draft":
    let thread = takeOption("--thread")
    let client = await openClient(openStore())
    do {
        let d = try await client.draftWithMyAI(in: args.first ?? "", thread: thread)
        emit(["type": "draft", "text": d], human: "Draft (not sent):\n\(d)")
    } catch { fail("\(error)") }

case "town-grant":
    guard let sub = args.first else { fail("town-grant issue|revoke|list") }
    args.removeFirst()
    let planes = (takeOption("--planes") ?? "wall").split(separator: ",").compactMap { StandingGrant.Plane(rawValue: String($0)) }
    let days = takeOption("--days").flatMap(Int.init) ?? 7
    let msgs = takeOption("--messages").flatMap(Int.init) ?? 200
    let bytes = takeOption("--bytes").flatMap(Int.init) ?? 2_000_000
    let tasks = takeOption("--tasks").flatMap(Int.init) ?? 2
    let client = await openClient(openStore())
    do {
        switch sub {
        case "issue":
            guard let to = args.first, !planes.isEmpty else { fail("town-grant issue <contact> --planes wall,delegate --days N") }
            let (g, exportJSON) = try await client.issueTownGrant(to: to, planes: planes, days: days, messagesPerDay: msgs, bytesPerDay: bytes, maxConcurrentTasks: tasks)
            if json { emit(["type": "town-grant", "grantID": g.grantID, "export": exportJSON], human: "") }
            else { print("Issued \(g.grantID). Paste this into the peer node's town-grants.json:\n\(exportJSON)") }
        case "revoke":
            guard let id = args.first else { fail("town-grant revoke <grant-id>") }
            _ = try await client.revokeTownGrant(id)
            emit(["type": "town-grant", "revoked": id], human: "Revoked \(id). Also remove it from any town-grants.json you pasted it into (AC143).")
        case "list":
            for s in await client.townGrants() {
                emit(["grantID": s.grantID, "peer": s.peerIdentityHex, "plane": s.plane.rawValue, "until": s.activeUntil, "mine": s.granterIdentityHex == client.identityHex],
                     human: "\(s.grantID)\t\(s.plane.rawValue)\t\(s.granterIdentityHex == client.identityHex ? "→ " + short(s.peerIdentityHex) : "← " + short(s.granterIdentityHex))\tuntil \(iso(Date(timeIntervalSince1970: TimeInterval(s.activeUntil))))")
            }
        default: fail("town-grant issue|revoke|list")
        }
    } catch { fail("\(error)") }

case "settings":
    let name = takeOption("--name")
    let lg = takeOption("--loop-guard").flatMap(Int.init)
    let relays = takeOption("--relays")
    let client = await openClient(openStore())
    do {
        var s = await client.settings
        if let name { s.displayName = name }
        if let lg { s.loopGuardLimit = lg }
        if name != nil || lg != nil { try await client.updateSettings(s) }
        if let relays { try await client.setRelays(relays.split(separator: ",").map(String.init)) }
        let st = await client.state
        emit(["type": "settings", "displayName": s.displayName as Any, "loopGuard": s.loopGuardLimit ?? PQRCConstants.agentLoopGuardLimit,
              "relays": st.relays],
             human: "name: \(s.displayName ?? "(none)")\nloop guard: \(s.loopGuardLimit ?? PQRCConstants.agentLoopGuardLimit) consecutive AI messages (0 = off)\nrelays: \(st.relays.joined(separator: ", "))")
    } catch { fail("\(error)") }

case "qr":
    let client = await openClient(openStore())
    let link = await client.pairingLink.uri
    do { let q = try QRCode.encode(link); out(q.terminalString()); out(link) } catch { fail("\(error)") }

default:
    fail("unknown command '\(command)' — see `eldr-chat help`")
}
exit(0)
