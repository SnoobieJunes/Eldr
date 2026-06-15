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
        }
    }

    // MARK: Unlock

    private var unlockSection: some View {
        Group {
            if session.hasBiometricUnlock {
                Section {
                    Button {
                        run { await session.biometricUnlock() }
                    } label: {
                        Label("Unlock with Face ID", systemImage: "faceid")
                    }
                    .accessibilityIdentifier("biometric-unlock")
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
                Text("Unlock")
            } footer: {
                Text("Enter your passphrase to open that account. Each passphrase opens its own private, separate account on this device — nothing reveals how many exist.")
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
