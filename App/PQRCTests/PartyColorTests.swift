// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import Testing
import UIKit

@testable import EldrChat

// The PartyColor unit coverage TEST-PLAN §13 asked for: determinism (same hex ⇒
// same color, across instances and traits) and the WCAG white-on-solid contrast
// guarantee — measured on the RESOLVED colors, the same numbers the platform
// accessibility auditor sees, in both light and dark.
@Suite("PartyColor — determinism + WCAG contrast (TEST-PLAN §13)")
struct PartyColorTests {

    // MARK: WCAG math over resolved UIKit colors

    private func linear(_ c: CGFloat) -> Double {
        let v = Double(c)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func resolved(_ color: Color, dark: Bool) -> UIColor {
        UIColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
    }

    // MARK: Determinism

    @Test func sameIdentity_sameColor_differentIdentitiesDiffer() {
        let a1 = PartyColor.solid(forIdentity: "ab12cd34", isSelf: false)
        let a2 = PartyColor.solid(forIdentity: "ab12cd34", isSelf: false)
        let b = PartyColor.solid(forIdentity: "ff00ff00", isSelf: false)
        #expect(
            resolved(a1, dark: false) == resolved(a2, dark: false),
            "same identity hex resolves to the same color on every call")
        #expect(
            resolved(a1, dark: false) != resolved(b, dark: false),
            "distinct identities land on distinct colors (these two hashes differ)")
    }

    // MARK: White-on-solid guarantee (peers AND self), light + dark

    /// A spread of identity hexes covering the hue wheel (golden-angle hashing
    /// makes any decent sample representative), plus the self palette.
    @Test(arguments: [false, true])
    func whiteOnSolid_clearsWCAGAA(dark: Bool) {
        let white = UIColor.white
        for seed in 0..<24 {
            let hex = String(repeating: String(format: "%02x", seed * 11 % 256), count: 8)
            let solid = resolved(
                PartyColor.solid(forIdentity: hex, isSelf: false), dark: dark)
            let ratio = contrast(solid, white)
            #expect(
                ratio >= 4.5,
                "peer solid for \(hex) (dark=\(dark)) must clear AA, measured \(ratio)")
        }
        let selfSolid = resolved(
            PartyColor.solid(forIdentity: "irrelevant", isSelf: true), dark: dark)
        let selfRatio = contrast(selfSolid, white)
        #expect(
            selfRatio >= 4.5,
            "SELF solid (accent-anchored, dark=\(dark)) must clear AA, measured \(selfRatio)")
    }

    /// The agent bubble pair: `.primary`-equivalent label/body text on the light
    /// `aiFill` wash must clear AA for body text in both schemes.
    @Test(arguments: [false, true])
    func primaryTextOnAIFill_clearsWCAGAA(dark: Bool) {
        let text = UIColor.label.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        for hex in ["ab12cd34", "00ff0011", "deadbeef"] {
            let palette = PartyColor.palette(forIdentity: hex, isSelf: false)
            let fill = resolved(palette.aiFill, dark: dark)
            let ratio = contrast(fill, text)
            #expect(
                ratio >= 4.5,
                "primary-on-aiFill for \(hex) (dark=\(dark)) measured \(ratio)")
        }
    }
}
