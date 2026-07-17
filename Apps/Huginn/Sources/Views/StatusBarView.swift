import AppKit
import SwiftUI

/// The menu-bar popover: a live status dot, the install state, and quick actions.
struct StatusBarView: View {
    @EnvironmentObject private var health: LLMHealthChecker
    @EnvironmentObject private var installer: InstallerService
    // WS-B3: tether state (`relayACPServing`) + the two pending-approval surfaces —
    // all app-level @StateObjects shared from HuginnApp so this SEPARATE scene (the
    // menu bar isn't a descendant of the main window) sees the same live state.
    @EnvironmentObject private var bridge: ACPBridgeService
    @EnvironmentObject private var a2aHost: A2AServerHost
    @EnvironmentObject private var testChatSession: TestChatSession

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

            tetherRow
            if pendingApprovalCount > 0 {
                pendingApprovalRow
            }

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

    /// WS-B3: `relayACPServing` — whether the phone's remote-drive session (the full
    /// ACP protocol served over the relay) is live right now.
    private var tetherRow: some View {
        HStack(spacing: 8) {
            Image(systemName: bridge.relayACPServing ? "cable.connector" : "cable.connector.slash")
                .foregroundStyle(bridge.relayACPServing ? .green : .secondary)
            Text(bridge.relayACPServing ? "Tethered to your phone" : "Not tethered")
                .font(.callout)
            Spacer()
        }
    }

    /// WS-B3: pending approvals from BOTH gates — the A2A server's per-task gate and
    /// Test Chat's per-tool-call gate. Each auto-denies after 120s if nobody answers;
    /// this badge (plus the `PendingApprovalNotifier` OS notification) is what makes
    /// that visible when Huginn's window isn't the thing you're looking at.
    private var pendingApprovalCount: Int {
        a2aHost.pendingApprovals.count + testChatSession.pendingApprovals.count
    }

    private var pendingApprovalRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            Text("\(pendingApprovalCount) approval\(pendingApprovalCount == 1 ? "" : "s") pending")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Spacer()
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
