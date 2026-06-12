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
        // SPEC §2 pin: >= 4.3.1 (CVE-2026-28815). Do not lower.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),
        // BIP-340 Schnorr for Nostr event signing (CryptoKit has no secp256k1).
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", from: "0.23.0"),
    ],
    targets: [
        .target(
            name: "PQRCNostr",
            dependencies: [
                "PQRCCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "P256K", package: "swift-secp256k1"),
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
            dependencies: ["PQRCNostr"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
