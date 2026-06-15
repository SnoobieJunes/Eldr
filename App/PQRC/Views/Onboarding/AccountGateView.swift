import SwiftUI

/// The always-first screen: a passphrase gate for deniable multi-account.
/// - Unlock an existing silo by typing its passphrase.
/// - Create a brand-new account (a fresh silo).
/// - Migrate a pre-silo account from an older build (one-time).
/// No account list is ever shown — entering a passphrase is the ONLY way to
/// reveal a silo, so a wrong passphrase and a non-existent account look the same.
struct AccountGateView: View {
    @Environment(AppSession.self) private var session

    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var displayName = ""
    @State private var creating = false
    @State private var acknowledged = false
    @State private var working = false
    /// Fire the launch Face ID attempt at most once (it's a convenience, not a
    /// gate — the passphrase field is always available as the fallback).
    @State private var autoTriedBiometric = false

    var body: some View {
        NavigationStack {
            Form {
                if session.hasLegacyAccount {
                    migrateSection
                } else if creating {
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
            .navigationTitle(session.hasLegacyAccount ? "Protect your account" : "EldrChat")
            .disabled(working)
            .overlay { if working { ProgressView() } }
            .task {
                // Opt-in Face ID convenience: if the user turned it on, prompt
                // automatically on launch so unlocking is a glance, not a tap.
                // Silent on cancel/failure — the passphrase field stays available
                // (including for hidden accounts not stored behind biometrics).
                guard !session.hasLegacyAccount, !creating, session.hasBiometricUnlock,
                    !autoTriedBiometric
                else { return }
                autoTriedBiometric = true
                await session.biometricUnlock(autoTriggered: true)
            }
        }
    }

    // MARK: Unlock

    private var unlockSection: some View {
        Group {
            // Face ID first: when this device's primary account is stored behind
            // biometrics it's the prominent, default way in (and it auto-prompts
            // at launch). The passphrase is the secondary path below — always
            // available, and the only way into a hidden/different account.
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
                    Text("This device's account unlocks with Face ID. Use a passphrase below for a different or hidden account.")
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
                Text(session.hasBiometricUnlock ? "Or use a passphrase" : "Unlock")
            } footer: {
                Text("Each passphrase opens its own private, separate account on this device — nothing reveals how many exist.")
            }
            Section {
                Button("Create a new account") {
                    session.unlockError = nil
                    creating = true
                }
                .accessibilityIdentifier("show-create-account")
            }
        }
    }

    // MARK: Create

    private var createSection: some View {
        Group {
            Section("New account") {
                TextField("Display name", text: $displayName)
                    .accessibilityIdentifier("onboarding-name")
                SecureField("Passphrase", text: $passphrase)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("passphrase-field")
                SecureField("Confirm passphrase", text: $confirm)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("passphrase-confirm")
            }
            Section {
                Toggle(
                    "I understand: there is NO recovery. If I lose this passphrase, this account and all its messages are gone forever.",
                    isOn: $acknowledged
                )
                .accessibilityIdentifier("onboarding-acknowledge")
            } footer: {
                Text("Your account lives only on this device, encrypted under this passphrase. It is never backed up, synced, or exported. We cannot reset it for you.")
            }
            Section {
                Button("Create account") {
                    run { await session.createAccount(passphrase: passphrase, displayName: displayName) }
                }
                .disabled(!canCreate)
                .accessibilityIdentifier("onboarding-create")
                Button("Back to unlock") { creating = false }
            }
        }
    }

    private var canCreate: Bool {
        !passphrase.isEmpty && passphrase == confirm && acknowledged
    }

    // MARK: Migrate (one-time, from a pre-silo build)

    private var migrateSection: some View {
        Group {
            Section("Set a passphrase") {
                SecureField("New passphrase", text: $passphrase)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("passphrase-field")
                SecureField("Confirm passphrase", text: $confirm)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("passphrase-confirm")
            }
            Section {
                Toggle(
                    "I understand: there is NO recovery if I lose this passphrase.",
                    isOn: $acknowledged
                )
                .accessibilityIdentifier("onboarding-acknowledge")
            } footer: {
                Text("Your existing account will be locked under this passphrase. From now on you'll enter it to open the app, and you can create additional separate accounts too.")
            }
            Section {
                Button("Protect my account") {
                    run { await session.migrateLegacyAccount(passphrase: passphrase) }
                }
                .disabled(!canCreate)
                .accessibilityIdentifier("onboarding-create")
            }
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }
}
