// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Foundation
import PQRCCore
import Testing

@testable import Huginn

/// WS-D3 — the map's geometry and time math. A drawing bug is silent (the canvas simply
/// looks wrong), so the arithmetic behind every dot, arc and pulse is pinned here.
@Suite("World map — layout and animation math")
struct WorldMapLayoutTests {

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
        abs(a - b) <= tol
    }

    // MARK: - Radial layout

    /// The first town sits at 12 o'clock, and the ring runs clockwise in SCREEN
    /// coordinates (y grows downward), which is what makes the drawing match the labels.
    @Test func firstTownIsAtTwelveOClockAndTheRingRunsClockwise() {
        let top = WorldMapLayout.unitPosition(index: 0, count: 4)
        #expect(approx(top.x, 0))
        #expect(approx(top.y, -1), "12 o'clock is -y in screen coordinates")

        let right = WorldMapLayout.unitPosition(index: 1, count: 4)
        #expect(approx(right.x, 1))
        #expect(approx(right.y, 0), "the next town is at 3 o'clock — clockwise")

        let bottom = WorldMapLayout.unitPosition(index: 2, count: 4)
        #expect(approx(bottom.x, 0))
        #expect(approx(bottom.y, 1))
    }

    /// Every position is on the unit circle, for any town count up to the pairwise
    /// fan-out cap (`maxTownPeers` = 8) — so no node can be drawn off its ring.
    @Test func everyPositionIsOnTheUnitCircleForEveryValidCount() {
        for count in 1...8 {
            for index in 0..<count {
                let p = WorldMapLayout.unitPosition(index: index, count: count)
                #expect(
                    approx(p.x * p.x + p.y * p.y, 1, 1e-12),
                    "count=\(count) index=\(index) left the unit circle")
            }
        }
    }

    /// Distinct towns get distinct positions — otherwise two towns overlap into one dot
    /// and the map silently under-reports.
    @Test func distinctTownsGetDistinctPositions() {
        for count in 2...8 {
            var seen: [CGPoint] = []
            for index in 0..<count {
                let p = WorldMapLayout.unitPosition(index: index, count: count)
                #expect(
                    !seen.contains(where: { approx($0.x, p.x, 1e-9) && approx($0.y, p.y, 1e-9) }),
                    "count=\(count) produced a duplicate position")
                seen.append(p)
            }
        }
    }

    /// Zero towns must not divide by zero.
    @Test func emptyRingIsSafe() {
        #expect(WorldMapLayout.unitPosition(index: 0, count: 0) == .zero)
    }

    /// The ring must stay inside the canvas, and never invert on a tiny one.
    @Test func ringRadiusStaysInsideTheCanvasAndNeverGoesNegative() {
        // Fixed to the SHORTER side, so a wide pane doesn't push nodes off the top.
        let r = WorldMapLayout.ringRadius(in: CGSize(width: 400, height: 300), inset: 56)
        #expect(approx(Double(r), 94), "half of the short side (300), less the inset")
        // A pane smaller than the inset would otherwise produce a negative radius and
        // mirror the whole map through the centre.
        #expect(WorldMapLayout.ringRadius(in: CGSize(width: 20, height: 20), inset: 56) >= 10)
    }

    // MARK: - Grant-lifetime ring

    /// The ring is remaining life over the protocol's OWN hard cap (30 days), not an
    /// invented denominator — full at the cap, empty at expiry, never outside 0...1.
    @Test func lifetimeFractionIsClampedAgainstTheProtocolCap() {
        let now: Int64 = 1_800_000_000
        let cap = PQRCConstants.maxStandingGrantDuration
        #expect(WorldMapLayout.lifetimeFraction(grantExpiry: now + cap, now: now) == 1)
        #expect(
            approx(
                WorldMapLayout.lifetimeFraction(grantExpiry: now + cap / 2, now: now), 0.5, 1e-9))
        // Past expiry, and exactly at it, read as empty — never as a full ring.
        #expect(WorldMapLayout.lifetimeFraction(grantExpiry: now, now: now) == 0)
        #expect(WorldMapLayout.lifetimeFraction(grantExpiry: now - 1, now: now) == 0)
        // A grant longer than the cap (the engine refuses these) still clamps to 1.
        #expect(WorldMapLayout.lifetimeFraction(grantExpiry: now + cap * 10, now: now) == 1)
        // No live grant is an EMPTY ring, not a full one.
        #expect(WorldMapLayout.lifetimeFraction(grantExpiry: nil, now: now) == 0)
    }

    // MARK: - Pulse

    /// The pulse cycles 0→1 and stays in range for any time value, including negative
    /// ones (`timeIntervalSinceReferenceDate` is negative before 2001).
    @Test func pulsePhaseStaysInRangeAndCycles() {
        for t in stride(from: -10.0, through: 10.0, by: 0.37) {
            let p = WorldMapLayout.pulsePhase(time: t)
            #expect(p >= 0 && p < 1, "phase escaped 0..<1 at t=\(t): \(p)")
        }
        #expect(approx(WorldMapLayout.pulsePhase(time: 0, period: 2), 0))
        #expect(approx(WorldMapLayout.pulsePhase(time: 1, period: 2), 0.5))
        // One full period returns to the start.
        #expect(approx(WorldMapLayout.pulsePhase(time: 2, period: 2), 0, 1e-9))
        // A zero period must not divide by zero.
        #expect(WorldMapLayout.pulsePhase(time: 5, period: 0) == 0)
    }

    /// Edges are de-phased so eight towns don't pulse in lockstep (which would read as
    /// one synchronised heartbeat rather than independent channels).
    @Test func edgesAreDePhasedFromEachOther() {
        let a = WorldMapLayout.pulsePhase(time: 0, offset: 0)
        let b = WorldMapLayout.pulsePhase(time: 0, offset: 0.25)
        #expect(!approx(a, b), "adjacent edges must not pulse in lockstep")
    }

    /// Interpolation hits both endpoints exactly, so a pulse starts at the node and
    /// finishes at the town rather than drifting off the line.
    @Test func lerpHitsBothEndpointsExactly() {
        let a = CGPoint(x: 10, y: 20)
        let b = CGPoint(x: 110, y: 220)
        #expect(WorldMapLayout.lerp(a, b, 0) == a)
        #expect(WorldMapLayout.lerp(a, b, 1) == b)
        let mid = WorldMapLayout.lerp(a, b, 0.5)
        #expect(approx(mid.x, 60) && approx(mid.y, 120))
    }
}
