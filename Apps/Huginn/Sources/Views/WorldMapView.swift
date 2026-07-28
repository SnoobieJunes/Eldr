// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCCore
import SwiftUI

// WS-D3 — the World MAP: towns as a village, the way goosetown draws one.
//
// **What the animation is allowed to mean.** A moving pulse on an edge reads, forcefully,
// as "traffic is flowing right now" — far more forcefully than any text label. This app
// does not have per-message events (the dashboard refreshes on demand; streaming was
// deliberately deferred), so a pulse here encodes the STATE "this channel is live" —
// i.e. the node saw traffic from this town inside `liveWindowSeconds` — and nothing
// finer. It is not one dot per message, and the legend says so. An edge that is merely
// authorized is DASHED and STILL: the visual grammar carries the same
// permission-vs-connection distinction the list makes in words, because a map is exactly
// where that distinction is easiest to lose.
//
// The lifetime ring around each town is the grant's remaining life as a fraction of the
// protocol's own hard cap (`PQRCConstants.maxStandingGrantDuration`, 30 days) — a real
// documented bound rather than an invented denominator.

/// Pure geometry + time math. No SwiftUI, no clock of its own, so every value the map
/// draws is table-testable.
enum WorldMapLayout {

    /// Unit-circle position for town `index` of `count`, starting at 12 o'clock and
    /// going clockwise. Screen coordinates (y grows downward), so 12 o'clock is -y.
    static func unitPosition(index: Int, count: Int) -> CGPoint {
        guard count > 0 else { return .zero }
        let angle = (Double(index) / Double(count)) * 2 * .pi - .pi / 2
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    /// Where that unit position lands in a concrete canvas.
    static func point(_ unit: CGPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + unit.x * radius, y: center.y + unit.y * radius)
    }

    /// Ring radius that keeps nodes and their labels inside `size`.
    static func ringRadius(in size: CGSize, inset: CGFloat = 56) -> CGFloat {
        max(10, min(size.width, size.height) / 2 - inset)
    }

    /// Fraction of the protocol's maximum grant duration still remaining, clamped 0...1.
    /// nil expiry (no live grant) is 0 — an empty ring, not a full one.
    static func lifetimeFraction(
        grantExpiry: Int64?, now: Int64,
        cap: Int64 = PQRCConstants.maxStandingGrantDuration
    ) -> Double {
        guard let grantExpiry, cap > 0 else { return 0 }
        let remaining = Double(grantExpiry - now)
        guard remaining > 0 else { return 0 }
        return min(1, remaining / Double(cap))
    }

    /// Position of the travelling pulse along an edge, 0...1, for a given time.
    /// `offset` de-phases each edge so eight towns don't pulse in lockstep.
    static func pulsePhase(time: TimeInterval, period: Double = 2.2, offset: Double = 0)
        -> Double
    {
        guard period > 0 else { return 0 }
        let t = (time / period + offset).truncatingRemainder(dividingBy: 1)
        return t < 0 ? t + 1 : t
    }

    /// Interpolate along the edge from `a` to `b`.
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

struct WorldMapView: View {
    let nodeTownID: String
    let towns: [TownStatusWire.Town]
    /// Injected so previews/tests are deterministic; production passes the wall clock.
    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }

    var body: some View {
        VStack(spacing: 8) {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    draw(
                        context: context, size: size,
                        time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(minHeight: 280)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            legend
        }
        .padding(.vertical, 8)
    }

    /// The map is a picture; VoiceOver gets the same facts in words, and the LIST view
    /// remains the fully navigable surface (the toggle never hides information).
    private var accessibilitySummary: String {
        guard !towns.isEmpty else {
            return "Town map. No paired towns."
        }
        let n = now()
        let parts = towns.map { town -> String in
            let status = WorldStatusDerivation.townStatus(town, now: n)
            return "\(town.label.isEmpty ? town.townID : town.label): \(status.label)"
        }
        return "Town map centred on \(nodeTownID). " + parts.joined(separator: ". ")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("moving = traffic seen", systemImage: "circle.fill")
                .foregroundStyle(.green)
            Label("dashed = authorized, quiet", systemImage: "minus")
                .foregroundStyle(.blue)
            Label("ring = grant life left", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func draw(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let n = now()
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = WorldMapLayout.ringRadius(in: size)

        // The centre: this node.
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26)),
            with: .color(.accentColor))
        context.draw(
            Text(nodeTownID).font(.caption.weight(.semibold)),
            at: CGPoint(x: center.x, y: center.y + 26))

        guard !towns.isEmpty else {
            context.draw(
                Text("No paired towns").font(.caption).foregroundStyle(.secondary),
                at: CGPoint(x: center.x, y: center.y - 34))
            return
        }

        for (index, town) in towns.enumerated() {
            let unit = WorldMapLayout.unitPosition(index: index, count: towns.count)
            let position = WorldMapLayout.point(unit, center: center, radius: radius)
            let status = WorldStatusDerivation.townStatus(town, now: n)

            var edge = Path()
            edge.move(to: center)
            edge.addLine(to: position)

            switch status {
            case .live:
                context.stroke(edge, with: .color(.green.opacity(0.75)), lineWidth: 2)
                // The pulse encodes the LIVE STATE, not individual messages.
                let phase = WorldMapLayout.pulsePhase(
                    time: time, offset: Double(index) / Double(max(1, towns.count)))
                let dot = WorldMapLayout.lerp(center, position, phase)
                context.fill(
                    Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)),
                    with: .color(.green))
            case .authorized:
                context.stroke(
                    edge, with: .color(.blue.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            default:
                context.stroke(
                    edge, with: .color(.secondary.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
            }

            // Grant-lifetime ring: a trailing arc, full at the 30-day protocol cap.
            let fraction = WorldMapLayout.lifetimeFraction(
                grantExpiry: town.grantExpiry, now: n)
            if fraction > 0 {
                var ring = Path()
                ring.addArc(
                    center: position, radius: 18, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
                context.stroke(ring, with: .color(status.tintForCanvas), lineWidth: 3)
            }

            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: position.x - 11, y: position.y - 11, width: 22, height: 22)),
                with: .color(status.tintForCanvas))
            context.draw(
                Text(town.label.isEmpty ? town.townID : town.label).font(.caption2),
                at: CGPoint(x: position.x, y: position.y + 28))
        }
    }
}

extension WorldStatus {
    /// Canvas needs a concrete `Color`; `tint` is the same palette the list rows use so
    /// the two views cannot disagree about what a colour means.
    var tintForCanvas: Color { tint }
}
