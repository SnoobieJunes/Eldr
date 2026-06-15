import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// On-device inference via the iOS 26 FoundationModels framework
/// (APP-SPEC §9). Availability-gated; the default provider when available.
/// Decrypted context never leaves the device.
public struct FoundationModelsAgentProvider: AgentProvider {
    public init() {}

    /// nil when the on-device model is ready; otherwise a specific, actionable
    /// reason. This is what surfaces in Settings and in the thrown error, so the
    /// user learns *why* Apple Intelligence isn't responding instead of silently
    /// getting the Mock stub.
    public static var availabilityReason: String? {
        #if canImport(FoundationModels)
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This device isn't eligible for Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is off — turn it on in Settings ▸ Apple Intelligence & Siri."
                case .modelNotReady:
                    return "The on-device model is still downloading. Try again in a few minutes."
                @unknown default:
                    return "On-device AI is unavailable on this device."
                }
            }
        #else
            return "This OS build doesn't include the on-device model framework."
        #endif
    }

    public static var isAvailable: Bool { availabilityReason == nil }

    /// One-shot on-device generation for small utility tasks (e.g. inventing a
    /// local display codename). Stays entirely on device — it never touches a
    /// remote API. Throws `AgentProviderError.unavailable` when the on-device
    /// model isn't ready, so callers can fall back to a local generator.
    public static func oneShot(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
            if let reason = availabilityReason {
                throw AgentProviderError.unavailable(reason)
            }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
            throw AgentProviderError.unavailable("FoundationModels not present on this OS build")
        #endif
    }

    public func draftReply(context: AgentContext) async throws -> Draft {
        #if canImport(FoundationModels)
            if let reason = Self.availabilityReason {
                throw AgentProviderError.unavailable(reason)
            }
            let session = LanguageModelSession(
                instructions: """
                    You are \(context.myDisplayName)'s personal messaging assistant. \
                    Draft a brief, natural reply to the conversation. Reply with the \
                    draft text only.
                    """)
            do {
                let response = try await session.respond(to: Self.renderTranscript(context))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                // An empty/whitespace completion is a failure, not a draft: a
                // blank reply reads as "the AI is broken and lying about it".
                // Surface it so the UI shows a reason instead of inserting "".
                guard !text.isEmpty else {
                    throw AgentProviderError.unavailable(
                        "The on-device model returned an empty reply. Try again, or pick a different provider in Settings ▸ AI.")
                }
                return Draft(text: text)
            } catch let error as AgentProviderError {
                throw error
            } catch {
                // Surface generation/guardrail failures instead of swallowing
                // them — a silent empty draft reads as "the AI is broken".
                throw AgentProviderError.unavailable("On-device generation failed: \(error.localizedDescription)")
            }
        #else
            throw AgentProviderError.unavailable("FoundationModels not present on this OS build")
        #endif
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        #if canImport(FoundationModels)
            if let reason = Self.availabilityReason {
                throw AgentProviderError.unavailable(reason)
            }
            let session = LanguageModelSession(
                instructions: """
                    You are \(context.myDisplayName)'s AI participating in a shared \
                    thread with other people's AIs. Contribute one useful message — \
                    share the relevant context the other AIs need to help, in as \
                    much detail as is useful — or reply with exactly PASS to stay \
                    silent.
                    """)
            do {
                let response = try await session.respond(to: Self.renderTranscript(context))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != "PASS" else { return nil }
                return AgentTurn(messages: [AgentMessage(text: text)])
            } catch {
                throw AgentProviderError.unavailable("On-device generation failed: \(error.localizedDescription)")
            }
        #else
            throw AgentProviderError.unavailable("FoundationModels not present on this OS build")
        #endif
    }

    static func renderTranscript(_ context: AgentContext) -> String {
        context.transcript.suffix(20).map { entry in
            let role = entry.participantType == .agent ? "\(entry.senderDisplayName)'s AI" : entry.senderDisplayName
            return "\(role): \(entry.text)"
        }.joined(separator: "\n")
    }
}
