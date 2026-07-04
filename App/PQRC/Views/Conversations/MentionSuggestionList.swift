import SwiftUI

/// @-mention autocomplete shown above the composer (feature 6). Lists matching
/// candidates — your AIs, the people in the chat, and their AIs — and inserts
/// "@name " when tapped. A convenience over typing the name; the engine resolves
/// the mention on send either way.
struct MentionSuggestionList: View {
    let suggestions: [MentionSuggestion]
    let onPick: (MentionSuggestion) -> Void

    struct MentionSuggestion: Identifiable, Equatable {
        var id: String { kind + "|" + name }
        let name: String
        let kind: String  // "ai" | "person"
    }

    var body: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { s in
                        Button { onPick(s) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: s.kind == "ai" ? "sparkles" : "person.fill")
                                    .font(.caption2)
                                    .foregroundStyle(s.kind == "ai" ? Color.purple : .secondary)
                                Text("@\(s.name)").font(.caption.weight(.medium)).foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mention-suggestion-\(s.name)")
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 36)
            .accessibilityIdentifier("mention-suggestions")
        }
    }
}
