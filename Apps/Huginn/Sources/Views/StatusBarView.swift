// SPDX-License-Identifier: AGPL-3.0-only
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
    /// WS-M1: the model-server row. Observing the shared service here also means
    /// it exists (and its health monitor runs) from app launch, so a
    /// launchd-managed server shows live status without ever opening the MLX tab.
    @ObservedObject private var mlx = MLXService.shared

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

            MLXMenuBarSection(
                service: mlx,
                managed: mlx.managesServer,
                model: mlx.serverConfig.model,
                serverState: mlx.serverState,
                probeStatus: mlx.probeStatus,
                autostart: mlx.autostartEnabled,
                swapWorking: mlx.brainSwap.isWorking)

            Divider()

            Text(installText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("Open Eldr node") { Self.activateMainWindow() }
            Button("Re-check now") { Task { await recheck() } }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Bring the (single) main window to the front — shared by "Open Eldr node"
    /// and the MLX row's tab jump.
    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
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

/// WS-M1 menu-bar server controls: status dot + model, Start/Stop, and a jump
/// to the MLX tab — an Equatable child so job-log churn on the service can't
/// re-lay-out the popover while it's open.
private struct MLXMenuBarSection: View, Equatable {
    let service: MLXService
    let managed: Bool
    let model: String
    let serverState: MLXService.ServerState
    let probeStatus: LLMHealthChecker.HealthResult
    let autostart: Bool
    let swapWorking: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.managed == rhs.managed && lhs.model == rhs.model
            && lhs.serverState == rhs.serverState && lhs.probeStatus == rhs.probeStatus
            && lhs.autostart == rhs.autostart && lhs.swapWorking == rhs.swapWorking
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText).font(.callout)
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        HStack(spacing: 8) {
            if managed {
                Button(startTitle) {
                    Task {
                        // The menu bar can be the first UI touched after launch —
                        // the env probe may not have run yet.
                        if !service.envState.isReady { await service.refreshEnvironment() }
                        service.startServer()
                    }
                }
                .disabled(model.isEmpty || swapWorking)
                Button("Stop") { service.stopServer() }
                    .disabled(!stoppable || swapWorking)
            }
            Spacer()
            Button("MLX tab") {
                StatusBarView.activateMainWindow()
                NotificationCenter.default.post(
                    name: MainWindow.openTab, object: MainWindow.Tab.mlx)
            }
        }
        .controlSize(.small)
    }

    private var titleText: String {
        guard managed else { return "Model server: external" }
        return model.isEmpty ? "MLX server — no model set" : shortModel
    }

    /// "mlx-community/Qwen3-4B-4bit" → "Qwen3-4B-4bit" (the popover is 320 pt).
    private var shortModel: String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    private var stoppable: Bool {
        if autostart { return true }
        switch serverState {
        case .starting, .running: return true
        default: return false
        }
    }

    private var startTitle: String {
        if autostart { return "Start / Restart" }
        switch serverState {
        case .stopped, .failed: return "Start"
        default: return "Restart"
        }
    }

    private var dotColor: Color {
        guard managed else { return .secondary }
        if autostart { return probeStatus.isReachable ? .green : .orange }
        switch serverState {
        case .running(let healthy): return healthy ? .green : .orange
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var stateText: String {
        guard managed else { return "Huginn isn't managing MLX — configured in the MLX tab" }
        if autostart {
            return probeStatus.isReachable ? "Answering (launchd)" : "launchd — not answering"
        }
        switch serverState {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(true): return "Answering"
        case .running(false): return "Alive, not answering"
        case .failed: return "Failed — see the MLX tab"
        }
    }
}
