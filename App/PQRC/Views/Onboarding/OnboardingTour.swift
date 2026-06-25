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
            subtitle: "Post-quantum, in plain language.",
            body:
                "Today's encryption could one day be broken by powerful quantum computers still being built. Eldr already uses encryption designed to resist them, so a message you send now stays private even years from now — long after the seas have changed.",
            fieldNote:
                "Post-quantum cryptography is on for every conversation — no toggle, no extra steps.",
            voiceOver:
                "Ready for tomorrow's storms. Post-quantum, in plain language. Today's encryption could one day be broken by powerful quantum computers still being built. Eldr already uses encryption designed to resist them, so a message you send now stays private even years from now, long after the seas have changed. Post-quantum cryptography is on for every conversation, with no toggle and no extra steps."
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
                "The firewall is on by default for every off-device AI; the on-device model never leaves the phone at all.",
            voiceOver:
                "Tether AI on a leash. Collaborate, alone or in a crew. Bring in a powerful model like Claude, or one you run yourself, and let assistants collaborate in a shared thread — comparing notes, drafting a plan, dividing a task, on the record. You stay in command of what the AI sees, who sees it, where it goes, and when it must leave the device — and an egress firewall obfuscates contacts and caps how much can ever leave when it does. The firewall is on by default for every off-device AI."
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
                "That's the lay of the water: private by right, transparent about AI, post-quantum, and decentralized — a boat that lets people and their robots communicate and collaborate safely. Add a contact, tether an assistant, and chart your course. Curious to see it all in motion? Try the live demo from Settings.",
            fieldNote: "Replay this tour anytime from Settings ▸ About ▸ Take the tour.",
            voiceOver:
                "Set sail. A mind forever voyaging through strange seas of thought. That's the lay of the water: private by right, transparent about AI, post-quantum, and decentralized — a boat that lets people and their robots communicate and collaborate safely. Add a contact, tether an assistant, and chart your course. You can replay this tour anytime from Settings, About, Take the tour."
        ),
    ]

    /// The enterprise / funder pitch — the same card system as the welcome tour,
    /// surfaced on demand from Settings ▸ About ("Why Eldr for teams"). It leads with
    /// zero-trust collaboration, then sovereign self-hosted AI, then post-quantum /
    /// decentralized resilience. Shipped capabilities are stated as present; the team
    /// and self-hosted bridges are labeled as rolling out (the honesty rule applies
    /// here exactly as it does to the welcome tour).
    static let enterpriseSteps: [TourStep] = [
        TourStep(
            id: 0,
            symbol: "building.2.fill",
            accentSymbol: "lock.fill",
            gradient: [Color.indigo, Color.blue],
            title: "AI without the leak",
            subtitle: "Powerful agents, none of the exposure.",
            body:
                "AI is only as safe as the channel you reach it through. Eldr is the private network for your team and its agents — end-to-end encrypted, post-quantum, and yours to run. A place where people and AI work together without your data ever leaving your control.",
            fieldNote:
                "Every capability in this tour ships in the app today; the team and self-hosted integrations are rolling out now.",
            voiceOver:
                "A.I. without the leak. Powerful agents, none of the exposure. A.I. is only as safe as the channel you reach it through. Eldr is the private network for your team and its agents: end-to-end encrypted, post-quantum, and yours to run. A place where people and A.I. work together without your data ever leaving your control. Every capability in this tour ships in the app today; the team and self-hosted integrations are rolling out now."
        ),
        TourStep(
            id: 1,
            symbol: "shield.lefthalf.filled",
            accentSymbol: "person.line.dotted.person.fill",
            gradient: [Color.teal, Color.green],
            title: "Collaboration without risk",
            subtitle: "Vendors, new hires, anyone — on a leash.",
            body:
                "Give a contractor, a new hire, or a non-technical teammate a scoped, observable, revocable line to an AI agent. A per-chat egress firewall caps and obfuscates whatever could leave, agents can't act on their own, and access is one unpair away from gone.",
            fieldNote:
                "Fail-closed by default: an agent can't self-activate, and the firewall is on for every off-device model.",
            voiceOver:
                "Collaboration without risk. Vendors, new hires, anyone, on a leash. Give a contractor, a new hire, or a non-technical teammate a scoped, observable, revocable line to an A.I. agent. A per-chat egress firewall caps and obfuscates whatever could leave, agents can't act on their own, and access is one unpair away from gone. Fail-closed by default: an agent can't self-activate, and the firewall is on for every off-device model."
        ),
        TourStep(
            id: 2,
            symbol: "doc.text.magnifyingglass",
            accentSymbol: "checkmark.seal.fill",
            gradient: [Color.orange, Color.pink],
            title: "Nothing happens in the dark",
            subtitle: "Every AI action, labeled and on the record.",
            body:
                "Eldr cryptographically labels every AI-authored message as AI — it can't be forged or stripped — and shows you exactly what each assistant can read. For a regulated team, that's an audit trail by construction, not a bolt-on.",
            fieldNote:
                "The AI label is signed inside the encryption, so human and machine can never be confused on the wire.",
            voiceOver:
                "Nothing happens in the dark. Every A.I. action, labeled and on the record. Eldr cryptographically labels every A.I.-authored message as A.I., so it can't be forged or stripped, and shows you exactly what each assistant can read. For a regulated team, that's an audit trail by construction, not a bolt-on. The label is signed inside the encryption, so human and machine can never be confused on the wire."
        ),
        TourStep(
            id: 3,
            symbol: "server.rack",
            accentSymbol: "key.horizontal.fill",
            gradient: [Color.blue, Color.cyan],
            title: "Your AI, your infrastructure",
            subtitle: "No cloud vendor in the middle.",
            body:
                "Run the model yourself — on the device, or on your own server — and run the network yourself too. No API key, no third-party cloud, no lock-in. Your code, your AI, your rules, extended to the very wire your messages travel on.",
            fieldNote:
                "Bring your own model, on-device or self-hosted; stand up your own relay in minutes.",
            voiceOver:
                "Your A.I., your infrastructure. No cloud vendor in the middle. Run the model yourself, on the device or on your own server, and run the network yourself too. No A.P.I. key, no third-party cloud, no lock-in. Your code, your A.I., your rules, extended to the very wire your messages travel on. Bring your own model, on-device or self-hosted, and stand up your own relay in minutes."
        ),
        TourStep(
            id: 4,
            symbol: "antenna.radiowaves.left.and.right",
            accentSymbol: "brain.head.profile.fill",
            gradient: [Color.purple, Color.blue],
            title: "Reach your agent from anywhere",
            subtitle: "Your phone. Your self-hosted AI. One secure line.",
            body:
                "Eldr links your phone to the AI running on your own machines over a post-quantum, end-to-end-encrypted line — so you can task your self-hosted assistant from anywhere, with nothing exposed to the open internet. The cockpit stays yours; Eldr is the private network it flies over.",
            fieldNote:
                "Built to bridge self-hosted agent stacks like sybilclaw to your phone — rolling out now.",
            voiceOver:
                "Reach your agent from anywhere. Your phone, your self-hosted A.I., one secure line. Eldr links your phone to the A.I. running on your own machines over a post-quantum, end-to-end-encrypted line, so you can task your self-hosted assistant from anywhere, with nothing exposed to the open internet. The cockpit stays yours; Eldr is the private network it flies over. Built to bridge self-hosted agent stacks like sybilclaw to your phone, rolling out now."
        ),
        TourStep(
            id: 5,
            symbol: "atom",
            accentSymbol: "point.3.connected.trianglepath.dotted",
            gradient: [Color.purple, Color.indigo],
            title: "Built for the hardest networks",
            subtitle: "Post-quantum. Decentralized. No single point to fail.",
            body:
                "Encryption designed to outlast tomorrow's quantum computers, over a decentralized network with no company in the pipe — and it keeps working when the internet doesn't, falling back to local radio or a phone-hosted relay. The same properties that survive an outage are what communication needs at the edge, and eventually off-Earth.",
            fieldNote:
                "Post-quantum on every conversation; works offline over Bluetooth and Wi-Fi with no router or carrier.",
            voiceOver:
                "Built for the hardest networks. Post-quantum, decentralized, no single point to fail. Encryption designed to outlast tomorrow's quantum computers, over a decentralized network with no company in the pipe, and it keeps working when the internet doesn't, falling back to local radio or a phone-hosted relay. The same properties that survive an outage are what communication needs at the edge, and eventually off-Earth. Post-quantum is on for every conversation, and it works offline over Bluetooth and Wi-Fi with no router or carrier."
        ),
        TourStep(
            id: 6,
            symbol: "flag.checkered",
            accentSymbol: "sparkles",
            gradient: [Color.pink, Color.purple],
            title: "Own the network your AI runs on",
            subtitle: "Private by right. Sovereign by design.",
            body:
                "Zero-trust collaboration, self-hosted AI, and post-quantum resilience in one fabric — so teams can put powerful agents to work with vendors, contractors, and each other without handing their data to anyone. That's the company we're building.",
            fieldNote:
                "Replay anytime from Settings ▸ About ▸ Why Eldr for teams.",
            voiceOver:
                "Own the network your A.I. runs on. Private by right, sovereign by design. Zero-trust collaboration, self-hosted A.I., and post-quantum resilience in one fabric, so teams can put powerful agents to work with vendors, contractors, and each other without handing their data to anyone. That's the company we're building. You can replay this anytime from Settings, About, Why Eldr for teams."
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

    /// Which script the presented tour shows. `welcome` is the first-run default;
    /// `enterprise` is the on-demand "Why Eldr for teams" pitch (Settings ▸ About).
    enum Variant: Sendable { case welcome, enterprise }
    private(set) var variant: Variant = .welcome

    /// Cards for the currently-selected variant — the view reads this, not the
    /// `TourScript` arrays directly.
    var steps: [TourStep] {
        switch variant {
        case .welcome: return TourScript.steps
        case .enterprise: return TourScript.enterpriseSteps
        }
    }

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
                variant = .welcome
                isPresenting = true
                return
            }
        #endif
        if args.contains("--uitest") || args.contains("--local-universe")
            || args.contains("--uitest-biometric") || args.contains("--reset")
            || args.contains("--show-enterprise-tour")  // QA forces the enterprise variant instead
        {
            return
        }
        let key = Self.seenKey(siloID: siloID)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // Pin the welcome variant only now that we're definitely presenting the first-run
        // tour — doing it earlier clobbered a concurrently-set enterprise variant (QA path).
        variant = .welcome
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
    func relaunch(_ variant: Variant = .welcome) {
        guard !isPresenting else { return }
        self.variant = variant
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            isPresenting = true
        }
    }

    #if DEBUG
        /// QA only (`--show-enterprise-tour`): force the enterprise pitch tour on launch so
        /// it can be reviewed/screenshotted without navigating to Settings ▸ About. Compiled
        /// out of Release; never reachable in a shipped build.
        func presentEnterpriseForQA() {
            variant = .enterprise
            isPresenting = true
        }
    #endif

    /// Mark seen + dismiss (Skip or finishing the last card). Records against the
    /// active account when known, and also the device key so a re-lock to the gate
    /// doesn't re-trigger it.
    func finish(siloID: String?) {
        // Only the first-run WELCOME tour records "seen"; the on-demand enterprise
        // pitch is replayable and must never suppress a user's welcome tour.
        if variant == .welcome {
            UserDefaults.standard.set(true, forKey: Self.seenKey(siloID: siloID))
            UserDefaults.standard.set(true, forKey: Self.baseKey)
        }
        isPresenting = false
        variant = .welcome
    }
}
