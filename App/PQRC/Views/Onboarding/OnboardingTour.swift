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
                "That's the lay of the water: private by right, transparent about AI, post-quantum, and decentralized — a boat that lets people and their robots communicate and collaborate safely. Add a contact, tether an assistant, and chart your course. Curious to see it all in motion? Try the live demo from Settings.",
            fieldNote: "Replay this tour anytime from Settings ▸ About ▸ Take the tour.",
            voiceOver:
                "Set sail. A mind forever voyaging through strange seas of thought. That's the lay of the water: private by right, transparent about AI, post-quantum, and decentralized — a boat that lets people and their robots communicate and collaborate safely. Add a contact, tether an assistant, and chart your course. You can replay this tour anytime from Settings, About, Take the tour."
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
