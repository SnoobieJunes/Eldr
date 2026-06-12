import PQRCAgent
import PQRCCore
import PQRCNostr
import SwiftUI

@main
struct PQRCApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

/// Top-level app mode: a real single-persona session, or the Local Universe
/// (Debug + reviewer demo) with multiple personas over an in-process relay.
@MainActor
@Observable
final class AppSession {
    enum Mode {
        case onboarding
        case single(AppModel)
        case universe(LocalUniverse, selected: Int)
    }

    var mode: Mode = .onboarding
    var bootError: String?
    /// Set when the user opens the demo from Settings or launch args.
    var demoRunning = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--reset") {
            KeychainStore().deleteAll()
            UserDefaults.standard.removeObject(forKey: "displayName")
        }
        if arguments.contains("--local-universe") || arguments.contains("--uitest") {
            Task { await bootUniverse(runScript: arguments.contains("--demo-script")) }
        } else if KeychainStore().loadIfPresent(account: "identity-seed") != nil,
            !arguments.contains("--reset")
        {
            Task { await bootSingle() }
        }
    }

    /// UI-test hooks, applied after the universe boots.
    func applyUITestHooks() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let model = activeModel else { return }
        if arguments.contains("--uitest-safetychange") {
            // Synthetic safety-code-change: exercises the persistent warning
            // banner path the same way a re-published 10420 would.
            let target = model.conversations.first { $0.title == "Bob" }
                ?? model.conversations.first
            model.safetyCodeChangedFor.insert(target?.id ?? "")
        }
        if arguments.contains("--uitest-10k") {
            // Seed a 10k-message conversation for the scroll perf test.
            guard
                let conversationID = (model.conversations.first { $0.title == "Bob" }
                    ?? model.conversations.first)?.id
            else { return }
            var list = model.messagesByConversation[conversationID] ?? []
            for i in 0..<10_000 {
                list.append(
                    StoredMessage(
                        id: "perf-\(i)", conversationID: conversationID,
                        senderIdentity: i % 2 == 0 ? model.myIdentityHex : conversationID,
                        participantType: .human, text: "Scroll perf message #\(i)",
                        sentAt: Int64(i), localStatus: "sent"))
            }
            model.messagesByConversation[conversationID] = list
        }
    }

    /// Relay for the single-persona session, resolved in priority order:
    /// 1. `PQRC_RELAY_URL` env var (Xcode scheme) or `relayURL` UserDefaults —
    ///    any ws:// or wss:// relay, e.g. `ws://127.0.0.1:7777` for a local
    ///    `swift run pqrc-relay`. The literal value `local` forces the
    ///    in-process simulator.
    /// 2. Default: the deployed anchor relay.
    /// UI tests are unaffected either way — they boot the Local Universe.
    static let defaultRelayURL = "wss://relay.lerants.com"

    private func makeRelayTransport() async -> any RelayTransport {
        let configured = ProcessInfo.processInfo.environment["PQRC_RELAY_URL"]
            ?? UserDefaults.standard.string(forKey: "relayURL")
            ?? Self.defaultRelayURL
        if configured != "local", let url = URL(string: configured),
            url.scheme == "ws" || url.scheme == "wss"
        {
            return await NostrWebSocketTransport(url: url).connect()
        }
        return await LocalRelaySimulator(url: "local://relay").connect()
    }

    func bootSingle() async {
        let transport = await makeRelayTransport()
        let blossom = LocalBlossomSimulator()
        let provider: any AgentProvider =
            FoundationModelsAgentProvider.isAvailable
            ? FoundationModelsAgentProvider() : MockAgentProvider()
        // S1 Multipeer local link: Debug builds only (TESTFLIGHT-GUIDE §A6 —
        // Release ships without local-network permissions or Bonjour usage).
        #if DEBUG
            let localLinkEnabled = true
        #else
            let localLinkEnabled = false
        #endif
        let runtime = PersonaRuntime(
            displayName: UserDefaults.standard.string(forKey: "displayName") ?? "Me",
            transports: [transport],
            blobStore: blossom,
            provider: provider,
            keychainService: "chat.pqrc.keys",
            enableLocalLink: localLinkEnabled)
        let model = AppModel(
            runtime: runtime,
            personaName: UserDefaults.standard.string(forKey: "displayName") ?? "Me")
        do {
            try await model.start(inMemoryStore: false)
            mode = .single(model)
        } catch {
            bootError = String(describing: error)
        }
    }

    func bootUniverse(runScript: Bool) async {
        let universe = LocalUniverse()
        do {
            try await universe.boot()
            mode = .universe(universe, selected: 0)
            if runScript {
                demoRunning = true
                try await universe.runDemoScript()
                demoRunning = false
            }
            await applyUITestHooks()
        } catch {
            bootError = String(describing: error)
        }
    }

    func selectPersona(_ index: Int) {
        if case .universe(let universe, _) = mode {
            mode = .universe(universe, selected: index)
        }
    }

    var activeModel: AppModel? {
        switch mode {
        case .onboarding: return nil
        case .single(let model): return model
        case .universe(let universe, let selected): return universe.models[selected]
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        switch session.mode {
        case .onboarding:
            OnboardingView()
        case .single(let model):
            MainView(model: model)
        case .universe(let universe, let selected):
            // The switcher renders inside the conversation-list screen only:
            // global overlays fight the navigation bar / composer for taps.
            MainView(
                model: universe.models[selected],
                personaSwitcher: PersonaSwitcher(universe: universe, selected: selected))
        }
    }
}

/// Debug/demo persona switcher for the Local Universe.
struct PersonaSwitcher: View {
    @Environment(AppSession.self) private var session
    let universe: LocalUniverse
    let selected: Int

    var body: some View {
        Picker("Persona", selection: Binding(
            get: { selected },
            set: { session.selectPersona($0) }
        )) {
            ForEach(Array(universe.models.enumerated()), id: \.offset) { index, model in
                Text(model.personaName).tag(index)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityIdentifier("persona-switcher")
    }
}
