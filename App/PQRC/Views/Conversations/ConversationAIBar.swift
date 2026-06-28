import PQRCCore
import SwiftUI

/// Slim "AI faces" presence strip above the conversation (features 4 & 8). Shown
/// only when you have 2+ AIs tethered, so single-AI users see no new clutter. Each
/// face is one of your AIs (incl. the Mac-Tethered-AI); faces not in this chat's
/// roster are dimmed. Tapping opens the per-AI hub. Reads live per appear.
struct ConversationAIBar: View {
    @Bindable var model: AppModel
    let conversationID: String
    var threadID: String? = nil
    let onTap: () -> Void

    @State private var ais: [ConfiguredAI] = []
    @State private var roster: [String]?

    private var scopeID: String { threadID ?? conversationID }

    var body: some View {
        Group {
            if ais.count >= 2 {
                Button(action: onTap) {
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            ForEach(ais.prefix(6), id: \.id) { ai in
                                let badge = AITypeIcon.badge(kind: ai.kind, model: ai.model, name: ai.name)
                                AITypeBadgeView(symbol: badge.symbol, glyph: badge.glyph, size: 13)
                                    .opacity(isParticipating(ai.id) ? 1 : 0.3)
                            }
                        }
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation-ai-bar")
                .accessibilityLabel("AIs in this chat: \(label). Tap to configure.")
            }
        }
        .task { load() }
    }

    private var label: String {
        let count = ais.filter { isParticipating($0.id) }.count
        if roster == nil { return "\(ais.count) AIs · all replying" }
        if count == 0 { return "AIs off here" }
        return count == 1 ? "1 AI replying" : "\(count) AIs · in order"
    }

    private func isParticipating(_ id: String) -> Bool {
        guard let roster else { return true }  // nil = all participate
        return roster.contains(id)
    }

    private func load() {
        ais = model.tetheredAIList().filter(\.isEnabled)
        roster = model.conversationAIRoster(scopeID)
    }
}
