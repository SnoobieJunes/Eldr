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
    /// Toggles the "Add to AI Context" marker (Feature 3). nil hides the action.
    var onToggleAIContext: (() -> Void)? = nil
    /// Opens this message's markdown/HTML in the full-screen reader. nil hides it.
    var onFullScreen: ((String) -> Void)? = nil

    /// Whether this message has document structure worth opening full screen.
    private var isRich: Bool { MessageContent.isRich(message.text) }

    var body: some View {
        if message.localStatus == "violation" {
            violationRow
        } else if message.localStatus == "system" {
            // Window starts, group/thread creation, roster changes (APP-SPEC
            // §6.2): neutral centered rows, never message bubbles.
            SystemRow(text: "\(isMine ? "You" : senderName) \(message.text)")
                .id(message.id)
        } else if message.participantType == .agent {
            agentBubble.contextMenu { bubbleMenu }
        } else {
            humanBubble.contextMenu { bubbleMenu }
        }
    }

    /// Long-press menu: full-screen (for rich content) + AI-context toggle.
    @ViewBuilder private var bubbleMenu: some View {
        fullScreenMenuItem
        aiContextMenuItem
    }

    /// "View full screen" — only for markdown/HTML messages.
    @ViewBuilder private var fullScreenMenuItem: some View {
        if isRich, let onFullScreen {
            Button {
                onFullScreen(message.text)
            } label: {
                Label("View full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
    }

    /// Small expand glyph shown on rich bubbles for discoverability.
    @ViewBuilder private var expandButton: some View {
        if isRich, let onFullScreen {
            Button {
                onFullScreen(message.text)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View full screen")
            .accessibilityIdentifier("expand-message")
        }
    }

    /// Accessibility labels must stay short: a very large message (e.g. a
    /// chunked multi-hundred-KB paste) would otherwise put its entire body into
    /// the accessibility tree, making every VoiceOver/XCUITest traversal of the
    /// conversation crawl. The visual bubble still shows the full text; only the
    /// spoken/queried label is bounded.
    static func accessibleText(_ text: String, limit: Int = 240) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit) + "… (long message)"
    }

    /// Long-press menu entry for marking a message as AI context.
    @ViewBuilder private var aiContextMenuItem: some View {
        if let onToggleAIContext {
            Button {
                onToggleAIContext()
            } label: {
                Label(
                    message.aiContext ? "Remove from AI Context" : "Add to AI Context",
                    systemImage: message.aiContext ? "brain.head.profile" : "brain")
            }
        }
    }

    /// Small marker shown on messages flagged for AI context.
    @ViewBuilder private var aiContextBadge: some View {
        if message.aiContext {
            Image(systemName: "brain")
                .font(.caption2)
                .foregroundStyle(.purple)
                .accessibilityLabel("Marked as AI context")
        }
    }

    /// iMessage-style bubble (iOS 26): continuous corners, gradient tint for
    /// outgoing. Backgrounds stay opaque — translucent materials under busy
    /// content fail the contrast audit.
    private var humanBubble: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                MessageContent(text: message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        isMine
                            // Gradient runs darker, never lighter: the accent
                            // asset is already the darkest white-text-safe
                            // shade the audit accepts (A7).
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.mix(with: .black, by: 0.18)],
                                    startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .foregroundStyle(isMine ? .white : .primary)
                HStack(spacing: 6) {
                    aiContextBadge
                    expandButton
                    if isMine {
                        // Local-only status; copy says "sent to relay", never "delivered" (D5).
                        // .secondary (not .tertiary): keeps the contrast audit green.
                        Text(message.localStatus == "queued" ? "Queued" : "Sent to relay")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .id(message.id)
        .privacySensitive()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine ? "You" : senderName): \(Self.accessibleText(message.text))")
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
                HStack(spacing: 6) {
                    Label("⟡ \(senderName)'s AI", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(agentAccent)
                    expandButton
                }
                HStack(alignment: .top, spacing: 6) {
                    if message.isContext {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(agentAccent)
                            .accessibilityLabel("Context contribution")
                    }
                    MessageContent(text: message.text)
                    aiContextBadge
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                // Opaque purple-tinted fill (visually identical to the old
                // 6% overlay): translucent fills give the contrast auditor no
                // determinable background when rows overlap bars (A7).
                .background(
                    Color.purple.mix(with: Color(.systemBackground), by: 0.94),
                    in: RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.purple.opacity(0.6), lineWidth: 1.5))
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .id(message.id)
        .privacySensitive()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AI message from \(senderName)'s assistant: \(Self.accessibleText(message.text))")
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

/// Neutral centered system row (ai_window start/expiry, roster changes,
/// anchors). The opaque capsule is load-bearing for the accessibility audit:
/// bare text near the glass header gives the contrast auditor no determinable
/// background and it hard-fails regardless of the actual color (A7) — the
/// same opaque fill incoming bubbles use keeps it green in both schemes.
struct SystemRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.gray.mix(with: .primary, by: 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
    }
}
