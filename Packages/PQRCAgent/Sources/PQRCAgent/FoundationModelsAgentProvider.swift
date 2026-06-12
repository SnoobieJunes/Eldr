import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// On-device inference via the iOS 26 FoundationModels framework
/// (APP-SPEC §9). Availability-gated; the default provider when available.
/// Decrypted context never leaves the device.
public struct FoundationModelsAgentProvider: AgentProvider {
    public init() {}

    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
        #else
            return false
        #endif
    }

    public func draftReply(context: AgentContext) async throws -> Draft {
        #if canImport(FoundationModels)
            guard Self.isAvailable else {
                throw AgentProviderError.unavailable("AI unavailable on this device")
            }
            let session = LanguageModelSession(
                instructions: """
                    You are \(context.myDisplayName)'s personal messaging assistant. \
                    Draft a brief, natural reply to the conversation. Reply with the \
                    draft text only.
                    """)
            let response = try await session.respond(to: Self.renderTranscript(context))
            return Draft(text: response.content)
        #else
            throw AgentProviderError.unavailable("FoundationModels not present")
        #endif
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        #if canImport(FoundationModels)
            guard Self.isAvailable else {
                throw AgentProviderError.unavailable("AI unavailable on this device")
            }
            let session = LanguageModelSession(
                instructions: """
                    You are \(context.myDisplayName)'s AI participating in a shared \
                    thread with another person's AI. Contribute one short, useful \
                    message, or reply with exactly PASS to stay silent.
                    """)
            let response = try await session.respond(to: Self.renderTranscript(context))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "PASS" else { return nil }
            return AgentTurn(messages: [AgentMessage(text: text)])
        #else
            throw AgentProviderError.unavailable("FoundationModels not present")
        #endif
    }

    static func renderTranscript(_ context: AgentContext) -> String {
        context.transcript.suffix(20).map { entry in
            let role = entry.participantType == .agent ? "\(entry.senderDisplayName)'s AI" : entry.senderDisplayName
            return "\(role): \(entry.text)"
        }.joined(separator: "\n")
    }
}
