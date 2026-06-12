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

    func bootSingle() async {
        let relay = LocalRelaySimulator(url: "local://relay")
        let blossom = LocalBlossomSimulator()
        let provider: any AgentProvider =
            FoundationModelsAgentProvider.isAvailable
            ? FoundationModelsAgentProvider() : MockAgentProvider()
        let runtime = PersonaRuntime(
            displayName: UserDefaults.standard.string(forKey: "displayName") ?? "Me",
            transports: [await relay.connect()],
            blobStore: blossom,
            provider: provider,
            keychainService: "chat.pqrc.keys")
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
