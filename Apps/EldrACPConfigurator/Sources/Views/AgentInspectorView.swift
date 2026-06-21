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
        HStack(spacing: 8) {
            Picker("Filter", selection: $filter) {
                Text("All").tag(DiagnosticsLog.Category?.none)
                ForEach(DiagnosticsLog.Category.allCases) { cat in
                    Label(cat.rawValue, systemImage: cat.symbol).tag(DiagnosticsLog.Category?.some(cat))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer()
            Text("\(shown.count) event\(shown.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                log.clear(); expanded.removeAll()
            } label: { Label("Clear", systemImage: "trash") }
                .disabled(log.events.isEmpty)
        }
        .padding(8)
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
