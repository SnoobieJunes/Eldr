import SwiftUI

/// First launch (APP-SPEC §5): explainers, local-only display name, the
/// unskippable device-loss warning, then key generation + publication.
struct OnboardingView: View {
    @Environment(AppSession.self) private var session
    @State private var displayName = ""
    @State private var acknowledgedLoss = false
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OnboardingCard {
                        Label("Private by construction", systemImage: "lock.shield")
                            .font(.headline)
                        Text(
                            "PQRC is end-to-end encrypted with post-quantum cryptography. No phone number, no email, no account — your identity is a key pair generated on this device."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    OnboardingCard {
                        Label("AI, transparently", systemImage: "sparkles")
                            .font(.headline)
                        Text(
                            "Your AI assistant can read conversations on-device and help you reply — but it is silent by default, every AI message is visibly labeled, and no one ever unknowingly talks to an AI."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    OnboardingCard {
                        Text("Your name (only stored on this device)")
                            .font(.headline)
                        TextField("Display name", text: $displayName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("onboarding-name")
                    }
                    // The unskippable warning (recovery is a non-goal, SPEC §0).
                    OnboardingCard {
                        Label("No recovery — by design", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(
                            "Your keys exist only on this device. They are never backed up, synced, or exported. If you lose this device, you lose this identity and all its conversations. There is no recovery."
                        )
                        .font(.subheadline)
                        Toggle(
                            "I understand that losing this device loses this identity",
                            isOn: $acknowledgedLoss
                        )
                        .accessibilityIdentifier("onboarding-acknowledge")
                    }
                    Button {
                        creating = true
                        UserDefaults.standard.set(
                            displayName.isEmpty ? "Me" : displayName, forKey: "displayName")
                        Task { await session.bootSingle() }
                    } label: {
                        if creating {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Generate my keys").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!acknowledgedLoss || creating)
                    .accessibilityIdentifier("onboarding-create")
                }
                .padding()
            }
            .navigationTitle("Welcome to PQRC")
        }
    }
}

/// Grouped-inset style explainer card (iOS 26 look without translucency —
/// secondary text over materials fails the contrast audit).
private struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
