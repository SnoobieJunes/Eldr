import SwiftUI

/// The guided "venturing on unknown seas" first-run tour (APP-SPEC §0 product
/// principles + §19–24). Eldr is genuinely new territory — a post-quantum,
/// decentralized, AI-native, privacy-first messenger — so the first run is framed
/// as setting out across unknown, sometimes-murky waters, but armed with the right
/// tools to communicate with people (and AI) you're unsure you can trust. Each
/// step teaches one capability, one privacy guarantee, or one of the project's
/// goals, and privacy and AI cards alternate so trust builds as the reader sails on.
///
/// This is pure content + a tiny coordinator. It lives at the RootView level as an
/// overlay and never reaches into the conversation/main views (those are owned
/// elsewhere); the cards use simple SF Symbol iconography, not screenshots, so
/// they can't drift out of sync with the real screens.

/// One card in the tour. Self-describing for VoiceOver: `voiceOver` is read in
/// place of the decorative glyph + split text.
struct TourStep: Identifiable, Sendable {
    let id: Int
    /// SF Symbol shown in the hero badge.
    let symbol: String
    /// A second, smaller symbol layered for a richer mock (optional).
    let accentSymbol: String?
    /// Two-tone gradient for the hero badge + progress accent.
    let gradient: [Color]
    /// Short, punchy headline.
    let title: String
    /// One-line evocative subtitle ("the hook").
    let subtitle: String
    /// The substance: 1–3 short sentences teaching the capability/guarantee.
    let body: String
    /// A small "ship's log" pill — the honest, concrete detail under the wonder.
    let fieldNote: String
    /// Spoken description for VoiceOver (replaces the decorative split).
    let voiceOver: String
}

/// The script. Order matters: cast off → privacy → AI → privacy → AI … so trust
/// builds as the reader sails on, ending with the open network and "set sail".
/// Every step is a real, shipped capability (APP-SPEC §19–24 / DEVIATIONS
/// A19–A36) — nothing aspirational is taught as present.
enum TourScript {
    static let steps: [TourStep] = [
        TourStep(
            id: 0,
            symbol: "sailboat.fill",
            accentSymbol: "location.north.fill",
            gradient: [Color.blue, Color.indigo],
            title: "Cast off",
            subtitle: "You're venturing onto unknown seas.",
            body:
                "Talking to people — and to AI — you're not yet sure you can trust is open water: vast, murky, sometimes a little scary. Eldr is the boat that keeps you and your data flowing safely through those seas with your robots, so everyone can interact with confidence in this new age of exploration.",
            fieldNote: "About 60 seconds. Skip anytime; replay it from Settings ▸ About.",
            voiceOver:
                "Cast off. You're venturing onto unknown seas. Talking to people, and to AI, you're not yet sure you can trust is open water: vast, murky, sometimes a little scary. Eldr is the boat that keeps you and your data flowing safely through those seas with your robots, so everyone can interact with confidence in this new age of exploration. A quick guided tour follows. It takes about a minute and you can skip it anytime, or replay it later from Settings, About."
        ),
        TourStep(
            id: 1,
            symbol: "lock.shield.fill",
            accentSymbol: "checkmark.seal.fill",
            gradient: [Color.green, Color.teal],
            title: "Privacy is a right",
            subtitle: "Not a setting. The whole point.",
            body:
                "Every message is end-to-end encrypted and the hull is built to be impenetrable and secure — only you and the people you're talking to can ever read a word. Whenever a choice trades privacy for convenience, privacy wins. That is the one rule the entire app is built around.",
            fieldNote:
                "Honest limit: a relay can see your IP and that someone messaged you — never who, or what was said.",
            voiceOver:
                "Privacy is a right. Not a setting; the whole point. Every message is end-to-end encrypted and the hull is built to be impenetrable and secure — only you and the people you're talking to can ever read a word. Whenever a choice trades privacy for convenience, privacy wins. Honest limit: a relay can see your I.P. address and that someone messaged you, never who or what was said."
        ),
        TourStep(
            id: 2,
            symbol: "eyeglasses",
            accentSymbol: "brain.head.profile.fill",
            gradient: [Color.orange, Color.pink],
            title: "AI you can watch",
            subtitle: "You see exactly what your AI sees.",
            body:
                "Eldr is built for working with AI from the very first day — but with no hidden channel. Tap the in-chat context chip to see precisely what your assistant can read, right now. By default it reads only the messages you choose to add to its context, never your whole history behind your back.",
            fieldNote:
                "Settings ▸ AI ▸ \u{201C}What your AI sees\u{201D} shows the exact, read-only context window.",
            voiceOver:
                "AI you can watch. You see exactly what your AI sees. Eldr is built for working with AI from the very first day, but with no hidden channel. Tap the in-chat context chip to see precisely what your assistant can read right now. By default it reads only the messages you choose to add to its context, never your whole history behind your back. Settings, AI, What your AI sees, shows the exact read-only context window."
        ),
        TourStep(
            id: 3,
            symbol: "atom",
            accentSymbol: "hourglass",
            gradient: [Color.purple, Color.blue],
            title: "Ready for tomorrow's storms",
            subtitle: "Post-quantum encryption, in plain language.",
            body:
                "Today's encryption could one day be broken by powerful quantum computers still being built. Eldr already uses encryption designed to resist them, so a message you send now stays private even years from now — long after the seas have changed.",
            fieldNote:
                "Post-quantum encryption is on for every conversation — no toggle, no extra steps.",
            voiceOver:
                "Ready for tomorrow's storms. Post-quantum encryption, in plain language. Today's encryption could one day be broken by powerful quantum computers still being built. Eldr already uses encryption designed to resist them, so a message you send now stays private even years from now, long after the seas have changed. Post-quantum encryption is on for every conversation, with no toggle and no extra steps."
        ),
        TourStep(
            id: 4,
            symbol: "checkmark.seal.fill",
            accentSymbol: "sparkles",
            gradient: [Color.indigo, Color.purple],
            title: "AI always flies its colors",
            subtitle: "Human or machine — always honest.",
            body:
                "Every message an AI writes is cryptographically labeled as AI and shown in its own distinct bubble. There is no way to pass an assistant's words off as a person's. And an AI can never speak for you on its own — only inside a window you personally open, for as long as you allow.",
            fieldNote:
                "The label is signed inside the encryption, so it can't be forged or stripped in transit.",
            voiceOver:
                "AI always flies its colors. Human or machine, always honest. Every message an AI writes is cryptographically labeled as AI and shown in its own distinct bubble. There is no way to pass an assistant's words off as a person's. And an AI can never speak for you on its own, only inside a window you personally open, for as long as you allow."
        ),
        TourStep(
            id: 5,
            symbol: "key.horizontal.fill",
            accentSymbol: "iphone.gen3",
            gradient: [Color.blue, Color.cyan],
            title: "Your keys never leave the ship",
            subtitle: "No account in the cloud — just you.",
            body:
                "Your identity and message keys live only on this device, sealed by the Secure Enclave and unlocked with Face ID or your passphrase. Nothing is saved, backed up, synced, or exported. Your data is your property and your right.",
            fieldNote:
                "Lose the passphrase and the data is gone for good. Real privacy means real responsibility.",
            voiceOver:
                "Your keys never leave the ship. No account in the cloud, just you. Your identity and message keys live only on this device, sealed by the Secure Enclave and unlocked with Face ID or your passphrase. Nothing is saved, backed up, synced, or exported. Your data is your property and your right. Note: lose the passphrase and the data is gone for good."
        ),
        TourStep(
            id: 6,
            symbol: "shield.lefthalf.filled",
            accentSymbol: "person.line.dotted.person.fill",
            gradient: [Color.teal, Color.green],
            title: "Tether AI on a leash",
            subtitle: "Collaborate — alone or in a crew.",
            body:
                "Bring in a powerful model like Claude, or one you run yourself, and let assistants collaborate in a shared thread — comparing notes, drafting a plan, dividing a task, on the record. You stay in command of what the AI sees, who sees it, where it goes, and when it must leave the device — and an egress firewall obfuscates contacts and caps how much can ever leave when it does.",
            fieldNote:
                "On by default for every off-device AI — each chat shows whether it's on, and secrets like API keys are scrubbed before anything reaches a cloud model. Your AI follows only your settings; no one else in a chat can switch it on or off.",
            voiceOver:
                "Tether AI on a leash. Collaborate, alone or in a crew. Bring in a powerful model like Claude, or one you run yourself, and let assistants collaborate in a shared thread — comparing notes, drafting a plan, dividing a task, on the record. You stay in command of what the AI sees, who sees it, where it goes, and when it must leave the device — and an egress firewall obfuscates contacts and caps how much can ever leave when it does. It's on by default for every off-device AI, each chat shows whether it's on, and secrets like A.P.I. keys are scrubbed before anything reaches a cloud model. Your A.I. follows only your settings; no one else in a chat can switch it on or off."
        ),
        TourStep(
            id: 7,
            symbol: "square.stack.3d.up.fill",
            accentSymbol: "arrow.left.and.right",
            gradient: [Color.gray, Color.indigo],
            title: "Separate seas",
            subtitle: "Keep work and personal apart.",
            body:
                "One app can hold several completely separate accounts, each opened by its own passphrase and sealed under its own key. Keep work and personal life apart by a great divide — neither can ever see the other, and the app never shows an account list. A wrong passphrase simply opens nothing.",
            fieldNote:
                "Each account's data is encrypted independently; the running app never reveals how many you keep.",
            voiceOver:
                "Separate seas. Keep work and personal apart. One app can hold several completely separate accounts, each opened by its own passphrase and sealed under its own key. Keep work and personal life apart by a great divide — neither can ever see the other, and the app never shows an account list. A wrong passphrase simply opens nothing."
        ),
        TourStep(
            id: 8,
            symbol: "antenna.radiowaves.left.and.right",
            accentSymbol: "point.3.connected.trianglepath.dotted",
            gradient: [Color.orange, Color.red],
            title: "Chart your own waters",
            subtitle: "An open network — no company owns the pipe.",
            body:
                "Eldr sails on Nostr, an open, decentralized network, so no single company owns the route your messages take. Don't trust the harbor? Stand up your own relay in minutes, or have one phone host a pocket relay over Bluetooth and Wi-Fi for everyone nearby — no router, no carrier, no third party.",
            fieldNote:
                "Even when a phone hosts the relay, it only ever sees sealed ciphertext — never your messages.",
            voiceOver:
                "Chart your own waters. An open network, no company owns the pipe. Eldr sails on Nostr, an open, decentralized network, so no single company owns the route your messages take. Don't trust the harbor? Stand up your own relay in minutes, or have one phone host a pocket relay over Bluetooth and Wi-Fi for everyone nearby — no router, no carrier, no third party. Even when a phone hosts the relay, it only ever sees sealed ciphertext, never your messages."
        ),
        TourStep(
            id: 9,
            symbol: "sailboat.fill",
            accentSymbol: "sparkles",
            gradient: [Color.pink, Color.purple],
            title: "Set sail",
            subtitle: "\u{201C}A mind forever voyaging through strange seas of thought.\u{201D}",
            body:
                "That's the lay of the water: private by right, transparent about AI, post-quantum encrypted, and decentralized — a boat that lets people and their robots communicate and collaborate safely. Add a contact, tether an assistant, and chart your course. Curious to see it all in motion? Try the live demo from Settings.",
            fieldNote: "Replay this tour anytime from Settings ▸ About ▸ Take the tour.",
            voiceOver:
                "Set sail. A mind forever voyaging through strange seas of thought. That's the lay of the water: private by right, transparent about AI, post-quantum encrypted, and decentralized — a boat that lets people and their robots communicate and collaborate safely. Add a contact, tether an assistant, and chart your course. You can replay this tour anytime from Settings, About, Take the tour."
        ),
    ]
}

/// The enterprise / funder "Why Eldr for teams" tour, surfaced INSIDE EldrChat (a
/// "Why Eldr for teams" entry in Settings ▸ About, next to "Take the tour") so it
/// can be shown on a phone when the cofounder's Mac running Huginn isn't in the
/// room. Ported verbatim from the macOS Huginn app's `EnterpriseTour.steps`
/// (Apps/Huginn ▸ EnterpriseTourView.swift) — same cards, same words — reusing
/// `TourStep` + `OnboardingTourView` so there's a single card renderer. Keep the
/// two scripts in sync if the Huginn copy changes.
///
/// Theme (matching the welcome tour): Eldr is each org's boat through unknown
/// waters; Huginn — Óðinn's raven, "thought" — is the AI that flies boat to boat
/// over Eldr's sealed line, keeping the whole fleet rowing in unison.
enum EnterpriseTourScript {
    static let steps: [TourStep] = [
        TourStep(
            id: 0,
            symbol: "bird.fill", accentSymbol: "sailboat.fill",
            gradient: [.indigo, .blue],
            title: "Huginn — the raven of thought",
            subtitle: "Shared thoughts, flying boat to boat.",
            body:
                "Eldr is each org's boat through unknown waters — private, end-to-end encrypted, yours to steer. Huginn is the thought that flies between them: your AI, carried from Eldr to Eldr over a sealed line, so a whole crew can think and work as one — every ship rowing in unison — without your data ever leaking overboard.",
            fieldNote:
                "Named for Óðinn's raven Huginn — \u{201C}thought.\u{201D} Send it out by pairing a phone from the EldrChat Bridge tab; the team integrations are rolling out now.",
            voiceOver:
                "Huginn, the raven of thought. Shared thoughts, flying boat to boat. Eldr is each org's boat through unknown waters, private, end-to-end encrypted, yours to steer. Huginn is the thought that flies between them: your A.I., carried from Eldr to Eldr over a sealed line, so a whole crew can think and work as one, every ship rowing in unison, without your data ever leaking overboard. Named for Óðinn's raven Huginn, thought."
        ),
        TourStep(
            id: 1,
            symbol: "bird.fill", accentSymbol: "🦞",
            gradient: [.mint, .teal],
            title: "Delivered, never rewritten",
            subtitle: "Tool-agnostic. Huginn routes your thought — it doesn't replace it.",
            body:
                "Huginn is the router, not another brain. Speaking ACP — the common tongue of agents — it carries your thought between Eldr and the models and tools you already sail with: OpenClaw, Xcode, and more. It never augments your thought or bends it on the way; it simply gets it where you meant it to go.",
            fieldNote:
                "ACP, the Agent Client Protocol, is the shared tongue — Huginn connects to your stack instead of replacing it. Your thought, unchanged, to the tools you already use.",
            voiceOver:
                "Delivered, never rewritten. Tool-agnostic. Huginn routes your thought; it doesn't replace it. Huginn is the router, not another brain. Speaking A.C.P., the common tongue of agents, it carries your thought between Eldr and the models and tools you already sail with: OpenClaw, Xcode, and more. It never augments your thought or bends it on the way; it simply gets it where you meant it to go. A.C.P., the Agent Client Protocol, is the shared tongue; Huginn connects to your stack instead of replacing it, your thought unchanged, to the tools you already use."
        ),
        TourStep(
            id: 2,
            symbol: "shield.lefthalf.filled", accentSymbol: "bird.fill",
            gradient: [.teal, .green],
            title: "Your raven answers only to you",
            subtitle: "Sovereign by design — yours alone to send.",
            body:
                "Your hand alone decides when your thought takes wing and what it carries — no one else aboard can launch it, ground it, or turn it. And the raven on this Mac is bound to you: invite a shipmate aboard and they can row alongside, but they can never command it, set it to a task, or bend it to their will. It heeds its master, and no other.",
            fieldNote:
                "Bound to you at pairing: a shipmate's words can never become your agent's orders — no stowaway ever reaches the helm of your Mac.",
            voiceOver:
                "Your raven answers only to you. Sovereign by design, yours alone to send. Your hand alone decides when your thought takes wing and what it carries; no one else aboard can launch it, ground it, or turn it. And the raven on this Mac is bound to you: invite a shipmate aboard and they can row alongside, but they can never command it, set it to a task, or bend it to their will. Bound to you at pairing: a shipmate's words can never become your agent's orders."
        ),
        TourStep(
            id: 3,
            symbol: "key.horizontal.fill", accentSymbol: "eye.slash.fill",
            gradient: [.blue, .cyan],
            title: "What's sealed stays sealed",
            subtitle: "Keys and secrets never make the crossing.",
            body:
                "Before your raven carries a word to another ship — or to a far-off model — Eldr strips the secrets from its talons: API keys, tokens, passwords. Even if a shipmate tries to coax a key loose, the message they receive is sealed shut. You see the cargo whole; they never do.",
            fieldNote:
                "Scrubs OpenAI / Anthropic / AWS / GitHub / Slack keys, bearer tokens, and high-entropy blobs — per recipient, and before any crossing to a cloud model.",
            voiceOver:
                "What's sealed stays sealed. Keys and secrets never make the crossing. Before your raven carries a word to another ship, or to a far-off model, Eldr strips the secrets from its talons: A.P.I. keys, tokens, passwords. Even if a shipmate tries to coax a key loose, the message they receive is sealed shut. You see the cargo whole; they never do."
        ),
        TourStep(
            id: 4,
            symbol: "hand.raised.fill", accentSymbol: "lock.shield.fill",
            gradient: [.orange, .pink],
            title: "No oar moves without your word",
            subtitle: "Nothing changes course without you.",
            body:
                "When your raven would change something on your ship — write a file, run a command — it waits for your yes, and silence is a no. It's kept to one deck it cannot leave. A powerful thought, on a line you can always see and always cut.",
            fieldNote:
                "Real and shipping: a mutating action from your paired Mac agent raises an \u{201C}Allow this action?\u{201D} prompt on your phone — Allow once, Always allow, or Deny. Fail-closed, bounded to one workdir; standing approval is a choice you make, never the default.",
            voiceOver:
                "No oar moves without your word. Nothing changes course without you. When your raven would change something on your ship, write a file, run a command, it waits for your yes, and silence is a no. It's kept to one deck it cannot leave. Real and shipping: a mutating action from your paired Mac agent raises an Allow this action prompt on your phone, Allow once, Always allow, or Deny. Fail-closed; standing approval is a choice you make, never the default."
        ),
        TourStep(
            id: 5,
            symbol: "checkmark.seal.fill", accentSymbol: "bird.fill",
            gradient: [.indigo, .purple],
            title: "Every word flies its colors",
            subtitle: "Shipmate or raven — never mistaken on the wire.",
            body:
                "Eldr marks every word your raven speaks as the raven's — a rune signed inside the encryption, that can't be forged or stripped — and shows exactly what it was given to read. For a crew that answers to rules, that's a ship's log by construction, not a bolt-on.",
            fieldNote:
                "The mark is signed inside the encryption, so shipmate and raven can never be passed off for one another on the wire.",
            voiceOver:
                "Every word flies its colors. Shipmate or raven, never mistaken on the wire. Eldr marks every word your raven speaks as the raven's, a rune signed inside the encryption that can't be forged or stripped, and shows exactly what it was given to read. For a crew that answers to rules, that's a ship's log by construction, not a bolt-on."
        ),
        TourStep(
            id: 6,
            symbol: "server.rack", accentSymbol: "key.horizontal.fill",
            gradient: [.blue, .cyan],
            title: "Your raven, your waters",
            subtitle: "No harbor master in the middle.",
            body:
                "Fly a raven you keep yourself — on this Mac, or your own server — no API key, no distant cloud, no lock-in. Your crew, your thought, your rules, all the way down to the model that does the thinking.",
            fieldNote:
                "Point Huginn at a local model — LM Studio, Ollama, or vLLM — in Configuration. Nothing about your thought has to leave a machine you own.",
            voiceOver:
                "Your raven, your waters. No harbor master in the middle. Fly a raven you keep yourself, on this Mac or your own server, no A.P.I. key, no distant cloud, no lock-in. Your crew, your thought, your rules, all the way down to the model that does the thinking. Point Huginn at a local model, L.M. Studio, Ollama, or vLLM, in Configuration."
        ),
        TourStep(
            id: 7,
            symbol: "point.3.connected.trianglepath.dotted", accentSymbol: "server.rack",
            gradient: [.teal, .blue],
            title: "Sail open waters, or raise your own harbor",
            subtitle: "Decentralized by default. Self-hosted when you want.",
            body:
                "Eldr sails on Nostr — an open, decentralized network where no single company owns the sea-lanes your words travel. Trust no harbor at all? Raise your own: Huginn fits out a hardened relay in a few clicks from the Relay tab — domain, port, allowlist, TLS — so your whole fleet routes through a harbor you alone command.",
            fieldNote:
                "The Relay tab generates a ready-to-run, hardened relay server; or a phone can host a pocket harbor over Bluetooth and Wi-Fi. Either way the harbor only ever sees sealed ciphertext — never your words.",
            voiceOver:
                "Sail open waters, or raise your own harbor. Decentralized by default, self-hosted when you want. Eldr sails on Nostr, an open, decentralized network where no single company owns the sea-lanes your words travel. Trust no harbor at all? Raise your own: Huginn fits out a hardened relay in a few clicks from the Relay tab, domain, port, allowlist, T.L.S., so your whole fleet routes through a harbor you alone command. The Relay tab generates a ready-to-run, hardened relay server, or a phone can host a pocket harbor over Bluetooth and Wi-Fi. Either way the harbor only ever sees sealed ciphertext, never your words."
        ),
        TourStep(
            id: 8,
            symbol: "antenna.radiowaves.left.and.right", accentSymbol: "bird.fill",
            gradient: [.purple, .blue],
            title: "Send the raven from any shore",
            subtitle: "Your phone, your ship's thought, one sealed line.",
            body:
                "Eldr ties your phone to the thought running on your own ships over a post-quantum, end-to-end-encrypted line — so you can send your raven from any shore and have it wing home, with nothing left exposed on open water.",
            fieldNote:
                "Built to carry self-hosted agent crews like sybilclaw to your phone — pair from the EldrChat Bridge tab. Rolling out now.",
            voiceOver:
                "Send the raven from any shore. Your phone, your ship's thought, one sealed line. Eldr ties your phone to the thought running on your own ships over a post-quantum, end-to-end-encrypted line, so you can send your raven from any shore and have it wing home, with nothing left exposed on open water."
        ),
        TourStep(
            id: 9,
            symbol: "atom", accentSymbol: "point.3.connected.trianglepath.dotted",
            gradient: [.purple, .indigo],
            title: "Built for the hardest seas",
            subtitle: "Post-quantum encryption. Holds when the net doesn't.",
            body:
                "Encryption forged to outlast tomorrow's storms — the quantum machines still being built — that holds its bearing when the internet goes dark, falling back to local radio or a phone that hosts the harbor itself. The qualities that ride out a squall are the ones thought will need at the edge of the map, and one day beyond it.",
            fieldNote:
                "Post-quantum encryption on every crossing; rows on over Bluetooth and Wi-Fi with no router or carrier.",
            voiceOver:
                "Built for the hardest seas. Post-quantum encryption that holds when the net doesn't. Encryption forged to outlast tomorrow's storms, the quantum machines still being built, that holds its bearing when the internet goes dark, falling back to local radio or a phone that hosts the harbor itself. The qualities that ride out a squall are the ones thought will need at the edge of the map, and one day beyond it. Post-quantum encryption on every crossing; it rows on over Bluetooth and Wi-Fi with no router or carrier."
        ),
        TourStep(
            id: 10,
            symbol: "sailboat.fill", accentSymbol: "sparkles",
            gradient: [.pink, .purple],
            title: "A fleet that rows as one",
            subtitle: "Private by right. Sovereign by design.",
            body:
                "Boats that trust no harbor, ravens that answer only to their masters, and thought that flies sealed between them — so a whole fleet can put powerful AI to the oars together, in unison, without ever handing over the tiller. That's the company we're building.",
            fieldNote:
                "Replay this anytime from Settings ▸ About ▸ \u{201C}Why Eldr for teams.\u{201D}",
            voiceOver:
                "A fleet that rows as one. Private by right, sovereign by design. Boats that trust no harbor, ravens that answer only to their masters, and thought that flies sealed between them, so a whole fleet can put powerful A.I. to the oars together, in unison, without ever handing over the tiller. That's the company we're building."
        ),
    ]
}

/// Tracks whether the first-run tour has been shown, and lets Settings relaunch
/// it. Per-account where possible (so a fresh silo gets its own welcome), with a
/// device-wide fallback for the lock screen / no active account.
@MainActor
@Observable
final class TourCoordinator {
    /// Currently presenting the tour.
    var isPresenting = false

    /// Cards for the first-run welcome tour. (The enterprise / funder "Why Eldr for
    /// teams" pitch moved to the Huginn app — Apps/Huginn ▸ EnterpriseTourView.swift.)
    var steps: [TourStep] { TourScript.steps }

    private static let baseKey = "hasSeenOnboardingTour"

    /// Per-silo "seen" key when an account is active, else the bare device key.
    private static func seenKey(siloID: String?) -> String {
        guard let siloID, !siloID.isEmpty else { return baseKey }
        return AppSession.siloDefaultsKey(baseKey, siloID)
    }

    /// Show the tour once per account on first entry. Call when a real account is
    /// active (not the lock screen, not the demo universe). No-op if already seen.
    func presentIfFirstRun(siloID: String?) {
        // UI/automation runs must never get a modal tour in the way. `--reset` is a
        // dev/test wipe that lands on a clean create flow; the onboarding UI test
        // drives that flow and asserts the main UI directly, so it must not be
        // boxed in by the tour either.
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
            // Dev/QA-only: force the welcome tour on top of the demo universe so it
            // can be reviewed and screenshotted without going through account
            // creation. Compiled out of Release; never reachable in a shipped build.
            if args.contains("--show-tour") {
                isPresenting = true
                return
            }
        #endif
        if args.contains("--uitest") || args.contains("--local-universe")
            || args.contains("--uitest-biometric") || args.contains("--reset")
        {
            return
        }
        let key = Self.seenKey(siloID: siloID)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        isPresenting = true
    }

    /// Relaunch from Settings — always shows, regardless of the seen flag.
    ///
    /// The tour is a `fullScreenCover` on `RootView`, and "Take the tour" lives
    /// inside the Settings `.sheet` (also presented from `RootView`). Flipping
    /// `isPresenting` in the same turn that the sheet calls `dismiss()` made UIKit
    /// try to present the cover while the sheet was still dismissing — a
    /// present-while-presentation-in-progress conflict that UIKit drops, so the
    /// tour silently never appeared. Defer to the next runloop turns so the sheet
    /// fully tears down first, then present. (`isPresenting` already drives the
    /// cover, so a one-tick hop after the dismissal lands is enough; we wait a
    /// touch longer than the sheet's dismiss animation to be safe.)
    func relaunch() {
        guard !isPresenting else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            isPresenting = true
        }
    }

    /// Mark seen + dismiss (Skip or finishing the last card). Records against the
    /// active account when known, and also the device key so a re-lock to the gate
    /// doesn't re-trigger it.
    func finish(siloID: String?) {
        UserDefaults.standard.set(true, forKey: Self.seenKey(siloID: siloID))
        UserDefaults.standard.set(true, forKey: Self.baseKey)
        isPresenting = false
    }
}
