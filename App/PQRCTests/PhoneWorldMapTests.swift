// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Foundation
import PQRCAgent
import PQRCCore
import Testing

@testable import EldrChat

/// WS-D3 (phone) — the map's geometry, its animation, and the property that makes it
/// safe to ship: the phone's map cannot express a connection.
@Suite("World map — phone geometry and honest animation")
struct PhoneWorldMapTests {

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
        abs(a - b) <= tol
    }

    // MARK: - THE property: no "connected" is representable

    /// The phone cannot observe town liveness, so `PhoneGrantStatus` has no `connected`
    /// case at all — the claim is unrepresentable rather than merely unused. This test is
    /// the tripwire: if someone adds one, the exhaustive switch below stops compiling,
    /// and the label assertion catches a "connected"-flavoured string sneaking in.
    @Test func phoneStatusVocabularyCannotClaimAConnection() {
        let all: [PhoneGrantStatus] = [
            .authorized(until: 1), .expiringSoon(until: 1), .expired,
        ]
        for status in all {
            // Exhaustive: adding a case breaks this switch at compile time.
            let label: String =
                switch status {
                case .authorized: "authorized"
                case .expiringSoon: "expiring soon"
                case .expired: "expired"
                }
            #expect(status.label == label)
            let lowered = status.label.lowercased()
            #expect(!lowered.contains("connect"), "the phone must never claim a connection")
            #expect(!lowered.contains("live"))
            #expect(!lowered.contains("online"))
        }
    }

    // MARK: - Geometry (parity with the Mac's layout)

    @Test func layoutMatchesTheMacsRadialConvention() {
        let top = PhoneWorldMapLayout.unitPosition(index: 0, count: 4)
        #expect(approx(top.x, 0))
        #expect(approx(top.y, -1), "12 o'clock is -y in screen coordinates")

        let right = PhoneWorldMapLayout.unitPosition(index: 1, count: 4)
        #expect(approx(right.x, 1))
        #expect(approx(right.y, 0), "clockwise, same as the Mac")

        for count in 1...8 {
            for index in 0..<count {
                let p = PhoneWorldMapLayout.unitPosition(index: index, count: count)
                #expect(approx(p.x * p.x + p.y * p.y, 1, 1e-12))
            }
        }
        #expect(PhoneWorldMapLayout.unitPosition(index: 0, count: 0) == .zero)
    }

    @Test func ringRadiusNeverInvertsOnASmallScreen() {
        // An iPhone in landscape with a keyboard up can get very short panes.
        #expect(PhoneWorldMapLayout.ringRadius(in: CGSize(width: 40, height: 40)) >= 10)
        #expect(
            approx(
                Double(PhoneWorldMapLayout.ringRadius(in: CGSize(width: 400, height: 300), inset: 52)),
                98))
    }

    // MARK: - Grant clock

    @Test func lifetimeFractionIsClampedAgainstTheProtocolCap() {
        let now: Int64 = 1_800_000_000
        let cap = PQRCConstants.maxStandingGrantDuration
        #expect(PhoneWorldMapLayout.lifetimeFraction(expiresAt: now + cap, now: now) == 1)
        #expect(PhoneWorldMapLayout.lifetimeFraction(expiresAt: now + cap * 5, now: now) == 1)
        #expect(PhoneWorldMapLayout.lifetimeFraction(expiresAt: now, now: now) == 0)
        #expect(PhoneWorldMapLayout.lifetimeFraction(expiresAt: nil, now: now) == 0)
        #expect(
            approx(
                PhoneWorldMapLayout.lifetimeFraction(expiresAt: now + cap / 4, now: now), 0.25,
                1e-9))
    }

    // MARK: - Animation

    /// Nothing on the phone's map moves unless it is genuinely time-critical: a
    /// non-urgent grant is a STILL ring. Motion that means nothing is motion that
    /// teaches the eye to ignore motion that does.
    @Test func onlyExpiringGrantsAnimate() {
        for t in stride(from: 0.0, through: 6.0, by: 0.31) {
            #expect(
                PhoneWorldMapLayout.breath(time: t, urgent: false) == 0.5,
                "a healthy grant must not breathe")
        }
        var seen = Set<String>()
        for t in stride(from: 0.0, through: 3.2, by: 0.1) {
            let b = PhoneWorldMapLayout.breath(time: t, urgent: true)
            #expect(b >= 0 && b <= 1, "breath escaped 0...1 at t=\(t): \(b)")
            seen.insert(String(format: "%.2f", b))
        }
        #expect(seen.count > 5, "an expiring grant must actually animate, not sit still")
    }

    /// A zero period must not divide by zero (a guard, not a scenario).
    @Test func degenerateBreathPeriodIsSafe() {
        #expect(PhoneWorldMapLayout.breath(time: 5, urgent: true, period: 0) == 0.5)
    }
}
