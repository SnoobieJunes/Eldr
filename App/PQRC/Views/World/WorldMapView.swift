// SPDX-License-Identifier: AGPL-3.0-only
import PQRCCore
import SwiftUI

// WS-D3 (phone) — the same village, drawn honestly for a device that cannot see traffic.
//
// **The phone's map animates something DIFFERENT from the Mac's, on purpose.** On the
// Mac, a pulse travels an edge to encode "the node has seen traffic from this town". The
// phone has no such fact — town liveness lives in the node's memory on the Mac — so it
// draws NO travelling pulses at all. Every edge is dashed and still.
//
// What it animates instead is the thing the phone knows exactly: the GRANT CLOCK. Each
// town carries a lifetime ring, and a grant inside its final day breathes. That is a real
// fact this device owns (it signed the grant and holds its expiry), so animating it
// misleads no one — whereas a moving pulse would assert a connection the phone cannot
// verify. Same visual language, strictly weaker claims.

/// Pure geometry + time math, mirroring the Mac's `WorldMapLayout`. Duplicated rather
/// than shared because the two apps have no common module (see `PhoneWorldDerivation`).
enum PhoneWorldMapLayout {

    /// Unit-circle position, 12 o'clock start, clockwise (screen y grows downward).
    static func unitPosition(index: Int, count: Int) -> CGPoint {
        guard count > 0 else { return .zero }
        let angle = (Double(index) / Double(count)) * 2 * .pi - .pi / 2
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    static func point(_ unit: CGPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + unit.x * radius, y: center.y + unit.y * radius)
    }

    static func ringRadius(in size: CGSize, inset: CGFloat = 52) -> CGFloat {
        max(10, min(size.width, size.height) / 2 - inset)
    }

    /// Remaining grant life as a fraction of the protocol's hard cap, clamped 0...1.
    static func lifetimeFraction(
        expiresAt: Int64?, now: Int64, cap: Int64 = PQRCConstants.maxStandingGrantDuration
    ) -> Double {
        guard let expiresAt, cap > 0 else { return 0 }
        let remaining = Double(expiresAt - now)
        guard remaining > 0 else { return 0 }
        return min(1, remaining / Double(cap))
    }

    /// A 0...1 breathing value for grants near expiry. Static (0.5) when not urgent, so
    /// nothing on this map moves unless it is genuinely time-critical.
    static func breath(time: TimeInterval, urgent: Bool, period: Double = 1.6) -> Double {
        guard urgent, period > 0 else { return 0.5 }
        return (sin(time / period * 2 * .pi) + 1) / 2
    }
}

struct PhoneWorldMapView: View {
    let rows: [PhoneTownRow]
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
            .frame(height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            Text("Dashed everywhere: this phone can see what you authorized, not whether a town is connected. Your Mac shows live traffic.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var accessibilitySummary: String {
        guard !rows.isEmpty else { return "Town map. No towns authorized." }
        return "Town map. "
            + rows.map { "\($0.title): \($0.status.label)" }.joined(separator: ". ")
    }

    private func draw(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let n = now()
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = PhoneWorldMapLayout.ringRadius(in: size)

        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)),
            with: .color(.accentColor))
        context.draw(
            Text("you").font(.caption2.weight(.semibold)),
            at: CGPoint(x: center.x, y: center.y + 24))

        guard !rows.isEmpty else {
            context.draw(
                Text("Nothing authorized yet").font(.caption).foregroundStyle(.secondary),
                at: CGPoint(x: center.x, y: center.y - 32))
            return
        }

        for (index, row) in rows.enumerated() {
            let unit = PhoneWorldMapLayout.unitPosition(index: index, count: rows.count)
            let position = PhoneWorldMapLayout.point(unit, center: center, radius: radius)

            // ALWAYS dashed, never a solid or animated edge: the phone is not entitled
            // to draw a connection.
            var edge = Path()
            edge.move(to: center)
            edge.addLine(to: position)
            context.stroke(
                edge, with: .color(row.status.tint.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))

            let expiry: Int64? =
                switch row.status {
                case .authorized(let until), .expiringSoon(let until): until
                case .expired: nil
                }
            let fraction = PhoneWorldMapLayout.lifetimeFraction(expiresAt: expiry, now: n)
            let urgent = if case .expiringSoon = row.status { true } else { false }
            let breath = PhoneWorldMapLayout.breath(time: time, urgent: urgent)

            if fraction > 0 {
                var ring = Path()
                ring.addArc(
                    center: position, radius: 17, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
                context.stroke(
                    ring, with: .color(row.status.tint.opacity(0.5 + 0.5 * breath)),
                    lineWidth: 3)
            }

            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: position.x - 10, y: position.y - 10, width: 20, height: 20)),
                with: .color(row.status.tint))
            context.draw(
                Text(row.title).font(.system(size: 9, design: .monospaced)),
                at: CGPoint(x: position.x, y: position.y + 26))
        }
    }
}
