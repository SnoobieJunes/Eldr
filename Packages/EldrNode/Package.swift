// swift-tools-version:6.2
import PackageDescription

// EldrNode — the STANDALONE HEADLESS node (ACPRouterplan Phase 4: "run the host on
// another machine"). A Mac/server process that connects to the Nostr relay, runs the
// PQRC messenger, and serves the FULL ACP agent to ITS OWNER's phone over the relay,
// owner-gated. It is the headless equivalent of the Configurator's `ACPRelayHost` /
// `ACPBridgeService` (no SwiftUI, no @MainActor): the same proven wiring, parked as a
// daemon.
//
// Platforms: `runACPAgent` (PQRCACP) drives `ACPAgent`, whose `ToolExecutor` spawns
// `Foundation.Process` to do real file/shell work — node-only (`#if os(macOS) ||
// os(Linux)` upstream since WS-L4), so both a Mac and a Linux server/Pi host the full
// agent. Linux identity lives in the WS-L2/L3 `FileIdentityStore` keystore ladder
// (macOS keeps the Keychain); the reusable `EldrNodeCore` serve loop is
// platform-agnostic and dependency-injected, so it is exercised headlessly over a
// `LocalRelaySimulator` with no network/Keychain.
let package = Package(
    name: "EldrNode",
    platforms: [.macOS(.v26)],
    products: [
        // The reusable, testable headless serve loop (the C-3 gate lives here).
        .library(name: "EldrNodeCore", targets: ["EldrNodeCore"]),
        // WS-G5: the gooseworld integration layer — the production wall host/bridge,
        // grant + cursor stores, and the loopback socket host for `eldr-gooseworld`.
        // A SEPARATE library so `EldrNodeCore` keeps its deliberate PQRCMCP-free
        // boundary (see the dependency note below) while this layer composes both.
        .library(name: "EldrNodeGooseworld", targets: ["EldrNodeGooseworld"]),
        // The daemon: load/create identity, dial the relay, park, and serve the owner.
        .executable(name: "eldr-node", targets: ["eldr-node"]),
        // WS-I5: the Eldr↔Buzz gateway — join a Buzz workspace as an agent member,
        // run turns against the LOCAL model, emit NIP-AM/NIP-AO. Library + daemon.
        .library(name: "EldrBuzzGateway", targets: ["EldrBuzzGateway"]),
        .executable(name: "eldr-buzz-agent", targets: ["eldr-buzz-agent"]),
    ],
    dependencies: [
        .package(path: "../PQRCCore"),
        .package(path: "../PQRCNostr"),
        .package(path: "../PQRCACP"),
        // The phone's MCP server package ALSO carries the gooseworld wall model
        // (TownWall/GooseworldBridge/GooseworldMCPServer, all dependency-free).
        // EldrNodeCore itself does NOT depend on PQRCMCP — that boundary stands; the
        // WS-G5 `EldrNodeGooseworld` layer and the test target are what link it.
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
        // WS-G5: composes EldrNodeCore's town plane with PQRCMCP's wall model into the
        // production wall host + bridge + `eldr-gooseworld` socket host.
        .target(
            name: "EldrNodeGooseworld",
            dependencies: [
                "EldrNodeCore",
                "PQRCCore",
                "PQRCNostr",
                .product(name: "PQRCMCP", package: "PQRCMCP"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "eldr-node",
            dependencies: [
                "EldrNodeCore",
                "EldrNodeGooseworld",
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
        // WS-I5: the Eldr↔Buzz gateway library — reuses PQRCNostr's Buzz codecs
        // (NIP-OA/NIP-44/NIP-AM/NIP-AO builders) and PQRCACP's LLM client.
        .target(
            name: "EldrBuzzGateway",
            dependencies: [
                "PQRCCore",
                "PQRCNostr",
                .product(name: "PQRCACP", package: "PQRCACP"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "eldr-buzz-agent",
            dependencies: [
                "EldrBuzzGateway",
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
                "EldrNodeGooseworld",
                // The daemon target, so `SybilclawGatewayFramingTests` can `@testable import` it
                // and pin the node's gateway connect handshake against silent protocol re-drift.
                "eldr-node",
                "EldrBuzzGateway",
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
