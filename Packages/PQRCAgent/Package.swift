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
            // To enable the real Private Cloud Compute path in
            // PCCFoundationModelsProvider, add `.define("ELDR_PCC_SDK")` here — but
            // ONLY once the installed SDK actually vends the PCC symbols. As of the
            // Xcode 27.0 seed, FoundationModels does NOT export
            // `PrivateCloudComputeLanguageModel` / `ContextOptions` (verified against
            // every .swiftinterface), so defining the flag breaks the build. See
            // DEVIATIONS A40-tech-debt. Keep it gated until a later SDK ships them.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PQRCAgentTests",
            dependencies: ["PQRCAgent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
