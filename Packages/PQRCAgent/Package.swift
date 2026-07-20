// swift-tools-version:6.2
import PackageDescription
import Foundation

/// Private Cloud Compute build gate (DEVIATIONS AC36/AC123). OFF unless you ask
/// for it, because the PCC symbols (`PrivateCloudComputeLanguageModel`,
/// `ContextOptions`) exist ONLY in the Xcode 27+ SDK — and no GitHub-hosted
/// runner ships Xcode 27, so an unconditional `.define` makes CI unbuildable
/// and breaks every contributor on a stable toolchain.
///
///     ELDR_PCC_SDK=1 swift build     # on an Xcode 27+ toolchain
let pccEnabled = ProcessInfo.processInfo.environment["ELDR_PCC_SDK"] != nil

let package = Package(
    name: "PQRCAgent",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PQRCAgent", targets: ["PQRCAgent"])
    ],
    dependencies: [
        .package(path: "../PQRCCore"),
        .package(path: "../PQRCNostr"),
        // ACPAgentProvider drives an external ACP coding harness as an
        // AgentProvider. PQRCACP is ZERO-dependency (no PQRC* imports), so
        // PQRCAgent → PQRCACP is a clean one-way edge — no cycle.
        .package(path: "../PQRCACP"),
    ],
    targets: [
        .target(
            name: "PQRCAgent",
            dependencies: ["PQRCCore", "PQRCNostr", "PQRCACP"],
            // Real Private Cloud Compute path in PCCFoundationModelsProvider, gated
            // behind `ELDR_PCC_SDK`. That flag is OFF by default (DEVIATIONS
            // AC36/AC123): the PCC symbols (`PrivateCloudComputeLanguageModel`,
            // `ContextOptions`, `ContextOptions.ReasoningLevel`, the generic
            // `LanguageModelSession(model: some LanguageModel, instructions:)`) are
            // ABSENT from the 26.x SDKs, so defining it unconditionally breaks the
            // build ("cannot find type in scope") for everyone not on an Xcode 27+
            // toolchain — which includes all GitHub-hosted CI runners.
            // It is therefore OPT-IN VIA THE ENVIRONMENT (`pccEnabled`, top of file):
            // `ELDR_PCC_SDK=1 swift build`, and only on a toolchain whose SDK
            // actually vends those symbols (verify in FoundationModels.swiftinterface
            // first). Do NOT re-add an unconditional `.define` here.
            //
            // SCOPE NOTE (DEVIATIONS AC25): if/when re-enabled, the flag is iOS-only.
            // Apple Private Cloud Compute is an iOS capability, and the only macOS
            // consumer of PQRCAgent — the Eldr ACP Configurator — uses LOCAL LLMs,
            // never PCC. The macOS PCC symbols also vary by SDK seed (the Xcode 27.0
            // macOS seed lacks them, which broke the Configurator build), so scoping
            // any future opt-in to iOS keeps the macOS build green on any Xcode.
            swiftSettings: pccEnabled
                ? [.swiftLanguageMode(.v6), .define("ELDR_PCC_SDK")]
                : [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PQRCAgentTests",
            dependencies: ["PQRCAgent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
