// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Inline, NON-blocking permission approval (feature 9 — "fix the permission
/// prompting"). Replaces the modal alert: a paired Mac coding-agent node's mutating
/// tool request (write / edit / run) appears as a card you can act on WITHOUT the
/// rest of the app freezing, with a "+N more" indicator when several queue (the old
/// alert showed only the first and hid the backlog). The node's own 120 s C-1
/// timeout still denies if ignored — fail-closed; this is the affordance, not the
/// brake.
struct ACPApprovalCard: View {
    @Bindable var model: AppModel

    var body: some View {
        if let request = model.acpPermissions.pending.first {
            let backlog = model.acpPermissions.pending.count - 1
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: kindIcon(request.kind))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("\(model.contactNames[request.nodeHex] ?? "Your Mac agent") wants to:")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 6)
                    if backlog > 0 {
                        Text("+\(backlog) more")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemBackground), in: Capsule())
                            .accessibilityLabel("\(backlog) more request\(backlog == 1 ? "" : "s") waiting")
                    }
                }
                Text(request.title)
                    .font(.callout.monospaced())
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Deny", role: .destructive) {
                        model.acpPermissions.resolve(id: request.id, .deny)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("acp-approve-deny")
                    Spacer(minLength: 8)
                    Button("Allow once") {
                        model.acpPermissions.resolve(id: request.id, .allowOnce)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("acp-approve-once")
                    Button("Always") {
                        model.acpPermissions.resolve(id: request.id, .allowAlways)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("acp-approve-always")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.orange.opacity(0.5), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("acp-approval-card")
        }
    }

    private func kindIcon(_ kind: String) -> String {
        switch kind {
        case "edit": return "pencil"
        case "execute": return "terminal"
        default: return "exclamationmark.triangle"
        }
    }
}
