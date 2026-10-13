// swift-tools-version:6.2
import PackageDescription

// EldrLinux — the native Linux client (Milestone 1: `eldr-chat` CLI).
//
// `EldrClientCore` is the reusable, UI-free client engine (encrypted-at-rest state,
// contacts, sessions, requests inbox, pairing links) built ONLY on PQRCCore + PQRCNostr;
// `eldr-chat` is the command-line front end, also the surface an AI agent drives.
// Later targets (GTK desktop via a system-library module map) build on the same core.
//
// Dependencies: only the in-repo PQRC packages, EldrKeystore (the keystore shared with
// eldr-node) and Apple's swift-crypto. The relay socket on Linux comes from PQRCNostr's
// NIONostrTransport (Apple swift-nio), since URLSessionWebSocketTask is unsupported on
// Linux FoundationNetworking.
let package = Package(
    name: "EldrLinux",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EldrClientCore", targets: ["EldrClientCore"]),
        .executable(name: "eldr-chat", targets: ["eldr-chat"]),
    ],
    dependencies: [
        .package(path: "../PQRCCore"),
        .package(path: "../PQRCNostr"),
        .package(path: "../EldrKeystore"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),
    ],
    targets: [
        .target(
            name: "EldrClientCore",
            dependencies: [
                "PQRCCore",
                "PQRCNostr",
                .product(name: "EldrKeystore", package: "EldrKeystore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "eldr-chat",
            dependencies: ["EldrClientCore", "PQRCCore", "PQRCNostr"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EldrClientCoreTests",
            dependencies: [
                "EldrClientCore", "PQRCCore", "PQRCNostr",
                .product(name: "EldrKeystore", package: "EldrKeystore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
