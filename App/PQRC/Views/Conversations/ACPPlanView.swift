import PQRCACP
import SwiftUI

/// The plan/TODO checklist a paired coding-agent node reports while it works
/// (Phase D1). It rides the existing relay-ACP path: the node emits a `plan`
/// session/update, `PersonaRuntime` forwards it as `RuntimeEvent.acpPlan`, and
/// `AppModel.acpPlansByConversation` holds the latest snapshot. This view renders
/// that snapshot so the user sees the agent's APPROACH (the steps it's taking),
/// not just a stream of opaque tool calls.
///
/// Display-only: every entry's `content` is AGENT output, so it gets the same
/// hygiene as an agent bubble — shown plainly, trusted no further (the node→phone
/// direction never grants the plan text any authority). A circle/checkmark tracks
/// each step's status (pending → in_progress → completed).
struct ACPPlanView: View {
    let entries: [ACPPlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Agent plan", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(for: entry.status))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Self.tint(for: entry.status))
                        .accessibilityHidden(true)
                    Text(entry.content)
                        // completed steps read as "done": dimmed + struck through,
                        // like a checked-off to-do.
                        .font(.callout)
                        .foregroundStyle(entry.status == "completed" ? .secondary : .primary)
                        .strikethrough(entry.status == "completed", color: .secondary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Self.statusLabel(for: entry.status)): \(entry.content)")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("acp-plan")
    }

    /// SF Symbol per ACP PlanEntry status (anything unknown → the pending circle).
    private static func symbol(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.lefthalf.filled"
        default: return "circle"  // pending / unknown
        }
    }

    private static func tint(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .accentColor
        default: return .secondary
        }
    }

    /// Spoken status for VoiceOver (matches the icon).
    private static func statusLabel(for status: String) -> String {
        switch status {
        case "completed": return "Completed"
        case "in_progress": return "In progress"
        default: return "Pending"
        }
    }
}
