// swift-tools-version: 6.0
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
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PQRCACP", targets: ["PQRCACP"]),
        .executable(name: "eldr-acp", targets: ["eldr-acp"]),
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
        .testTarget(
            name: "PQRCACPTests",
            dependencies: ["PQRCACP"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
