import SwiftUI

/// The enterprise / funder "Why Eldr for teams" tour, hosted in Huginn (the agent
/// cockpit) rather than EldrChat — this is where the team + self-hosted-AI story
/// lands, and where the agent-security guarantees (owner-gated agent, credential
/// scrubbing, human-in-the-loop tool approval, file jail) are most concrete.
///
/// Self-contained: it mirrors EldrChat's polished card tour (glowing hero badge,
/// two-tone gradients, progress rail, the honest "field note" pill) but is
/// macOS-native — a `.sheet`-presented, button-driven walkthrough (no iOS-only
/// `TabView(.page)` / `fullScreenCover`). Pure content + view code; no Huginn
/// domain dependencies.

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
    /// Leads with the private network + sovereign/owner-gated AI, then the concrete
    /// agent-security guarantees (secrets scrubbed, every action approved, jailed),
    /// then honest labeling, self-hosted infra, the phone↔agent bridge, post-quantum
    /// resilience, and the close. Shipped capabilities are stated as present; the
    /// team / self-hosted bridges are labeled as rolling out (the honesty rule).
    static let steps: [EnterpriseTourStep] = [
        EnterpriseTourStep(
            id: 0,
            symbol: "building.2.fill", accentSymbol: "lock.fill",
            gradient: [.indigo, .blue],
            title: "AI without the leak",
            subtitle: "Powerful agents, none of the exposure.",
            body:
                "Eldr is the private network for your team and its AI — end-to-end encrypted, post-quantum, and yours to run. Huginn is the cockpit on this Mac; Eldr is the secure line your people reach it over, so your data never leaves your control.",
            fieldNote:
                "Everything in this tour ships today. Pair a phone from the EldrChat Bridge tab to try it; the team integrations are rolling out now.",
            voiceOver:
                "A.I. without the leak. Powerful agents, none of the exposure. Eldr is the private network for your team and its A.I., end-to-end encrypted, post-quantum, and yours to run. Huginn is the cockpit on this Mac; Eldr is the secure line your people reach it over, so your data never leaves your control."
        ),
        EnterpriseTourStep(
            id: 1,
            symbol: "person.badge.shield.checkmark.fill", accentSymbol: "hand.raised.fill",
            gradient: [.teal, .green],
            title: "Your AI answers to you alone",
            subtitle: "Sovereign by design — and only yours to drive.",
            body:
                "Your settings alone decide when your AI speaks and what it sees — no one else in a chat can switch it on, off, or change it. And the agent on this Mac is pinned to you: invite a colleague in and they can collaborate, but they can never task your agent, run its tools, or hijack it. It answers to its owner.",
            fieldNote:
                "Owner-pinned at pairing: a non-owner's message can never become an agent command — no confused-deputy, no colleague reaching a shell on your Mac.",
            voiceOver:
                "Your A.I. answers to you alone. Sovereign by design, and only yours to drive. Your settings alone decide when your A.I. speaks and what it sees; no one else in a chat can switch it on, off, or change it. And the agent on this Mac is pinned to you: invite a colleague in and they can collaborate, but they can never task your agent, run its tools, or hijack it. Owner-pinned at pairing: a non-owner's message can never become an agent command."
        ),
        EnterpriseTourStep(
            id: 2,
            symbol: "key.horizontal.fill", accentSymbol: "eye.slash.fill",
            gradient: [.blue, .cyan],
            title: "Secrets never leave the room",
            subtitle: "Keys and tokens are scrubbed automatically.",
            body:
                "Before anything your agent says reaches another person — or a cloud model — Eldr strips credential-shaped secrets: API keys, tokens, passwords. Even if someone tries to coax a key out of your agent, the copy they receive is redacted. You see the raw answer; they don't.",
            fieldNote:
                "Pattern-scrubs OpenAI / Anthropic / AWS / GitHub / Slack keys, bearer tokens, and high-entropy blobs — per recipient, and before any cloud egress.",
            voiceOver:
                "Secrets never leave the room. Keys and tokens are scrubbed automatically. Before anything your agent says reaches another person, or a cloud model, Eldr strips credential-shaped secrets: A.P.I. keys, tokens, passwords. Even if someone tries to coax a key out of your agent, the copy they receive is redacted. You see the raw answer; they don't."
        ),
        EnterpriseTourStep(
            id: 3,
            symbol: "hand.raised.fill", accentSymbol: "lock.shield.fill",
            gradient: [.orange, .pink],
            title: "Every action needs your hand",
            subtitle: "Nothing mutates without your approval.",
            body:
                "Write a file, run a command — every action that changes something waits for your yes on your phone, and silence means no. The agent is boxed into one working directory it can't escape. A powerful agent, on a short, observable leash.",
            fieldNote:
                "Fail-closed by default: mutating tools need explicit approval and stay inside the workdir jail. Auto-approve is an explicit opt-in, never the default.",
            voiceOver:
                "Every action needs your hand. Nothing mutates without your approval. Write a file, run a command: every action that changes something waits for your yes on your phone, and silence means no. The agent is boxed into one working directory it can't escape. Fail-closed by default; auto-approve is an explicit opt-in, never the default."
        ),
        EnterpriseTourStep(
            id: 4,
            symbol: "doc.text.magnifyingglass", accentSymbol: "checkmark.seal.fill",
            gradient: [.pink, .orange],
            title: "Nothing happens in the dark",
            subtitle: "Every AI action, labeled and on the record.",
            body:
                "Eldr cryptographically labels every AI-authored message as AI — it can't be forged or stripped — and shows exactly what each assistant can read. For a regulated team, that's an audit trail by construction, not a bolt-on.",
            fieldNote:
                "The AI label is signed inside the encryption, so human and machine can never be confused on the wire.",
            voiceOver:
                "Nothing happens in the dark. Every A.I. action, labeled and on the record. Eldr cryptographically labels every A.I.-authored message as A.I., so it can't be forged or stripped, and shows exactly what each assistant can read. For a regulated team, that's an audit trail by construction, not a bolt-on."
        ),
        EnterpriseTourStep(
            id: 5,
            symbol: "server.rack", accentSymbol: "key.horizontal.fill",
            gradient: [.blue, .cyan],
            title: "Your AI, your infrastructure",
            subtitle: "No cloud vendor in the middle.",
            body:
                "Run the model yourself — on this Mac, or your own server — and run the network yourself too. No API key, no third-party cloud, no lock-in. Your code, your AI, your rules, extended to the very wire your messages travel on.",
            fieldNote:
                "Point Huginn at a local LLM (LM Studio, Ollama, vLLM) in Configuration; stand up your own relay from the Relay tab.",
            voiceOver:
                "Your A.I., your infrastructure. No cloud vendor in the middle. Run the model yourself, on this Mac or your own server, and run the network yourself too. No A.P.I. key, no third-party cloud, no lock-in. Point Huginn at a local L.L.M. in Configuration, and stand up your own relay from the Relay tab."
        ),
        EnterpriseTourStep(
            id: 6,
            symbol: "antenna.radiowaves.left.and.right", accentSymbol: "brain.head.profile.fill",
            gradient: [.purple, .blue],
            title: "Reach your agent from anywhere",
            subtitle: "Your phone. Your self-hosted AI. One secure line.",
            body:
                "Eldr links your phone to the AI running on your own machines over a post-quantum, end-to-end-encrypted line — so you can task your self-hosted assistant from anywhere, with nothing exposed to the open internet.",
            fieldNote:
                "Built to bridge self-hosted agent stacks like sybilclaw to your phone — pair from the EldrChat Bridge tab. Rolling out now.",
            voiceOver:
                "Reach your agent from anywhere. Your phone, your self-hosted A.I., one secure line. Eldr links your phone to the A.I. running on your own machines over a post-quantum, end-to-end-encrypted line, so you can task your self-hosted assistant from anywhere, with nothing exposed to the open internet."
        ),
        EnterpriseTourStep(
            id: 7,
            symbol: "atom", accentSymbol: "point.3.connected.trianglepath.dotted",
            gradient: [.purple, .indigo],
            title: "Built for the hardest networks",
            subtitle: "Post-quantum. Decentralized. No single point to fail.",
            body:
                "Encryption designed to outlast tomorrow's quantum computers, over a network with no company in the pipe — and it keeps working when the internet doesn't, falling back to local radio or a phone-hosted relay. The same properties that survive an outage are what communication needs at the edge, and eventually off-Earth.",
            fieldNote:
                "Post-quantum on every conversation; works offline over Bluetooth and Wi-Fi with no router or carrier.",
            voiceOver:
                "Built for the hardest networks. Post-quantum, decentralized, no single point to fail. Encryption designed to outlast tomorrow's quantum computers, over a network with no company in the pipe, and it keeps working when the internet doesn't, falling back to local radio or a phone-hosted relay. The same properties that survive an outage are what communication needs at the edge, and eventually off-Earth."
        ),
        EnterpriseTourStep(
            id: 8,
            symbol: "flag.checkered", accentSymbol: "sparkles",
            gradient: [.pink, .purple],
            title: "Own the network your AI runs on",
            subtitle: "Private by right. Sovereign by design.",
            body:
                "Zero-trust collaboration, self-hosted AI, and post-quantum resilience in one fabric — so teams can put powerful agents to work with vendors, contractors, and each other without handing their data to anyone. That's the company we're building.",
            fieldNote:
                "Replay this tour anytime from the “Why Eldr for teams” button in Configuration.",
            voiceOver:
                "Own the network your A.I. runs on. Private by right, sovereign by design. Zero-trust collaboration, self-hosted A.I., and post-quantum resilience in one fabric, so teams can put powerful agents to work with vendors, contractors, and each other without handing their data to anyone. That's the company we're building."
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
                Image(systemName: accent)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
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
                    Text(isLast ? "Get started" : "Next")
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
