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
    ],
    targets: [
        .target(
            name: "PQRCAgent",
            dependencies: ["PQRCCore", "PQRCNostr"],
            // Real Private Cloud Compute path in PCCFoundationModelsProvider.
            // `ELDR_PCC_SDK` is enabled because the installed Xcode-beta SDK now
            // vends the PCC symbols (`PrivateCloudComputeLanguageModel`,
            // `ContextOptions`, `ContextOptions.ReasoningLevel`, the generic
            // `LanguageModelSession(model: some LanguageModel, instructions:)`,
            // verified in FoundationModels.swiftinterface).
            //
            // SCOPED TO iOS (DEVIATIONS AC25): Apple Private Cloud Compute is an iOS
            // capability, and the only macOS consumer of PQRCAgent — the Eldr ACP
            // Configurator — uses LOCAL LLMs, never PCC. The macOS PCC symbols also
            // vary by SDK seed (the Xcode 27.0 macOS seed lacks them, which broke the
            // Configurator build), so defining the flag only for iOS keeps the macOS
            // build green on any Xcode while leaving the iOS PCC tier untouched.
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("ELDR_PCC_SDK", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "PQRCAgentTests",
            dependencies: ["PQRCAgent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
