import SwiftUI

/// Eldr ACP Configurator — a macOS front end for the `eldr-acp` coding agent. It
/// wraps the CLI in a setup wizard, live config, log viewer, in-app test chat, and
/// (Phase 4) an EldrChat bridge, then installs the binary + launcher so Xcode 27 can
/// drive a self-hosted LLM as a coding agent.
@main
struct EldrACPConfiguratorApp: App {
    @StateObject private var store = ConfigurationStore()
    @StateObject private var health = LLMHealthChecker()
    @StateObject private var installer = InstallerService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(health)
                .environmentObject(installer)
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
                }
        }
        .defaultSize(width: 1000, height: 760)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }  // no "New Window"

        // Menu-bar presence (the modern, state-sharing replacement for NSStatusItem).
        MenuBarExtra("Eldr ACP", systemImage: "wrench.and.screwdriver") {
            StatusBarView()
                .environmentObject(store)
                .environmentObject(health)
                .environmentObject(installer)
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

/// The tabbed main window. (The Bridge tab is added in Phase 4.)
struct MainWindow: View {
    enum Tab: Hashable { case configuration, testChat, logs, bridge }
    @State private var tab: Tab = .configuration

    var body: some View {
        TabView(selection: $tab) {
            ConfigurationView()
                .tabItem { Label("Configuration", systemImage: "slider.horizontal.3") }
                .tag(Tab.configuration)
            TestChatView()
                .tabItem { Label("Test Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.testChat)
            LogView()
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
                .tag(Tab.logs)
            BridgeView()
                .tabItem { Label("EldrChat Bridge", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.bridge)
        }
        .padding(.top, 6)
    }
}
