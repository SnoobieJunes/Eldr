// swift-tools-version:6.2
import PackageDescription

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
            // behind `ELDR_PCC_SDK`. That flag is OFF by default (DEVIATIONS AC36):
            // the PCC symbols (`PrivateCloudComputeLanguageModel`, `ContextOptions`,
            // `ContextOptions.ReasoningLevel`, the generic
            // `LanguageModelSession(model: some LanguageModel, instructions:)`) are
            // ABSENT from the installed iOS 26.5 / 27.0 SDKs, so defining it
            // unconditionally breaks the app build ("cannot find type in scope").
            // It is therefore OPT-IN: add `.define("ELDR_PCC_SDK")` below, and only
            // on a toolchain whose SDK actually vends those symbols (verify in
            // FoundationModels.swiftinterface first).
            //
            // SCOPE NOTE (DEVIATIONS AC25): if/when re-enabled, the flag is iOS-only.
            // Apple Private Cloud Compute is an iOS capability, and the only macOS
            // consumer of PQRCAgent — the Eldr ACP Configurator — uses LOCAL LLMs,
            // never PCC. The macOS PCC symbols also vary by SDK seed (the Xcode 27.0
            // macOS seed lacks them, which broke the Configurator build), so scoping
            // any future opt-in to iOS keeps the macOS build green on any Xcode.
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // ELDR_PCC_SDK is ON (DEVIATIONS A40/AC36). The Private Cloud Compute
                // symbols (`PrivateCloudComputeLanguageModel`, `ContextOptions`) ship in
                // the **Xcode 27 / iOS 27** SDK — VERIFIED 2026-06 (47 + 29 refs in the
                // iPhoneOS *and* iPhoneSimulator FoundationModels.swiftinterface). They are
                // ABSENT from the Xcode 26.x SDK, so this target MUST be built with
                // Xcode 27: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
                // (or set it as the active `xcode-select`). Building with 26.x fails with
                // "cannot find type 'PrivateCloudComputeLanguageModel'/'ContextOptions'".
                .define("ELDR_PCC_SDK"),
            ]
        ),
        .testTarget(
            name: "PQRCAgentTests",
            dependencies: ["PQRCAgent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
