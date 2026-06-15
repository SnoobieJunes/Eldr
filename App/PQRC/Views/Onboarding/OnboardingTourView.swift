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
            Button("Skip") { onFinish() }
                .font(.body.weight(.medium))
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
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: index)
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1) of \(steps.count)")
        .accessibilityValue(current.title)
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
