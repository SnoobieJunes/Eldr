// swift-tools-version:6.2
import PackageDescription

// ⚠️ THERE IS NO PRIVATE CLOUD COMPUTE BUILD FLAG. DO NOT ADD ONE. (DEVIATIONS AC125)
//
// PCC is gated in the SOURCE, on the SDK's own module version (scoped to the platforms
// Apple ships PCC on):
//     #if canImport(FoundationModels, _version: 2.0) && (os(iOS) || os(macOS))
// in Sources/PQRCAgent/PCCFoundationModelsProvider.swift. Xcode 27's
// FoundationModels declares user-module-version 2.0.x and vends the PCC symbols;
// Xcode 26.x declares 1.5.2 and does not. The compiler reads the installed SDK and
// picks the right path with zero configuration, identically for the Xcode GUI, the
// command line, and CI.
//
// Every manual flag tried here failed: an unconditional `.define("ELDR_PCC_SDK")`
// broke stable Xcode and 3 of 5 CI jobs (AC123), and the environment-variable /
// flag-file opt-in that replaced it silently disabled PCC for Dock-launched Xcode
// builds — which is how the app is actually built — so the owner's device reported
// "compiled without the Private Cloud Compute SDK" (AC125). Adding a flag back
// reintroduces one of those two failures. Don't.

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
            // No PCC define here — see the banner at the top of this file. The Private
            // Cloud Compute path gates itself on the SDK's module version in
            // PCCFoundationModelsProvider.swift, so this target builds on every
            // toolchain without configuration.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PQRCAgentTests",
            dependencies: ["PQRCAgent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
