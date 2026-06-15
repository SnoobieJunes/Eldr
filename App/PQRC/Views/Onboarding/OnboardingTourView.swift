import SwiftUI

/// The full-screen guided tour: a swipeable sequence of `TourStepCard`s with a
/// progress rail, Skip, Back, and Next/Begin. Presented as an overlay at the
/// RootView level (it never reaches into the conversation views, which are owned
/// elsewhere) and is fully driven by `TourScript` content + a `TourCoordinator`.
///
/// Accessibility: every page is one VoiceOver element (`TourStepCard`); the
/// controls are labeled; the progress rail announces "step N of M".
struct OnboardingTourView: View {
    /// Marks the tour seen + dismisses (Skip or finishing).
    let onFinish: () -> Void

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [TourStep] { TourScript.steps }
    private var isLast: Bool { index >= steps.count - 1 }
    private var current: TourStep { steps[index] }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                topBar
                pager
                controls
            }
        }
        .interactiveDismissDisabled()  // a deliberate Skip/Begin, not a swipe-down
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Backdrop (subtle, accent-tinted, animates with the page)

    private var backdrop: some View {
        ZStack {
            Color(.systemBackground)
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

    // MARK: - Top bar (brand mark + Skip)

    private var topBar: some View {
        HStack {
            Label("EldrChat", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .accessibilityHidden(true)
            Spacer()
            // Visible "where am I / how much is left" cue: a 10-card tour with no
            // count reads as endless and invites a premature Skip. A monospaced-
            // digit counter keeps the number from jittering as it ticks up.
            Text("\(index + 1) of \(steps.count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)  // the rail already announces step N of M
            Button("Skip") { onFinish() }
                .font(.body.weight(.medium))
                .padding(.leading, 12)
                .accessibilityIdentifier("tour-skip")
                .accessibilityHint("Closes the tour. You can replay it later from Settings, About.")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Pager

    private var pager: some View {
        TabView(selection: $index) {
            ForEach(steps) { step in
                TourStepCard(step: step, isActive: step.id == index)
                    .tag(step.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .accessibilityIdentifier("tour-pager")
    }

    // MARK: - Controls (progress rail + Back / Next)

    private var controls: some View {
        VStack(spacing: 18) {
            progressRail
            HStack(spacing: 12) {
                if index > 0 {
                    Button {
                        advance(to: index - 1)
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("tour-back")
                }
                Button {
                    if isLast { onFinish() } else { advance(to: index + 1) }
                } label: {
                    Text(isLast ? "Start exploring" : "Next")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(current.gradient.first ?? .accentColor)
                .accessibilityIdentifier(isLast ? "tour-finish" : "tour-next")
            }
            .frame(maxWidth: 480)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
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
                        // A comfortable touch target around the small dot without
                        // changing its visual size (the rail must stay slim).
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                // Now interactive, so each dot is its own a11y element — this also
                // lets VoiceOver users jump straight to any topic instead of only
                // swiping the pager. The current step is marked selected.
                .accessibilityLabel("Step \(step.id + 1) of \(steps.count): \(step.title)")
                .accessibilityAddTraits(step.id == index ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(step.id == index ? "" : "Jumps to this step")
                .accessibilityIdentifier("tour-dot-\(step.id)")
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

// MARK: - RootView attachment

extension View {
    /// Presents the onboarding tour over the receiver as a full-screen cover when
    /// `coordinator.isPresenting` is set. The single hook added to `RootView`; it
    /// touches nothing inside MainView/ConversationView.
    func onboardingTour(_ coordinator: TourCoordinator, activeSiloID: String?) -> some View {
        fullScreenCover(isPresented: Bindable(coordinator).isPresenting) {
            OnboardingTourView(onFinish: { coordinator.finish(siloID: activeSiloID) })
        }
    }
}
