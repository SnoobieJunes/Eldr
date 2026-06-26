import SwiftUI

/// A tasteful, cross-platform "help & info" affordance (one source string, one
/// call site) that explains EldrChat's genuinely-novel features without
/// cluttering the UI.
///
/// Why this exists: SwiftUI's `.help(_:)` only surfaces on **Mac on hover** and
/// shows *nothing* on iOS (touch has no hover), so the explanatory text we'd
/// added was invisible to iPhone/iPad users. `InfoButton` fixes that by being
/// visible and on-demand on **both** platforms:
///
/// - **Mac (Catalyst):** the small `info.circle` carries a `.help(text)` hover
///   tooltip (the native Mac idiom) *and* opens the same popover on click.
/// - **iOS (iPhone/iPad):** the `info.circle` is the visible, tappable cue;
///   tapping opens a brief popover with the same text. `.presentationCompact
///   Adaptation(.popover)` keeps it a small popover bubble on iPhone instead of
///   ballooning into a sheet.
///
/// It uses SF Symbols + system styling, so it adapts to Dynamic Type, light &
/// dark, and is fully VoiceOver-labelled. Tone matches `docs/USER-GUIDE.md`:
/// clear, friendly, privacy-forward, honest — a sentence or two each.
///
/// Use judiciously (the "do not clutter" rule): prefer ONE per section header.
struct InfoButton: View {
    /// The explanatory text — the same string drives the hover tooltip (Mac) and
    /// the tap popover (both platforms).
    let text: LocalizedStringKey
    /// Plain-text mirror of `text` for the VoiceOver hover tooltip and the
    /// popover's accessibility, so assistive tech reads the full explanation.
    private let plain: String

    init(_ text: String) {
        self.text = LocalizedStringKey(text)
        self.plain = text
    }

    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                // Track Dynamic Type but stay visually quiet — a small,
                // secondary cue, never a focal point.
                .font(.footnote)
                .foregroundStyle(.secondary)
                // 44×44 hit target — the HIG / accessibility-audit minimum
                // (`.hitRegion`). The glyph stays small and centered; the
                // tappable + audited frame is the full 44pt. (Was `.padding(2)`,
                // which left a 19×19 element the audit hard-fails as "too small".)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Mac: native hover tooltip with the SAME text (no-op on touch iOS).
        .help(text)
        .accessibilityLabel("More info")
        .accessibilityHint(plain)
        .popover(isPresented: $showing, arrowEdge: .top) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
                // Readable but bounded — never a wall of text on a wide screen.
                .frame(maxWidth: 300)
                .accessibilityLabel(plain)
                // Stay a small popover bubble on compact iPhone widths instead
                // of adapting to a full sheet (iOS 26 popover behavior).
                .presentationCompactAdaptation(.popover)
        }
    }
}

extension View {
    /// Attach a cross-platform help affordance to a label/header: trails the
    /// view with a small, tappable `info.circle` (and a Mac hover tooltip) that
    /// reveals `text`. One source string serves both platforms.
    ///
    /// Use on a section header or a single control label — not on every row.
    func helpInfo(_ text: String) -> some View {
        HStack(spacing: 6) {
            self
            InfoButton(text)
        }
    }
}
