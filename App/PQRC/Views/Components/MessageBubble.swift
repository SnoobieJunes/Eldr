import PQRCCore
import SwiftUI

/// Bubble rendering (APP-SPEC §6.2). Agent messages are unmistakably distinct
/// — tinted outline + sparkles badge + caption — and the styling survives
/// grayscale (shape + badge, never color alone). A protocol violation renders
/// as a red system row, never as a message.
struct MessageBubble: View {
    let message: StoredMessage
    let isMine: Bool
    let senderName: String

    var body: some View {
        if message.localStatus == "violation" {
            violationRow
        } else if message.participantType == .agent {
            agentBubble
        } else {
            humanBubble
        }
    }

    private var humanBubble: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(isMine ? .white : .primary)
                if isMine {
                    // Local-only status; copy says "sent to relay", never "delivered" (D5).
                    // .secondary (not .tertiary): keeps the contrast audit green.
                    Text(message.localStatus == "queued" ? "Queued" : "Sent to relay")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .id(message.id)
        .privacySensitive()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine ? "You" : senderName): \(message.text)")
    }

    /// Agent accent darkened for small-text contrast (≥ 4.5:1 on both schemes;
    /// the audit fails plain system purple at caption sizes).
    private var agentAccent: Color {
        Color.purple.mix(with: .primary, by: 0.45)
    }

    private var agentBubble: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                Label("⟡ \(senderName)'s AI", systemImage: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(agentAccent)
                HStack(alignment: .top, spacing: 6) {
                    if message.isContext {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(agentAccent)
                            .accessibilityLabel("Context contribution")
                    }
                    Text(message.text)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.purple.opacity(0.6), lineWidth: 1.5))
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .id(message.id)
        .privacySensitive()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI message from \(senderName)'s assistant: \(message.text)")
        .accessibilityIdentifier("agent-bubble")
    }

    private var violationRow: some View {
        Label(message.text, systemImage: "exclamationmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .id(message.id)
            .accessibilityIdentifier("protocol-violation-row")
    }
}

/// Neutral centered system row (ai_window start/expiry, roster changes, anchors).
struct SystemRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}
