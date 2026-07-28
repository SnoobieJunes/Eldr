// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "PQRCNostr",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PQRCNostr", targets: ["PQRCNostr"]),
        // S2: localhost NIP-01/NIP-42 WebSocket relay for demos and the
        // gated loopback conformance tests (`swift run pqrc-relay`).
        .executable(name: "pqrc-relay", targets: ["pqrc-relay"]),
    ],
    dependencies: [
        .package(path: "../PQRCCore"),
        // The ACP line-transport seam (`ACPTransport`). PQRCACP is zero-dependency,
        // so PQRCNostr → PQRCACP is a clean one-way edge (no cycle): PQRCACP imports
        // nothing from here. `NearbyACPTransport` conforms PQRCNostr's sealed Nearby
        // link to that seam, so the phone↔Mac ACP channel is confidential +
        // authenticated per line (ACPRouterplan P-4/P-8).
        .package(path: "../PQRCACP"),
        // SPEC §2 pin: >= 4.3.1 (CVE-2026-28815). Do not lower.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),
        // BIP-340 Schnorr for Nostr event signing (CryptoKit has no secp256k1).
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", from: "0.23.0"),
        // WS-L5: the Linux relay transport. `URLSessionWebSocketTask` is non-functional on
        // swift-corelibs ("WebSockets not supported by libcurl"), so the Linux node dials the
        // wss:// relay over SwiftNIO instead (NIO WebSocket + NIOSSL for TLS). Linked ONLY on
        // Linux (see the target) — Apple keeps URLSession, so the iOS app never pulls NIO.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "PQRCNostr",
            dependencies: [
                "PQRCCore",
                .product(name: "PQRCACP", package: "PQRCACP"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "P256K", package: "swift-secp256k1"),
                // Linux-only WebSocket+TLS relay transport (WS-L5). On Apple these are absent
                // and the target links no NIO.
                .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "NIOWebSocket", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "pqrc-relay",
            dependencies: ["PQRCNostr"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PQRCNostrTests",
            dependencies: [
                "PQRCNostr",
                // Linux-only: the WS-L5 loopback test stands up a NIO WebSocket echo server to
                // exercise NIOWebSocketChannel. Absent on Apple (that test is `#if os(Linux)`).
                .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.linux])),
                .product(name: "NIOWebSocket", package: "swift-nio", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
