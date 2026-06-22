import AppKit
import SwiftUI

/// The menu-bar popover: a live status dot, the install state, and quick actions.
struct StatusBarView: View {
    @EnvironmentObject private var health: LLMHealthChecker
    @EnvironmentObject private var installer: InstallerService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                Text("Eldr node").font(.headline)
            }
            Text(healthText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(installText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("Open Eldr node") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Button("Re-check now") { Task { await recheck() } }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func recheck() async {
        await health.checkNow()
        await installer.refreshState()
    }

    private var dotColor: Color {
        switch health.result {
        case .reachable: return .green
        case .unreachable: return .red
        case .checking, .unknown: return .yellow
        }
    }

    private var healthText: String {
        switch health.result {
        case .unknown: return "LLM status unknown."
        case .checking: return "Checking the LLM…"
        case .reachable(let models):
            return models.isEmpty
                ? "LLM reachable." : "LLM reachable — \(models.count) model(s)."
        case .unreachable(let error): return "LLM unreachable: \(error)"
        }
    }

    private var installText: String {
        switch installer.state {
        case .unknown: return "Checking install…"
        case .notInstalled: return "eldr-acp is not installed."
        case .installed(let version): return "Installed: eldr-acp \(version)"
        case .updateAvailable(let bundled, let installed):
            return "Update available: \(installed) → \(bundled)"
        }
    }
}
