// swift-tools-version:6.2
import PackageDescription

// PQRCACP — EldrChat's Agent Client Protocol (ACP) AGENT. A standalone Swift
// executable (`eldr-acp`) that an ACP CLIENT (e.g. Xcode 27) spawns over stdio,
// letting EldrChat's self-hosted LLM pilot the editor: read/write files, run
// shell commands, build projects, and run tests on simulators.
//
// ACP = JSON-RPC 2.0 over stdio. Xcode is the client; this is the agent. Unlike a
// plain MCP server, the agent makes OUTBOUND requests/notifications to the client
// (session/update, fs/*, terminal/*, session/request_permission), so the transport
// is bidirectional and correlates client responses to outbound requests by id.
//
// The library has NO app/crypto/SwiftUI dependencies and ZERO external packages —
// it speaks ACP and talks to a local OpenAI-compatible LLM behind an `LLMClient`
// protocol, so the whole protocol is testable headlessly and network-free
// (`swift test`). The reasoning-trace stripper is vendored (see ReasoningTrace.swift)
// to keep this a fast, dependency-light tool rather than pulling swift-crypto /
// swift-secp256k1 in through PQRCAgent.
let package = Package(
    name: "PQRCACP",
    // macOS floor is intentionally lower than the v26 app fleet: the `eldr-acp`
    // agent/CLI is dependency-free with no v26-SDK needs, so it stays runnable on a
    // wider range of macOS node hosts. (iOS is .v26 to match the app — its only iOS consumer.)
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "PQRCACP", targets: ["PQRCACP"]),
        .executable(name: "eldr-acp", targets: ["eldr-acp"]),
        // Terminal ACP client that drives the agent by hand (and exposes the reusable
        // ACPClientDriver the PQRC watch-along bridge also uses).
        .executable(name: "eldr-acp-run", targets: ["eldr-acp-run"]),
    ],
    targets: [
        .target(
            name: "PQRCACP",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "eldr-acp",
            dependencies: ["PQRCACP"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "eldr-acp-run",
            dependencies: ["PQRCACP"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PQRCACPTests",
            // Depend on the `eldr-acp` executable so `swift test` builds it into the
            // products dir — RunnerE2ETests spawns the real binary through ACPClientDriver.
            dependencies: ["PQRCACP", "eldr-acp"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
