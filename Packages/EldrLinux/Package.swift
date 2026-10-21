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
var products: [Product] = [
    .library(name: "EldrClientCore", targets: ["EldrClientCore"]),
    .executable(name: "eldr-chat", targets: ["eldr-chat"]),
]
var extraTargets: [Target] = [
    // GTK-free presentation logic (tested everywhere).
    .target(name: "EldrUIModel", dependencies: ["EldrClientCore", "PQRCCore", "PQRCNostr", .product(name: "PQRCAgent", package: "PQRCAgent")],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "EldrUIModelTests",
                dependencies: ["EldrUIModel", "EldrClientCore", "PQRCCore", "PQRCNostr", .product(name: "PQRCAgent", package: "PQRCAgent")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
]
#if os(Linux)
// Milestone 3: the native GTK 4 desktop app. GTK's C API is imported directly through a
// system-library module (no third-party bindings); `GtkKit` is our own thin wrapper.
products.append(.executable(name: "eldr-gtk", targets: ["eldr-gtk"]))
// WS-N10: GtkKit is also a library product so the AGPL HuginnLinux package can reuse it.
products.append(.library(name: "GtkKit", targets: ["GtkKit"]))
extraTargets += [
    .systemLibrary(name: "CGtk4", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
    .target(name: "GtkKit", dependencies: ["CGtk4"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "eldr-gtk",
                      dependencies: ["GtkKit", "EldrUIModel", "EldrClientCore", "PQRCCore", "PQRCNostr"],
                      swiftSettings: [.swiftLanguageMode(.v5)]),
]
#endif

let package = Package(
    name: "EldrLinux",
    platforms: [.macOS(.v26)],
    products: products,
    dependencies: [
        .package(path: "../PQRCCore"),
        .package(path: "../PQRCNostr"),
        .package(path: "../PQRCAgent"),
        .package(path: "../EldrKeystore"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),
    ],
    targets: [
        .target(
            name: "EldrClientCore",
            dependencies: [
                "PQRCCore",
                "PQRCNostr",
                .product(name: "PQRCAgent", package: "PQRCAgent"),
                .product(name: "EldrKeystore", package: "EldrKeystore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "eldr-chat",
            dependencies: ["EldrClientCore", "PQRCCore", "PQRCNostr", .product(name: "PQRCAgent", package: "PQRCAgent"), .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EldrClientCoreTests",
            dependencies: [
                "EldrClientCore", "EldrUIModel", "PQRCCore", "PQRCNostr",
                .product(name: "PQRCAgent", package: "PQRCAgent"),
                .product(name: "EldrKeystore", package: "EldrKeystore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ] + extraTargets
)
