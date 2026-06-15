import SwiftUI

/// The guided "explore a new planet" first-run tour (APP-SPEC §0 product
/// principles + §19–24). EldrChat genuinely is new territory — a post-quantum,
/// decentralized, AI-native, privacy-first messenger — so the first run is framed
/// as landing on and surveying a new world. Each step teaches one capability, one
/// privacy guarantee, or one of the project's goals, in an upbeat explorer voice.
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
    /// A small "field note" pill — the honest, concrete detail under the wonder.
    let fieldNote: String
    /// Spoken description for VoiceOver (replaces the decorative split).
    let voiceOver: String
}

/// The script. Order matters: arrival → privacy → transparency → capabilities →
/// goals → "go explore". Every step is a real, shipped capability (APP-SPEC
/// §19–24 / DEVIATIONS A19–A36) — nothing aspirational is taught as present.
enum TourScript {
    static let steps: [TourStep] = [
        TourStep(
            id: 0,
            symbol: "sparkles",
            accentSymbol: "globe.americas.fill",
            gradient: [Color.purple, Color.indigo],
            title: "Welcome, explorer",
            subtitle: "You've just landed somewhere new.",
            body: "EldrChat is a messenger for the AI age — post-quantum, decentralized, and private by design. It's genuinely new territory, so let's take a quick survey of the planet before you settle in.",
            fieldNote: "About 60 seconds. Skip anytime; replay it from Settings ▸ About.",
            voiceOver: "Welcome, explorer. You've just landed somewhere new. EldrChat is a messenger for the AI age — post-quantum, decentralized, and private by design. A quick guided tour follows. It takes about a minute and you can skip it anytime, or replay it later from Settings, About."
        ),
        TourStep(
            id: 1,
            symbol: "lock.shield.fill",
            accentSymbol: "atom",
            gradient: [Color.green, Color.teal],
            title: "Privacy is the law here",
            subtitle: "Rule number one, no exceptions.",
            body: "Every message is end-to-end encrypted with post-quantum cryptography, so it stays sealed even against a future quantum computer. When any choice trades privacy for convenience, privacy wins. That's the cardinal rule the whole app is built around.",
            fieldNote: "Honest limits: a relay can see your IP and that someone messaged you — never who, or what was said.",
            voiceOver: "Privacy is the law here. Rule number one, no exceptions. Every message is end-to-end encrypted with post-quantum cryptography, so it stays sealed even against a future quantum computer. When any choice trades privacy for convenience, privacy wins. Honest limit: a relay can see your I.P. address and that someone messaged you, never who or what was said."
        ),
        TourStep(
            id: 2,
            symbol: "key.horizontal.fill",
            accentSymbol: "person.2.fill",
            gradient: [Color.blue, Color.cyan],
            title: "One device, your keys",
            subtitle: "No account in the cloud — just you.",
            body: "Your identity and message keys live only on this device, protected by the Secure Enclave. Nothing is backed up, synced, or exported. Unlock with Face ID or a passphrase — and because there's no server account, there's nobody to subpoena or breach.",
            fieldNote: "Lose the passphrase and the data is gone for good. Real privacy means real responsibility.",
            voiceOver: "One device, your keys. Your identity and message keys live only on this device, protected by the Secure Enclave. Nothing is backed up, synced, or exported. Unlock with Face ID or a passphrase. Because there's no server account, there's nobody to subpoena or breach. Note: lose the passphrase and the data is gone for good."
        ),
        TourStep(
            id: 3,
            symbol: "eyeglasses",
            accentSymbol: "brain.head.profile.fill",
            gradient: [Color.orange, Color.pink],
            title: "No hidden AI channel",
            subtitle: "You see exactly what your AI sees.",
            body: "AI is built in, but there are no secrets. Tap the in-chat context chip to see what your assistant can read, right now. By default it reads only the messages you explicitly add to context — never your whole history behind your back.",
            fieldNote: "Settings ▸ AI ▸ \u{201C}What your AI sees\u{201D} shows the exact, read-only context window.",
            voiceOver: "No hidden A.I. channel. You see exactly what your AI sees. AI is built in, but there are no secrets. Tap the in-chat context chip to see what your assistant can read right now. By default it reads only the messages you explicitly add to context, never your whole history behind your back. Settings, AI, What your AI sees, shows the exact read-only context window."
        ),
        TourStep(
            id: 4,
            symbol: "checkmark.seal.fill",
            accentSymbol: "wand.and.stars",
            gradient: [Color.purple, Color.blue],
            title: "AI always wears a badge",
            subtitle: "Human or machine — always honest.",
            body: "Every message an AI writes is cryptographically labeled as AI and rendered in its own distinct bubble. There is no way to pass an assistant's words off as a person's. And an AI can never speak for you on its own — only inside a window you personally open.",
            fieldNote: "The label is signed inside the encryption, so it can't be forged or stripped in transit.",
            voiceOver: "AI always wears a badge. Human or machine, always honest. Every message an AI writes is cryptographically labeled as AI and shown in its own distinct bubble. There is no way to pass an assistant's words off as a person's. And an AI can never speak for you on its own — only inside a window you personally open."
        ),
        TourStep(
            id: 5,
            symbol: "shield.lefthalf.filled",
            accentSymbol: "arrow.up.right",
            gradient: [Color.teal, Color.green],
            title: "An egress firewall",
            subtitle: "Tether cloud AI — on a leash.",
            body: "Want a powerful model like Claude or a self-hosted one on your own machine? Tether it. Anything sent off-device passes a firewall first: it strips your contacts' names down to local codenames and hard-caps how much can ever leave in one call.",
            fieldNote: "On by default for every off-device AI. The on-device model never leaves the phone at all.",
            voiceOver: "An egress firewall. Tether cloud AI on a leash. Want a powerful model like Claude, or a self-hosted one on your own machine? Tether it. Anything sent off-device passes a firewall first: it strips your contacts' names down to local codenames and hard-caps how much can ever leave in one call. It's on by default for every off-device AI."
        ),
        TourStep(
            id: 6,
            symbol: "person.line.dotted.person.fill",
            accentSymbol: "bubble.left.and.bubble.right.fill",
            gradient: [Color.indigo, Color.purple],
            title: "Let your AIs collaborate",
            subtitle: "Two assistants, one shared thread.",
            body: "Open a shared AI thread and both people's assistants can work together — comparing calendars, drafting a plan, dividing a task — entirely inside that thread, on the record, with skills you pin from a catalog. A loop guard pauses them so a human always stays in the loop.",
            fieldNote: "Tether several AIs at once and give each its own persona and context rules.",
            voiceOver: "Let your AIs collaborate. Two assistants, one shared thread. Open a shared AI thread and both people's assistants can work together — comparing calendars, drafting a plan, dividing a task — entirely inside that thread, on the record, with skills you pin from a catalog. A loop guard pauses them so a human always stays in the loop."
        ),
        TourStep(
            id: 7,
            symbol: "antenna.radiowaves.left.and.right",
            accentSymbol: "iphone.radiowaves.left.and.right",
            gradient: [Color.orange, Color.red],
            title: "No carrier required",
            subtitle: "Your phone can be the relay.",
            body: "EldrChat rides over a decentralized network — no company owns the pipe. In a crowded place with no trusted Wi-Fi, one phone can host a pocket relay over Bluetooth and Wi-Fi Direct, and everyone nearby connects through it. No router, no third party.",
            fieldNote: "Even hosting, a relay only ever sees sealed ciphertext — never your messages.",
            voiceOver: "No carrier required. Your phone can be the relay. EldrChat rides over a decentralized network — no company owns the pipe. In a crowded place with no trusted Wi-Fi, one phone can host a pocket relay over Bluetooth and Wi-Fi Direct, and everyone nearby connects through it. No router, no third party. Even when hosting, a relay only ever sees sealed ciphertext."
        ),
        TourStep(
            id: 8,
            symbol: "square.stack.3d.up.fill",
            accentSymbol: "eye.slash.fill",
            gradient: [Color.gray, Color.indigo],
            title: "More than one you",
            subtitle: "Separate, deniable accounts.",
            body: "One app can hold several completely separate accounts, each opened by its own passphrase. Nothing reveals how many exist — a wrong passphrase simply opens nothing. Keep work and personal apart, or keep a low-stakes account for when you're asked to unlock under pressure.",
            fieldNote: "Each account's data is sealed under its own key. The app never shows an account list.",
            voiceOver: "More than one you. Separate, deniable accounts. One app can hold several completely separate accounts, each opened by its own passphrase. Nothing reveals how many exist — a wrong passphrase simply opens nothing. Keep work and personal apart, or keep a low-stakes account for when you're asked to unlock under pressure."
        ),
        TourStep(
            id: 9,
            symbol: "flag.checkered.2.crossed",
            accentSymbol: "sparkles",
            gradient: [Color.pink, Color.purple],
            title: "Go explore",
            subtitle: "The planet is yours now.",
            body: "That's the lay of the land: private by law, transparent about AI, decentralized, and quantum-ready. Add a contact, tether an assistant, and start a conversation. Curious to see it all in motion? Try the live demo from Settings.",
            fieldNote: "Replay this tour anytime from Settings ▸ About ▸ Take the tour.",
            voiceOver: "Go explore. The planet is yours now. That's the lay of the land: private by law, transparent about AI, decentralized, and quantum-ready. Add a contact, tether an assistant, and start a conversation. You can replay this tour anytime from Settings, About, Take the tour."
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

    private static let baseKey = "hasSeenOnboardingTour"

    /// Per-silo "seen" key when an account is active, else the bare device key.
    private static func seenKey(siloID: String?) -> String {
        guard let siloID, !siloID.isEmpty else { return baseKey }
        return AppSession.siloDefaultsKey(baseKey, siloID)
    }

    /// Show the tour once per account on first entry. Call when a real account is
    /// active (not the lock screen, not the demo universe). No-op if already seen.
    func presentIfFirstRun(siloID: String?) {
        // UI/automation runs must never get a modal tour in the way.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--uitest") || args.contains("--local-universe")
            || args.contains("--uitest-biometric")
        {
            return
        }
        let key = Self.seenKey(siloID: siloID)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        isPresenting = true
    }

    /// Relaunch from Settings — always shows, regardless of the seen flag.
    func relaunch() {
        isPresenting = true
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
