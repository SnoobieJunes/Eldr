import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Inference via Apple's **Private Cloud Compute (PCC)** server foundation model,
/// exposed to third-party developers in the WWDC26 FoundationModels framework
/// (APP-SPEC §9; DEVIATIONS PCC tier). PCC is a much larger model than the
/// on-device default, with a 32K context window and a `reasoning` capability
/// (`.light` / `.moderate` / `.deep`).
///
/// Privacy posture (CLAUDE.md cardinal rule): PCC sends decrypted context
/// off-device to Apple's attested, no-retention enclave. We treat it as its OWN
/// tier — it IS off-device (so the consent alert fires and the "leaves device"
/// indicator shows), but it is EXEMPT from the name-redaction egress firewall
/// that applies to third-party cloud vendors, because Apple PCC is attested and
/// retains no prompts. See `ConfiguredAI.appliesEgressFirewall`.
///
/// Eligibility (Apple): free for App Store Small Business Program developers with
/// < 2M lifetime first-time downloads, and requires the Private Cloud Compute
/// entitlement. When ineligible / not ready / rate-limited, the provider reports a
/// specific reason and the caller falls back to the Demo stub — never a silent
/// confidentiality downgrade.
///
/// BUILD GATE — `ELDR_PCC_SDK`: the PCC symbols
/// (`PrivateCloudComputeLanguageModel`, `ContextOptions`, `ContextOptions.ReasoningLevel`,
/// the `respond(to:options:contextOptions:)` overload) are documented by Apple for the
/// iOS-27 / macOS-27 SDK, but are NOT YET exported by the installed Xcode 27.0 seed
/// (verified absent from every FoundationModels .swiftinterface, 2026-06-18). So the
/// real PCC path is compiled ONLY when `ELDR_PCC_SDK` is defined — and defining it
/// against this seed fails to build. Because this provider lives in the PQRCAgent
/// SwiftPM package, the flag is set in `Package.swift`
/// (`swiftSettings: [.define("ELDR_PCC_SDK")]`) — NOT the app target's
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, which doesn't reach package compilation.
/// Without the flag the file still compiles everywhere and the provider degrades to a
/// clear "not built with the PCC SDK" reason → Demo fallback.
///
/// RUNTIME GATE: even once the symbols ship, `PrivateCloudComputeLanguageModel` & friends
/// require iOS/macOS 27 while the package deploys to iOS/macOS 26 — so every PCC symbol
/// use is already behind an `@available(iOS 27, macOS 27, *)` check (`#available` guards
/// in the entry points, attributes on the helpers). On 26 the provider reports the
/// version gap → Demo. Verify exact symbol spellings in Xcode Quick Help when the SDK
/// ships them — they are isolated to this one file.
public struct PCCFoundationModelsProvider: AgentProvider {
    /// User-selected reasoning depth ("light" | "moderate" | "deep"); nil → moderate.
    private let reasoningLevel: String?
    /// Optional sampling temperature (0.0–2.0). nil → framework default.
    private let temperature: Double?
    /// Optional response-length cap. nil → framework default.
    private let maxResponseTokens: Int?

    public init(
        reasoningLevel: String? = "moderate",
        temperature: Double? = nil,
        maxResponseTokens: Int? = nil
    ) {
        self.reasoningLevel = reasoningLevel
        self.temperature = temperature
        self.maxResponseTokens = maxResponseTokens
    }

    /// nil when PCC is usable; otherwise a specific, actionable reason that
    /// surfaces in Settings and in the thrown error (mirrors the on-device
    /// provider). PCC rides the same Apple Intelligence enablement as on-device;
    /// PCC-specific failures (entitlement missing, over the 2M cap, rate-limited)
    /// surface at `respond` time and are mapped in `mapGenerationError`.
    public static var availabilityReason: String? {
        #if canImport(FoundationModels) && ELDR_PCC_SDK
            guard #available(iOS 27, macOS 27, *) else {
                return "Private Cloud Compute requires iOS 27 / macOS 27 or later — this device is on an older OS."
            }
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This device isn't eligible for Apple Intelligence (required for Private Cloud Compute)."
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is off — turn it on in Settings ▸ Apple Intelligence & Siri to use Private Cloud Compute."
                case .modelNotReady:
                    return "Apple Intelligence is still preparing. Try again in a few minutes."
                @unknown default:
                    return "Private Cloud Compute is unavailable on this device."
                }
            }
        #elseif canImport(FoundationModels)
            return "This build was compiled without the Private Cloud Compute SDK. Replies use the Demo stub until the app is rebuilt with the Xcode 26 SDK + PCC entitlement."
        #else
            return "This OS build doesn't include the Foundation Models framework."
        #endif
    }

    public static var isAvailable: Bool { availabilityReason == nil }

    public func draftReply(context: AgentContext) async throws -> Draft {
        #if canImport(FoundationModels) && ELDR_PCC_SDK
            guard #available(iOS 27, macOS 27, *) else {
                throw AgentProviderError.unavailable(
                    "Private Cloud Compute requires iOS 27 / macOS 27 or later.")
            }
            if let reason = Self.availabilityReason {
                throw AgentProviderError.unavailable(reason)
            }
            let session = Self.makeSession(instructions: context.draftSystemPrompt())
            do {
                let text = try await Self.respond(
                    session: session,
                    prompt: FoundationModelsAgentProvider.renderTranscript(context),
                    reasoningLevel: reasoningLevel,
                    temperature: temperature,
                    maxResponseTokens: maxResponseTokens)
                // An empty/whitespace completion is a failure, not a draft.
                guard !text.isEmpty else {
                    throw AgentProviderError.unavailable(
                        "Private Cloud Compute returned an empty reply. Try again, or pick a different provider in Settings ▸ AI.")
                }
                return Draft(text: text)
            } catch let error as AgentProviderError {
                throw error
            } catch {
                throw AgentProviderError.unavailable(Self.mapGenerationError(error))
            }
        #else
            throw AgentProviderError.unavailable(
                Self.availabilityReason ?? "Private Cloud Compute is unavailable.")
        #endif
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        #if canImport(FoundationModels) && ELDR_PCC_SDK
            guard #available(iOS 27, macOS 27, *) else {
                throw AgentProviderError.unavailable(
                    "Private Cloud Compute requires iOS 27 / macOS 27 or later.")
            }
            if let reason = Self.availabilityReason {
                throw AgentProviderError.unavailable(reason)
            }
            let session = Self.makeSession(instructions: context.turnSystemPrompt())
            do {
                let text = try await Self.respond(
                    session: session,
                    prompt: FoundationModelsAgentProvider.renderTranscript(context),
                    reasoningLevel: reasoningLevel,
                    temperature: temperature,
                    maxResponseTokens: maxResponseTokens)
                guard !text.isEmpty, text != "PASS" else { return nil }
                return AgentTurn(messages: [AgentMessage(text: text)])
            } catch let error as AgentProviderError {
                throw error
            } catch {
                throw AgentProviderError.unavailable(Self.mapGenerationError(error))
            }
        #else
            throw AgentProviderError.unavailable(
                Self.availabilityReason ?? "Private Cloud Compute is unavailable.")
        #endif
    }

    // MARK: - PCC session + reasoning (WWDC26 SDK only)

    #if canImport(FoundationModels) && ELDR_PCC_SDK
        /// Build a session bound to the PCC SERVER model (not the on-device default).
        @available(iOS 27, macOS 27, *)
        private static func makeSession(instructions: String) -> LanguageModelSession {
            LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(), instructions: instructions)
        }

        /// One PCC generation with the per-AI reasoning depth + sampling options
        /// applied. Reasoning is PCC-only and consumes tokens against the 32K window.
        @available(iOS 27, macOS 27, *)
        private static func respond(
            session: LanguageModelSession,
            prompt: String,
            reasoningLevel: String?,
            temperature: Double?,
            maxResponseTokens: Int?
        ) async throws -> String {
            let options = GenerationOptions(
                temperature: temperature, maximumResponseTokens: maxResponseTokens)
            let contextOptions = ContextOptions(reasoningLevel: mapReasoning(reasoningLevel))
            let response = try await session.respond(
                to: prompt, options: options, contextOptions: contextOptions)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Map the stored string to the framework enum; unknown/nil → `.moderate`.
        @available(iOS 27, macOS 27, *)
        static func mapReasoning(_ level: String?) -> ContextOptions.ReasoningLevel {
            switch level?.lowercased() {
            case "light": return .light
            case "deep": return .deep
            default: return .moderate
            }
        }
    #endif

    /// Translate FoundationModels generation/guardrail/eligibility errors into a
    /// human, actionable reason. The 2026 error type is mid-migration
    /// (`LanguageModelSession.GenerationError` → `LanguageModelError`), so this
    /// matches on the localized description defensively rather than on case shapes
    /// that may be renamed — keeping the build resilient across point releases.
    static func mapGenerationError(_ error: Error) -> String {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("rate") && lower.contains("limit") {
            return "Private Cloud Compute is rate-limited (per-user daily quota reached). Try again later, or use a different provider in Settings ▸ AI."
        }
        if lower.contains("entitlement") || lower.contains("eligible") || lower.contains("not authorized") {
            return "This app isn't yet authorized for Private Cloud Compute (entitlement / Small Business Program eligibility). Replies use the Demo stub until then."
        }
        if lower.contains("context") && lower.contains("window") {
            return "The conversation exceeded Private Cloud Compute's context window. Trim the context depth in Settings ▸ AI."
        }
        if lower.contains("guardrail") || lower.contains("refus") {
            return "Private Cloud Compute declined to answer (safety guardrail)."
        }
        return "Private Cloud Compute generation failed: \(error.localizedDescription)"
    }
}
