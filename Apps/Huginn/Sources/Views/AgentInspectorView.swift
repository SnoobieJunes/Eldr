// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Live view of what the node is actually doing — every LLM round-trip (with latency
/// and an explicit flag when a reasoning model returns an empty answer), tool calls, and
/// node/relay lifecycle events. This is the diagnostic the project kept wishing it had:
/// it makes "the LLM isn't responding / nothing is recorded" legible at a glance.
struct AgentInspectorView: View {
    @ObservedObject private var log = DiagnosticsLog.shared
    @State private var filter: DiagnosticsLog.Category?
    @State private var expanded: Set<UUID> = []

    private var shown: [DiagnosticsLog.Event] {
        guard let filter else { return log.events }
        return log.events.filter { $0.category == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if shown.isEmpty {
                ContentUnavailableView {
                    Label("No agent activity yet", systemImage: "scope")
                } description: {
                    Text(
                        "Send a message in Test Chat, or drive the agent from your phone. "
                            + "Each LLM request/response, tool call, and node event appears here live. "
                            + "An empty/red “EMPTY answer” row means the model returned only reasoning — "
                            + "switch to an instruct model.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                eventList
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            filterChips
            HStack(spacing: 8) {
                Spacer()
                Text("\(shown.count) event\(shown.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    log.clear(); expanded.removeAll()
                } label: { Label("Clear", systemImage: "trash") }
                    .disabled(log.events.isEmpty)
            }
        }
        .padding(8)
    }

    /// Horizontal filter chips (replaces the old segmented-control picker) — scrolls
    /// instead of squeezing labels as categories grow (WS-B2 added `.relay`, a fifth).
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(title: "All", symbol: "tray.full", isSelected: filter == nil) {
                    filter = nil
                }
                ForEach(DiagnosticsLog.Category.allCases) { cat in
                    filterChip(title: cat.rawValue, symbol: cat.symbol, isSelected: filter == cat) {
                        filter = cat
                    }
                }
            }
        }
    }

    private func filterChip(
        title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
        )
        .overlay(Capsule().stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1))
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
    }

    private var eventList: some View {
        ScrollViewReader { proxy in
            List(shown) { event in
                row(event)
                    .id(event.id)
                    .listRowSeparator(.visible)
            }
            .listStyle(.inset)
            .onChange(of: log.events.count) { _, _ in
                if let last = shown.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ e: DiagnosticsLog.Event) -> some View {
        let isOpen = expanded.contains(e.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: e.category.symbol)
                    .foregroundStyle(e.severity.color)
                    .frame(width: 18)
                Text(e.title).font(.callout).fontWeight(.medium)
                    .foregroundStyle(e.severity == .error ? e.severity.color : .primary)
                Spacer()
                Text(e.at, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !e.detail.isEmpty {
                Text(e.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isOpen ? nil : 2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen { expanded.remove(e.id) } else { expanded.insert(e.id) }
        }
    }
}
