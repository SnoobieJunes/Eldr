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
        // A2A v1.0 delegation harness: `.a2aRemote` descriptors are bridged to a real
        // ACP transport over `SwiftA2A`. A SEPARATE product/target from `PQRCACP` —
        // see the dependency note below.
        .library(name: "A2AHarness", targets: ["A2AHarness"]),
    ],
    dependencies: [
        // Only `A2AHarness` depends on this — see the note on that target.
        .package(path: "../SwiftA2A")
    ],
    targets: [
        // NO dependencies, ever — this is PQRCACP's zero-dep promise (CLAUDE.md: "The
        // library has NO app/crypto/SwiftUI dependencies and ZERO external packages").
        // A2A support is layered ABOVE this target (`A2AHarness`), not folded into it;
        // `HarnessTransportFactory.swift` is the dependency-free seam that makes that
        // possible (see that file).
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
        // Implements `HarnessTransportFactory` for `.a2aRemote` by driving a real
        // `SwiftA2A` client — the ONLY target in this package that imports SwiftA2A.
        // Optional at the wiring layer: a node that never selects an `.a2aRemote`
        // harness need not link this.
        .target(
            name: "A2AHarness",
            dependencies: [
                "PQRCACP",
                .product(name: "A2AClient", package: "SwiftA2A"),
                .product(name: "A2ACore", package: "SwiftA2A"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PQRCACPTests",
            // Depend on the `eldr-acp` executable so `swift test` builds it into the
            // products dir — RunnerE2ETests spawns the real binary through ACPClientDriver.
            dependencies: ["PQRCACP", "eldr-acp"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "A2AHarnessTests",
            dependencies: ["A2AHarness"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
