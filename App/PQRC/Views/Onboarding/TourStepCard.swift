import SwiftUI

/// A single tour card: a glowing hero badge (mock iconography, never a
/// screenshot), a headline + evocative subtitle, the teaching body, and an honest
/// "ship's log" pill. Responsive (constrained reading width for iPad/Mac), works
/// in light + dark, and folds into one VoiceOver element so the decorative split
/// isn't read piece-by-piece.
struct TourStepCard: View {
    let step: TourStep
    /// Drives the entrance animation when this card becomes the visible page.
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                heroBadge
                VStack(spacing: 12) {
                    Text(step.title)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(step.subtitle)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(step.gradient.first ?? .accentColor)
                        .multilineTextAlignment(.center)
                }
                Text(step.body)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                fieldNote
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
            .frame(maxWidth: 560)  // reading width: don't sprawl on iPad/Mac
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // One VoiceOver element for the whole card — read on page change.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.voiceOver)
        .accessibilityAddTraits(.isSummaryElement)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .onAppear { animateIn() }
        .onChange(of: isActive) { _, nowActive in
            if nowActive { animateIn() }
        }
    }

    private func animateIn() {
        guard isActive else { return }
        if reduceMotion {
            appeared = true
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        }
    }

    // MARK: - Hero badge (mock iconography)

    private var heroBadge: some View {
        ZStack {
            // Soft radial halo.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            (step.gradient.first ?? .accentColor).opacity(0.35),
                            .clear,
                        ],
                        center: .center, startRadius: 0, endRadius: 130)
                )
                .frame(width: 240, height: 240)
            // Glass disc.
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 150, height: 150)
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: step.gradient, startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        lineWidth: 3)
                )
                .shadow(
                    color: (step.gradient.first ?? .accentColor).opacity(0.4), radius: 24, y: 8)
            // Primary glyph, gradient-filled.
            Image(systemName: step.symbol)
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: step.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .symbolRenderingMode(.hierarchical)
            // Small accent glyph in a corner satellite, for a richer mock. The
            // accent may be an SF Symbol name (all-ASCII, e.g. "sailboat.fill") OR a
            // literal emoji (e.g. the enterprise tour's 🦞). `Image(systemName:)`
            // silently renders NOTHING for an emoji, so a non-ASCII accent must be
            // drawn as Text — otherwise that card shows an empty badge.
            if let accent = step.accentSymbol {
                Group {
                    if accent.allSatisfy(\.isASCII) {
                        Image(systemName: accent)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text(accent)
                            .font(.system(size: 22))
                    }
                }
                .padding(10)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: step.gradient, startPoint: .top, endPoint: .bottom))
                )
                .overlay(Circle().strokeBorder(.background, lineWidth: 3))
                .offset(x: 58, y: 54)
            }
        }
        .frame(height: 240)
        .accessibilityHidden(true)
    }

    // MARK: - Ship's log (the honest detail)

    private var fieldNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "binoculars.fill")  // scanning the horizon — the honest, concrete detail
                .font(.footnote)
                .foregroundStyle(step.gradient.first ?? .accentColor)
            Text(step.fieldNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((step.gradient.first ?? .accentColor).opacity(0.25), lineWidth: 1)
        )
    }
}
