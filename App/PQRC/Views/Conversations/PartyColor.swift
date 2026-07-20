// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Per-party color coding for a conversation (APP-SPEC §6.2 readability pass).
///
/// Each HUMAN party gets a deterministic, pleasant SOLID color derived purely
/// from their PQRC identity hex — same identity ⇒ same color on every device,
/// no state, no storage (and nothing on the wire, so it can't leak: SPEC §0).
/// A party's tethered AI renders in a visually-RELATED variant (a lighter tint
/// of the same hue) so you can tell at a glance WHICH AI belongs to WHICH human.
///
/// Colorblind / grayscale safety (and the AI-labeling invariant, SPEC §8.2):
/// color is NEVER the only signal. AI bubbles additionally carry an outline and
/// a `sparkles` glyph + label, so an agent message is unmistakable even with no
/// color perception at all. `PartyColor` only supplies the palette; the
/// non-color affordances live in the bubble view.
enum PartyColor {
    /// A resolved party palette: the human's solid color plus the matched parts
    /// used to render their AI's bubble (a lighter fill tint and a stronger
    /// outline/label stroke of the same hue).
    struct Palette {
        /// Solid fill for the human's bubble; also the human's sender-label color.
        let solid: Color
        /// Lighter tint of `solid` for the AI bubble's FILL (so the AI reads as a
        /// faded cousin of its owner, distinct from the human's full-strength fill).
        let aiFill: Color
        /// Same-hue OUTLINE color for the AI bubble (a non-color AI signal). Only
        /// needs to be visible, not text-legible — so it stays vivid on-hue.
        let aiStroke: Color
        /// High-contrast, lightly-hue-tinted color for the AI's small LABEL text
        /// ("⟡ name") — mostly `.primary` so a caption-size label clears the
        /// contrast bar on the light `aiFill` in both schemes, just tinted enough
        /// to read as on-hue. (Caption text on a colored tint is the binding
        /// constraint; the bare hue fails it, so we lean on `.primary`.)
        let aiLabel: Color
        /// Foreground for text drawn ON `solid` (white reads on every hue here).
        let onSolid: Color = .white
    }

    // MARK: - Public API

    /// Deterministic palette for a human party from their identity hex. "Self"
    /// (the local user) passes `isSelf: true` to anchor on the app accent so
    /// "you" stays consistent with the rest of the app's outgoing styling.
    static func palette(forIdentity identityHex: String, isSelf: Bool) -> Palette {
        if isSelf {
            // "You" anchors on the app accent so my bubbles stay recognizably
            // mine, but the SOLID is the accent deepened by a fixed black mix:
            // white text on the RAW accent measures ~4.0:1 (under WCAG AA 4.5) —
            // the old "audit-approved" belief was an occlusion artifact, exposed
            // once threads showed the same bubble mid-screen. 22 % black puts the
            // default accents comfortably past 6:1 while reading as "the accent,
            // one shade deeper". The AI variants keep the undarkened accent hue.
            let base = Color.accentColor
            return Palette(
                solid: base.mix(with: .black, by: 0.22),
                aiFill: aiTint(base),
                aiStroke: aiStrokeShade(base),
                aiLabel: aiLabelShade(base))
        }
        // Everyone else: a deterministic hashed hue, luminance-darkened so its
        // solid fill guarantees white-on-solid contrast (below).
        let hsb = hashedHSB(identityHex)
        let base = Color(hue: hsb.h, saturation: hsb.s, brightness: hsb.b)
        return Palette(
            solid: solidShade(hsb),
            aiFill: aiTint(base),
            aiStroke: aiStrokeShade(base),
            aiLabel: aiLabelShade(base))
    }

    /// Just the solid party color (e.g. for a sender label or avatar dot).
    static func solid(forIdentity identityHex: String, isSelf: Bool) -> Color {
        palette(forIdentity: identityHex, isSelf: isSelf).solid
    }

    // MARK: - Deterministic hue

    private struct HSB { let h: Double; let s: Double; let b: Double }

    /// A pleasant, well-spaced base hue for a party. Hash → a stable angle on the
    /// color wheel; saturation/brightness sit in a band that's vivid enough to
    /// distinguish yet dark enough that the solid-shade step can always reach
    /// white-text contrast.
    private static func hashedHSB(_ identityHex: String) -> HSB {
        let h = stableHash(identityHex)
        // Golden-angle stepping de-clusters nearby hashes so two parties rarely
        // land on confusingly-close hues.
        let hue = Double(h % 360) / 360.0
        return HSB(h: hue, s: 0.62, b: 0.74)
    }

    /// Public base color (no contrast shaping) — handy for previews/tests.
    static func baseColor(forIdentity identityHex: String) -> Color {
        let hsb = hashedHSB(identityHex)
        return Color(hue: hsb.h, saturation: hsb.s, brightness: hsb.b)
    }

    // MARK: - Mode-aware shading
    //
    // These mirror the existing bubble approach (MessageBubble mixes toward
    // .black / .primary / system backgrounds) so results land in the same
    // contrast-audited territory. `.primary`/system colors are environment-
    // resolved, so the AI parts adapt to light vs dark automatically.

    /// The human's full-strength SOLID fill, darkened until WHITE TEXT clears the
    /// contrast bar on EVERY hue. High-luminance hues (yellow/green/cyan) are far
    /// lighter than blue at the same HSB brightness, so a flat darken isn't
    /// enough — we lower brightness until the hue's relative luminance is low
    /// enough, then build an opaque RGB color. This is the load-bearing guarantee
    /// for the white-on-solid bubble text.
    ///
    /// Target L ≤ 0.13 ⇒ contrast = 1.05/(L+0.05) ≥ ~5.8:1 vs white — safely past
    /// WCAG AA (4.5:1) with margin, while keeping the hue vivid enough that two
    /// parties stay easy to tell apart (driving it darker than this buys no real
    /// contrast and just muddies the colors). Note the platform XCUITest auditor
    /// reports a separate "indeterminate background" false-positive on incoming
    /// bubbles near the composer regardless of their actual color — that is a
    /// pre-existing artifact (it flags the neutral baseline bubbles too), not a
    /// real contrast deficit, so we optimize for genuine WCAG contrast here.
    private static func solidShade(_ hsb: HSB) -> Color {
        let target = 0.13
        var b = hsb.b
        var rgb = hsbToLinearRGB(h: hsb.h, s: hsb.s, b: b)
        // Darken in small steps until the hue is dark enough (bounded loop).
        var guardCount = 0
        while relativeLuminance(rgb) > target, b > 0.08, guardCount < 60 {
            b -= 0.025
            rgb = hsbToLinearRGB(h: hsb.h, s: hsb.s, b: b)
            guardCount += 1
        }
        let srgb = rgb.map(linearToSRGB)
        return Color(.sRGB, red: srgb[0], green: srgb[1], blue: srgb[2], opacity: 1)
    }

    /// AI FILL: a light, faded tint of the party hue. Mixing toward the system
    /// background keeps it opaque and legible in light AND dark (translucent
    /// fills fail the contrast auditor — see MessageBubble), while staying
    /// clearly the same family as the owner's solid color.
    private static func aiTint(_ base: Color) -> Color {
        base.mix(with: Color(.systemBackground), by: 0.80)
    }

    /// AI OUTLINE color: the party hue at near-full strength — it only has to be
    /// visible as the non-color "this is an AI" border, not pass text contrast.
    private static func aiStrokeShade(_ base: Color) -> Color {
        base.mix(with: .primary, by: 0.30)
    }

    /// AI LABEL color: mostly `.primary` with a hint of hue. The label is small
    /// caption text on the light `aiFill`, so it needs near-`.primary` contrast
    /// (the bare hue fails the auditor here); 25% hue keeps it visibly on-family.
    private static func aiLabelShade(_ base: Color) -> Color {
        base.mix(with: .primary, by: 0.75)
    }

    // MARK: - Color math (deterministic, device-independent)

    /// HSB → linear-light RGB (each channel 0…1, gamma-removed) so we can compute
    /// WCAG relative luminance. Pure value math — no environment, fully testable.
    private static func hsbToLinearRGB(h: Double, s: Double, b: Double) -> [Double] {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = b * (1 - s)
        let q = b * (1 - f * s)
        let t = b * (1 - (1 - f) * s)
        let srgb: [Double]
        switch i {
        case 0: srgb = [b, t, p]
        case 1: srgb = [q, b, p]
        case 2: srgb = [p, b, t]
        case 3: srgb = [p, q, b]
        case 4: srgb = [t, p, b]
        default: srgb = [b, p, q]
        }
        return srgb.map(srgbToLinear)
    }

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func relativeLuminance(_ linearRGB: [Double]) -> Double {
        0.2126 * linearRGB[0] + 0.7152 * linearRGB[1] + 0.0722 * linearRGB[2]
    }

    // MARK: - Hashing

    /// Stable FNV-1a over the identity's UTF-8 bytes → a deterministic, well-
    /// distributed integer. Independent of Swift's per-run `Hasher` seed, so the
    /// color is identical across launches and devices.
    private static func stableHash(_ s: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        // Fold to a positive Int in a comfortable range.
        return Int(hash % 0x7FFF_FFFF)
    }
}
