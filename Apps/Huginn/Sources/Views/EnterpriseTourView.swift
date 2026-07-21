// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// The enterprise / funder "Why Eldr for teams" tour, hosted in Huginn (the agent
/// cockpit) rather than EldrChat — this is where the team + self-hosted-AI story
/// lands, and where the agent-security guarantees (owner-bound agent, credential
/// scrubbing, human-in-the-loop tool approval, file jail) are most concrete.
///
/// Theme (matching EldrChat's voyaging tour): **Eldr** is each org's boat through
/// unknown waters; **Huginn** — named for Óðinn's raven, "thought" — is the AI that
/// flies from boat to boat over Eldr's sealed line, keeping the whole fleet rowing in
/// unison. The cards carry that metaphor while teaching one real, shipped guarantee
/// each.
///
/// Self-contained: it mirrors EldrChat's polished card tour (glowing hero badge,
/// two-tone gradients, progress rail, the honest "field note" pill) but is
/// macOS-native — a `.sheet`-presented, button-driven walkthrough (no iOS-only
/// `TabView(.page)` / `fullScreenCover`). Pure content + view code.

// MARK: - Model

/// One card in the tour. `voiceOver` is read in place of the decorative glyph + split.
struct EnterpriseTourStep: Identifiable {
    let id: Int
    let symbol: String
    let accentSymbol: String?
    let gradient: [Color]
    let title: String
    let subtitle: String
    let body: String
    let fieldNote: String
    let voiceOver: String
}

enum EnterpriseTour {
    /// Eldr (the boats) + Huginn (the raven of thought flying between them): leads with
    /// what Huginn is, then the agent-security guarantees made concrete here — the raven
    /// answers only to you, its cargo stays sealed, no oar moves without your word —
    /// then honest labeling, your own model + your own network, sending the raven home,
    /// the hardest seas, and the fleet as one. Shipped capabilities are stated as
    /// present; the team / self-hosted bridges are labeled as rolling out (honesty rule).
    ///
    /// NOTE: `id` MUST equal the array index (the progress rail keys `step.id == index`),
    /// so inserting a card means renumbering the ones after it.
    static let steps: [EnterpriseTourStep] = [
        EnterpriseTourStep(
            id: 0,
            symbol: "bird.fill", accentSymbol: "sailboat.fill",
            gradient: [.indigo, .blue],
            title: "Huginn — the raven of thought",
            subtitle: "Shared thoughts, flying boat to boat.",
            body:
                "Eldr is each org's boat through unknown waters — private, end-to-end encrypted, yours to steer. Huginn is the thought that flies between them: your AI, carried from Eldr to Eldr over a sealed line, so a whole crew can think and work as one — every ship rowing in unison — without your data ever leaking overboard.",
            fieldNote:
                "Named for Óðinn's raven Huginn — “thought.” Send it out by pairing a phone from the Bridge (phone tether) tab; the team integrations are rolling out now.",
            voiceOver:
                "Huginn, the raven of thought. Shared thoughts, flying boat to boat. Eldr is each org's boat through unknown waters, private, end-to-end encrypted, yours to steer. Huginn is the thought that flies between them: your A.I., carried from Eldr to Eldr over a sealed line, so a whole crew can think and work as one, every ship rowing in unison, without your data ever leaking overboard. Named for Óðinn's raven Huginn, thought."
        ),
        EnterpriseTourStep(
            id: 1,
            // The raven (big) carrying the OpenClaw "lobster" (the satellite emoji) —
            // Huginn picking your thought up and dropping it into the tools you use.
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
        EnterpriseTourStep(
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
        EnterpriseTourStep(
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
        EnterpriseTourStep(
            id: 4,
            symbol: "hand.raised.fill", accentSymbol: "lock.shield.fill",
            gradient: [.orange, .pink],
            title: "No oar moves without your word",
            subtitle: "Nothing changes course without you.",
            body:
                "When your raven would change something on your ship — write a file, run a command — it waits for your yes, and silence is a no. It's kept to one deck it cannot leave. A powerful thought, on a line you can always see and always cut.",
            fieldNote:
                "Real and shipping: a mutating action from your paired Mac agent raises an “Allow this action?” prompt on your phone — Allow once, Always allow, or Deny. Fail-closed, bounded to one workdir; standing approval is a choice you make, never the default.",
            voiceOver:
                "No oar moves without your word. Nothing changes course without you. When your raven would change something on your ship, write a file, run a command, it waits for your yes, and silence is a no. It's kept to one deck it cannot leave. Real and shipping: a mutating action from your paired Mac agent raises an Allow this action prompt on your phone, Allow once, Always allow, or Deny. Fail-closed; standing approval is a choice you make, never the default."
        ),
        EnterpriseTourStep(
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
        EnterpriseTourStep(
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
        EnterpriseTourStep(
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
        EnterpriseTourStep(
            id: 8,
            symbol: "antenna.radiowaves.left.and.right", accentSymbol: "bird.fill",
            gradient: [.purple, .blue],
            title: "Send the raven from any shore",
            subtitle: "Your phone, your ship's thought, one sealed line.",
            body:
                "Eldr ties your phone to the thought running on your own ships over a post-quantum, end-to-end-encrypted line — so you can send your raven from any shore and have it wing home, with nothing left exposed on open water.",
            fieldNote:
                "Built to carry self-hosted agent crews like sybilclaw to your phone — pair from the Bridge (phone tether) tab. Rolling out now.",
            voiceOver:
                "Send the raven from any shore. Your phone, your ship's thought, one sealed line. Eldr ties your phone to the thought running on your own ships over a post-quantum, end-to-end-encrypted line, so you can send your raven from any shore and have it wing home, with nothing left exposed on open water."
        ),
        EnterpriseTourStep(
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
        EnterpriseTourStep(
            id: 10,
            symbol: "sailboat.fill", accentSymbol: "sparkles",
            gradient: [.pink, .purple],
            title: "A fleet that rows as one",
            subtitle: "Private by right. Sovereign by design.",
            body:
                "Boats that trust no harbor, ravens that answer only to their masters, and thought that flies sealed between them — so a whole fleet can put powerful AI to the oars together, in unison, without ever handing over the tiller. That's the company we're building.",
            fieldNote:
                "Replay this anytime from the “Why Eldr for teams” card in Configuration.",
            voiceOver:
                "A fleet that rows as one. Private by right, sovereign by design. Boats that trust no harbor, ravens that answer only to their masters, and thought that flies sealed between them, so a whole fleet can put powerful A.I. to the oars together, in unison, without ever handing over the tiller. That's the company we're building."
        ),
    ]
}

// MARK: - View (macOS card walkthrough)

/// The sheet-presented tour. Drive it with Back / Next or the progress rail; Skip /
/// Done call `onFinish`. Mirrors EldrChat's `OnboardingTourView` look, adapted for
/// macOS (no page-style `TabView`, no `fullScreenCover`).
struct EnterpriseTourView: View {
    let onFinish: () -> Void

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [EnterpriseTourStep] { EnterpriseTour.steps }
    private var current: EnterpriseTourStep { steps[index] }
    private var isLast: Bool { index >= steps.count - 1 }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                topBar
                card
                controls
            }
        }
        .frame(minWidth: 640, idealWidth: 700, maxWidth: 760,
               minHeight: 660, idealHeight: 760)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Backdrop (accent-tinted, animates with the page)

    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.background)  // adaptive window background (light/dark)
            LinearGradient(
                colors: [
                    (current.gradient.first ?? .accentColor).opacity(0.18),
                    .clear,
                    (current.gradient.last ?? .accentColor).opacity(0.12),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: index)
    }

    // MARK: Top bar (brand + counter + Skip)

    private var topBar: some View {
        HStack {
            Label("Eldr", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .accessibilityHidden(true)
            Spacer()
            Text("\(index + 1) of \(steps.count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button("Skip") { onFinish() }
                .padding(.leading, 12)
                .accessibilityIdentifier("enterprise-tour-skip")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    // MARK: Card

    private var card: some View {
        ScrollView {
            VStack(spacing: 28) {
                heroBadge
                VStack(spacing: 12) {
                    Text(current.title)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(current.subtitle)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(current.gradient.first ?? .accentColor)
                        .multilineTextAlignment(.center)
                }
                Text(current.body)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                fieldNote
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current.voiceOver)
        .accessibilityAddTraits(.isSummaryElement)
        .id(index)  // re-create on page change so the entrance reads fresh to VoiceOver
        .transition(.opacity)
    }

    private var heroBadge: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [(current.gradient.first ?? .accentColor).opacity(0.35), .clear],
                        center: .center, startRadius: 0, endRadius: 130)
                )
                .frame(width: 240, height: 240)
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 150, height: 150)
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: current.gradient, startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        lineWidth: 3)
                )
                .shadow(
                    color: (current.gradient.first ?? .accentColor).opacity(0.4), radius: 24, y: 8)
            Image(systemName: current.symbol)
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: current.gradient, startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                )
                .symbolRenderingMode(.hierarchical)
            if let accent = current.accentSymbol {
                Group {
                    // SF Symbol names are ASCII; anything else is a literal emoji
                    // accent (e.g. the 🦞 the raven carries). Emoji render in their own
                    // colors, so they ride the gradient disc directly rather than a
                    // white tint.
                    if accent.first?.isASCII == false {
                        Text(accent).font(.system(size: 22))
                    } else {
                        Image(systemName: accent)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(10)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: current.gradient, startPoint: .top, endPoint: .bottom))
                )
                .overlay(Circle().strokeBorder(.background, lineWidth: 3))
                .offset(x: 58, y: 54)
            }
        }
        .frame(height: 240)
        .accessibilityHidden(true)
    }

    private var fieldNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "binoculars.fill")
                .font(.footnote)
                .foregroundStyle(current.gradient.first ?? .accentColor)
            Text(current.fieldNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((current.gradient.first ?? .accentColor).opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: Controls (progress rail + Back / Next)

    private var controls: some View {
        VStack(spacing: 18) {
            progressRail
            HStack(spacing: 12) {
                if index > 0 {
                    Button {
                        advance(to: index - 1)
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("enterprise-tour-back")
                }
                Button {
                    if isLast { onFinish() } else { advance(to: index + 1) }
                } label: {
                    Text(isLast ? "Set sail" : "Next")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(current.gradient.first ?? .accentColor)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(isLast ? "enterprise-tour-finish" : "enterprise-tour-next")
            }
            .frame(maxWidth: 460)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 4)
    }

    private var progressRail: some View {
        HStack(spacing: 7) {
            ForEach(steps) { step in
                Button {
                    advance(to: step.id)
                } label: {
                    Capsule()
                        .fill(
                            step.id == index
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: current.gradient, startPoint: .leading,
                                        endPoint: .trailing))
                                : AnyShapeStyle(Color.secondary.opacity(0.3))
                        )
                        .frame(width: step.id == index ? 26 : 7, height: 7)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(step.id + 1) of \(steps.count): \(step.title)")
                .accessibilityAddTraits(step.id == index ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("enterprise-tour-dot-\(step.id)")
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: index)
    }

    private func advance(to newIndex: Int) {
        guard newIndex >= 0, newIndex < steps.count else { return }
        if reduceMotion {
            index = newIndex
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { index = newIndex }
        }
    }
}
