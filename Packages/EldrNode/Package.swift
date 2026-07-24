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
        // WS-L3: scrypt (RFC 7914) for the Linux keystore's passphrase KEK, from swift-crypto's
        // `_CryptoExtras` — a product of the ALREADY-pinned swift-crypto, so NO new crypto
        // dependency (honors CLAUDE.md §2 + DEVIATIONS AC31; the port doc's "swift-crypto has no
        // memory-hard KDF" was wrong — scrypt IS memory-hard and ships here). Compiled on all
        // platforms so `FileIdentityStore` is unit-tested in the macOS suite; only SELECTED on
        // Linux (see `makeIdentityStore`).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),
    ],
    targets: [
        .target(
            name: "EldrNodeCore",
            dependencies: [
                "PQRCCore",
                "PQRCNostr",
                .product(name: "PQRCACP", package: "PQRCACP"),
                // A2A v1.0 delegation harness (`.a2aRemote` descriptors) — mirrors the
                // Configurator's `ACPRelayHost`/`ACPNodeHost` factory injection.
                .product(name: "A2AHarness", package: "PQRCACP"),
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
                // scrypt for the Linux keystore KEK (WS-L3), from swift-crypto's CryptoExtras
                // module. Harmless on Apple (the macOS node uses NodeKeychain); linked so the
                // store compiles + tests everywhere.
                .product(name: "CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EldrNodeCoreTests",
            dependencies: [
                "EldrNodeCore",
                // The daemon target, so `SybilclawGatewayFramingTests` can `@testable import` it
                // and pin the node's gateway connect handshake against silent protocol re-drift.
                "eldr-node",
                "PQRCCore",
                "PQRCNostr",
                .product(name: "PQRCACP", package: "PQRCACP"),
                .product(name: "A2AHarness", package: "PQRCACP"),
                .product(name: "PQRCMCP", package: "PQRCMCP"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
