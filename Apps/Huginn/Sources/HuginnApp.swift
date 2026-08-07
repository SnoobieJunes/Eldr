// SPDX-License-Identifier: AGPL-3.0-only
import PQRCACP
import SwiftUI

/// Eldr — Mac node & AI tether: the macOS "node" for EldrChat. It pairs with your phone,
/// hosts the `eldr-acp` coding harness (setup wizard, live config, log viewer, in-app
/// test chat), tethers your coding session into EldrChat conversations (the Bridge
/// (phone tether) tab), and provisions infrastructure (the relay-setup wizard). It
/// installs the binary + launcher so Xcode 27 can drive a self-hosted LLM as a coding
/// agent.
@main
struct HuginnApp: App {
    @StateObject private var store = ConfigurationStore()
    @StateObject private var health = LLMHealthChecker()
    @StateObject private var installer = InstallerService()
    // WS-B2: lifted here (rather than owned by BridgeView) so the Relay tab
    // (`RelayWizardView`) shares the SAME live node/relay state as the Bridge (phone
    // tether) tab — the "Connect local relay" quick action and the relay-status rows
    // need to see (and reconnect) the actual running `ACPBridgeService`, not a second
    // instance.
    @StateObject private var bridge = ACPBridgeService()
    // WS-B3: lifted here too (were private @StateObjects in BridgeView/TestChatView)
    // so the menu-bar StatusBarView — a SEPARATE scene, not a descendant of the main
    // window — can show tether state + a pending-approval badge sourced from the SAME
    // live objects the Bridge/Test Chat tabs drive, and so one `PendingApprovalNotifier`
    // can watch both without needing to live inside either view.
    @StateObject private var a2aHost = A2AServerHost()
    @StateObject private var testChatSession = TestChatSession()
    @StateObject private var approvalNotifier = PendingApprovalNotifier()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(health)
                .environmentObject(installer)
                .environmentObject(bridge)
                .environmentObject(a2aHost)
                .environmentObject(testChatSession)
                // Open at a comfortable size and stay FREELY resizable up from the
                // minimum (the content is flexible, so the window grows with the drag
                // — same desktop treatment as the EldrChat app, not small-or-fullscreen).
                .frame(
                    minWidth: 760, idealWidth: 1000, maxWidth: .infinity,
                    minHeight: 560, idealHeight: 760, maxHeight: .infinity)
                .task {
                    // Health checker reads the live LLM config and polls while open.
                    health.configProvider = { store.llmConfig }
                    health.startPolling()
                    await installer.refreshState()
                    // WS-B3: wire the notifier once both approval surfaces exist, so a
                    // pending approval fires an OS notification even while Huginn's
                    // window isn't frontmost (only the menu bar showing).
                    approvalNotifier.observe(a2aHost: a2aHost, testChatSession: testChatSession)
                    // Restore the tether: the operator's last Enable/Stop choice is
                    // persisted; without this every relaunch silently dropped the
                    // relay node + tether host until "Enable bridge" was clicked again.
                    if UserDefaults.standard.bool(forKey: ACPBridgeService.bridgeEnabledKey) {
                        bridge.enable()
                    }
                    // A2A serving restore (same AC109 pattern). The providers MUST be
                    // wired here first — BridgeView wires them too, but only once its
                    // tab has appeared, and a launch-restored server built from the
                    // inert defaults would answer with a NullLLMClient.
                    a2aHost.descriptorProvider = {
                        ConfigurationStore.resolvedHarnessDescriptor(id: bridge.relayHarnessID)
                            ?? .builtIn
                    }
                    a2aHost.llmProvider = {
                        let config = ACPBridgeService.relayHostLLMConfig()
                        return InspectingLLMClient(
                            wrapping: OpenAICompatibleLLMClient(config: config),
                            model: config.model)
                    }
                    a2aHost.toolEnvironmentProvider = {
                        ToolEnvironment(
                            workdir: bridge.agentWorkdir,
                            baseEnvironment: ProcessInfo.processInfo.environment)
                    }
                    a2aHost.agentConfigProvider = { .default }
                    a2aHost.autoApproveProvider = { store.a2aAutoApprove }
                    a2aHost.autoApproveAllowsToolsProvider = {
                        ACPBridgeService.operatorAllowsUngatedTools()
                    }
                    if UserDefaults.standard.bool(forKey: A2AServerHost.serverEnabledKey) {
                        await a2aHost.start()
                    }
                    // WS-I7: bring the workspace agents back up. A Buzz connection is
                    // a standing membership — the workspace expects the agent to be
                    // there — so an un-paused connection survives a Huginn restart
                    // without the user reconnecting it by hand. Paused (or invalid)
                    // connections stay down; each one re-checks its own gates first.
                    BuzzGatewayService.shared.startEnabledConnections(
                        llmURL: store.llmURL, llmModel: store.llmModel, llmToken: store.llmToken)
                }
        }
        .defaultSize(width: 1000, height: 760)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }  // no "New Window"

        // WS-M2: "Open as window" target for the log console — one scene, the
        // routed LogConsoleSource picks which log it shows (each source gets its
        // own window; opening an already-open source focuses it).
        WindowGroup("Log console", id: LogConsoleView.windowID, for: LogConsoleSource.self) {
            $source in
            LogConsoleWindow(source: source ?? .agent)
        }
        .defaultSize(width: 1000, height: 640)

        // Menu-bar presence (the modern, state-sharing replacement for NSStatusItem).
        MenuBarExtra("Eldr node", systemImage: "wrench.and.screwdriver") {
            StatusBarView()
                .environmentObject(store)
                .environmentObject(health)
                .environmentObject(installer)
                .environmentObject(bridge)
                .environmentObject(a2aHost)
                .environmentObject(testChatSession)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Routes between the first-run wizard and the main window based on a persisted flag.
struct RootView: View {
    @AppStorage("setupCompleted") private var setupCompleted = false

    var body: some View {
        if setupCompleted {
            MainWindow()
        } else {
            SetupWizardView(onFinish: { setupCompleted = true })
        }
    }
}

/// The tabbed main window — "Eldr — Mac node & AI tether". Tabs cover the local coding
/// harness (Configuration, Test Chat, Logs), the phone pairing/tether (Bridge (phone
/// tether)), and the infrastructure setup (Relay).
struct MainWindow: View {
    enum Tab: Hashable {
        case configuration, testChat, mlx, inspector, logs, bridge, nearby, relay
        // WS-D2h: `world` replaced the separate `townGrants` and `connections` tabs.
        // Both VIEWS still exist and are reached from inside it; only the tab cases are
        // gone, and nothing outside this file ever posted them to `openTab`.
        case world
    }
    @State private var tab: Tab = .configuration

    /// Cross-scene tab jump (WS-M1): the menu-bar extra and the Configuration
    /// linkage chip post this with a `Tab` as the object to land on a tab —
    /// selection is otherwise private @State inside the main window.
    static let openTab = Notification.Name("chat.eldr.huginn.open-tab")

    var body: some View {
        TabView(selection: $tab) {
            ConfigurationView()
                .tabItem { Label("Configuration", systemImage: "slider.horizontal.3") }
                .tag(Tab.configuration)
            TestChatView()
                .tabItem { Label("Test Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.testChat)
            MLXView()
                .tabItem { Label("MLX", systemImage: "memorychip") }
                .tag(Tab.mlx)
            AgentInspectorView()
                .tabItem { Label("Inspector", systemImage: "scope") }
                .tag(Tab.inspector)
            // WS-M2: the reusable console replaced LogView — same default source
            // (eldr-acp.log), plus source switching, search, markup, remediation.
            LogConsoleView(source: .agent, style: .full)
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
                .tag(Tab.logs)
            BridgeView()
                // WS-B4: was "EldrChat Bridge" — findable by NAME now: this is where the
                // phone's tether to this Mac (pairing + the remote-drive session) lives.
                .tabItem { Label("Bridge (phone tether)", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.bridge)
            NearbyScannerView()
                .tabItem { Label("Nearby", systemImage: "dot.radiowaves.left.and.right") }
                .tag(Tab.nearby)
            RelayWizardView()
                .tabItem { Label("Relay", systemImage: "server.rack") }
                .tag(Tab.relay)
            // WS-D2h: the single "who am I connected to?" surface — towns (live, read
            // from the running node via `world/status`), Buzz workspaces (WS-I7), and the
            // phone tether. It CONSOLIDATES the former Connections and Town Grants tabs:
            // both of those views are reached from inside it, so every import/edit/
            // revoke path is unchanged, and the Phase-2 invariant-9 authorization surface
            // is still one click from here.
            WorldView()
                .tabItem {
                    Label("World", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag(Tab.world)
        }
        .padding(.top, 6)
        .navigationTitle("Eldr — Mac node & AI tether")
        .onReceive(NotificationCenter.default.publisher(for: Self.openTab)) { note in
            if let target = note.object as? Tab { tab = target }
        }
    }
}
