import SwiftUI

/// The always-first screen: a lock gate for the device's accounts.
/// - Unlock the default account with Face ID / Touch ID (or device unlock).
/// - Unlock a hidden account by typing its passphrase.
/// - Create a new account — a passphrase-less default, or a passphrase-gated
///   hidden one (the user chooses at setup).
/// No account list is ever shown — entering a passphrase is the ONLY way to reveal
/// a HIDDEN silo, so a wrong passphrase and a non-existent account look the same.
struct AccountGateView: View {
    @Environment(AppSession.self) private var session
    @Environment(TourCoordinator.self) private var tour

    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var displayName = ""
    @State private var creating = false
    @State private var acknowledged = false
    @State private var working = false
    /// Setup choices: a passphrase-gated hidden account vs the passphrase-less
    /// default account, and (for the default) whether to enroll Face ID / Touch ID.
    @State private var usePassphrase = false
    @State private var useBiometric = true
    /// Fire the launch Face ID attempt at most once (it's a convenience, not a
    /// gate — the passphrase field is always available as the fallback).
    @State private var autoTriedBiometric = false

    var body: some View {
        NavigationStack {
            Form {
                if creating {
                    createSection
                } else {
                    unlockSection
                }
                if let error = session.unlockError {
                    Section {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("EldrChat")
            .disabled(working)
            .overlay { if working { ProgressView() } }
            .task {
                // Opt-in Face ID convenience: if the user enrolled it, prompt
                // automatically on launch so unlocking is a glance, not a tap.
                // Silent on cancel/failure — the passphrase field stays available
                // (including for hidden accounts not stored behind biometrics).
                guard !creating, session.hasBiometricUnlock, !autoTriedBiometric
                else { return }
                autoTriedBiometric = true
                await session.biometricUnlock(autoTriggered: true)
            }
        }
    }

    // MARK: Unlock

    private var unlockSection: some View {
        Group {
            // Face ID first: when the default account is stored behind biometrics
            // it's the prominent way in (and it auto-prompts at launch). The
            // passphrase below is the only way into a hidden account.
            if session.hasBiometricUnlock {
                Section {
                    Button {
                        run { await session.biometricUnlock() }
                    } label: {
                        Label("Unlock with Face ID", systemImage: "faceid")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("biometric-unlock")
                } footer: {
                    Text("This device's account unlocks with Face ID. Use a passphrase below for a hidden account.")
                }
            } else if session.hasDefaultAccount {
                // A default account with no biometric enrolled: open on device unlock.
                Section {
                    Button {
                        run { await session.unlockDefault() }
                    } label: {
                        Label("Open my account", systemImage: "lock.open")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("default-unlock")
                } footer: {
                    Text("Use a passphrase below for a hidden account.")
                }
            }
            Section {
                SecureField("Passphrase", text: $passphrase)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("passphrase-field")
                Button("Unlock") { run { await session.unlock(passphrase: passphrase) } }
                    .disabled(passphrase.isEmpty)
                    .accessibilityIdentifier("unlock-button")
            } header: {
                Text(session.hasBiometricUnlock || session.hasDefaultAccount
                    ? "Or use a passphrase" : "Unlock")
            } footer: {
                Text("Each passphrase opens its own private, separate account on this device — nothing reveals how many exist.")
            }
            Section {
                Button("Create a new account") {
                    session.unlockError = nil
                    // A second account must be hidden — the default already exists.
                    usePassphrase = session.hasDefaultAccount
                    creating = true
                }
                .accessibilityIdentifier("show-create-account")
            }
            // New-here affordances: lead with what EldrChat is and a live,
            // on-device demo, so a first-time viewer isn't met by only a
            // passphrase form. Both are account-free and never hit the network.
            Section {
                Button {
                    session.unlockError = nil
                    tour.relaunch()
                } label: {
                    Label("Take the tour", systemImage: "sparkles")
                }
                .accessibilityIdentifier("gate-take-tour")
                Button {
                    session.unlockError = nil
                    Task { await session.bootUniverse(runScript: true) }
                } label: {
                    Label("See the live demo", systemImage: "play.circle")
                }
                .accessibilityIdentifier("gate-see-demo")
            } header: {
                Text("New to EldrChat?")
            } footer: {
                Text("Take a quick guided tour, or watch a self-contained demo — two people and their AIs — run entirely on this device. Neither creates an account or sends anything off your device.")
            }
        }
    }

    // MARK: Create

    private var createSection: some View {
        Group {
            Section {
                TextField("Display name", text: $displayName)
                    .accessibilityIdentifier("onboarding-name")
                Toggle("Protect with a passphrase (hidden account)", isOn: $usePassphrase)
                    .disabled(session.hasDefaultAccount)
                    .accessibilityIdentifier("onboarding-use-passphrase")
                if usePassphrase {
                    SecureField("Passphrase", text: $passphrase)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("passphrase-field")
                    SecureField("Confirm passphrase", text: $confirm)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("passphrase-confirm")
                } else {
                    Toggle("Unlock with Face ID / Touch ID", isOn: $useBiometric)
                        .accessibilityIdentifier("onboarding-use-biometric")
                }
            } header: {
                Text("New account")
            } footer: {
                Text(usePassphrase
                    ? "A separate, HIDDEN account. Its passphrase is the only way in, and nothing on this device reveals it exists."
                    : "Your DEFAULT account on this device — it opens with Face ID / Touch ID or your device passcode.")
            }
            Section {
                Toggle(
                    "I understand: there is NO recovery. If I lose access, this account and all its messages are gone forever.",
                    isOn: $acknowledged
                )
                .accessibilityIdentifier("onboarding-acknowledge")
            } footer: {
                Text("Your account lives only on this device, encrypted by its secure hardware. It is never backed up, synced, or exported. We cannot reset it for you.")
            }
            Section {
                Button("Create account") {
                    run {
                        if usePassphrase {
                            await session.createAccount(
                                passphrase: passphrase, displayName: displayName)
                        } else {
                            await session.createDefaultAccount(
                                displayName: displayName, enableBiometric: useBiometric)
                        }
                    }
                }
                .disabled(!canCreate)
                .accessibilityIdentifier("onboarding-create")
                Button("Back to unlock") { creating = false }
            }
        }
    }

    private var canCreate: Bool {
        guard acknowledged else { return false }
        if usePassphrase { return !passphrase.isEmpty && passphrase == confirm }
        return true
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }
}
