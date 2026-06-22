// swift-tools-version:6.2
import PackageDescription

// EldrNode — the STANDALONE HEADLESS node (ACPRouterplan Phase 4: "run the host on
// another machine"). A Mac/server process that connects to the Nostr relay, runs the
// PQRC messenger, and serves the FULL ACP agent to ITS OWNER's phone over the relay,
// owner-gated. It is the headless equivalent of the Configurator's `ACPRelayHost` /
// `ACPBridgeService` (no SwiftUI, no @MainActor): the same proven wiring, parked as a
// daemon.
//
// macOS-only: `runACPAgent` (PQRCACP) drives `ACPAgent`, whose `ToolExecutor` spawns
// `Foundation.Process` to do real file/shell work — guarded `#if os(macOS)` upstream.
// So the node hosts the agent only where that exists (a Mac), exactly like the
// Configurator. Servers/Pis without a macOS Keychain are a documented follow-up (the
// `eldr-node` executable's identity store is macOS Keychain-backed for tonight); the
// reusable `EldrNodeCore` serve loop is platform-agnostic and dependency-injected, so
// it is exercised headlessly over a `LocalRelaySimulator` with no network/Keychain.
let package = Package(
    name: "EldrNode",
    platforms: [.macOS(.v26)],
    products: [
        // The reusable, testable headless serve loop (the C-3 gate lives here).
        .library(name: "EldrNodeCore", targets: ["EldrNodeCore"]),
        // The daemon: load/create identity, dial the relay, park, and serve the owner.
        .executable(name: "eldr-node", targets: ["eldr-node"]),
    ],
    dependencies: [
        .package(path: "../PQRCCore"),
        .package(path: "../PQRCNostr"),
        .package(path: "../PQRCACP"),
        // Test-only: the phone's MCP SERVER, so the node-side MCP-over-relay client can
        // be exercised end-to-end over a LocalRelaySimulator against a real `MCPServer`
        // (the same redacting/window-gating server the phone hosts). EldrNodeCore itself
        // does NOT depend on PQRCMCP — only the test target below does.
        .package(path: "../PQRCMCP"),
    ],
    targets: [
        .target(
            name: "EldrNodeCore",
            dependencies: [
                "PQRCCore",
                "PQRCNostr",
                .product(name: "PQRCACP", package: "PQRCACP"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "eldr-node",
            dependencies: [
                "EldrNodeCore",
                "PQRCCore",
                "PQRCNostr",
                .product(name: "PQRCACP", package: "PQRCACP"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EldrNodeCoreTests",
            dependencies: [
                "EldrNodeCore",
                "PQRCCore",
                "PQRCNostr",
                .product(name: "PQRCACP", package: "PQRCACP"),
                .product(name: "PQRCMCP", package: "PQRCMCP"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
