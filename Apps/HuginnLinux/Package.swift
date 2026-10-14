// swift-tools-version:6.2
// SPDX-License-Identifier: AGPL-3.0-only
import PackageDescription

// HuginnLinux — the Linux edition of Huginn (WS-N10, docs/plan/HUGINN-LINUX.md).
//
// Huginn's sources are AGPL-3.0-only, so this lives beside Apps/Huginn as its own AGPL
// package instead of inside the Apache EldrLinux package (DEVIATIONS AC203).
//  - HuginnCore: UI-free services (config env file, keystore secrets, installer +
//    launcher, LLM health, log tailing, project-memory learner, test chat, child-process
//    supervisor for eldr-node / eldr-buzz-agent, Buzz connections, relay provisioner,
//    world status, harness registration). Tested everywhere.
//  - huginn-cli: headless front end; also what the eldr-acp launcher calls for secrets.
//  - huginn-gtk: the GTK 4 app (Linux only), on EldrLinux's GtkKit.
// Dependencies: in-repo packages + Apple swift-crypto only.
var products: [Product] = [
    .library(name: "HuginnCore", targets: ["HuginnCore"]),
    .executable(name: "huginn-cli", targets: ["huginn-cli"]),
]
var deps: [Package.Dependency] = [
    .package(path: "../../Packages/PQRCCore"),
    .package(path: "../../Packages/PQRCNostr"),
    .package(path: "../../Packages/PQRCACP"),
    .package(path: "../../Packages/EldrKeystore"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),
]
var extra: [Target] = []
#if os(Linux)
products.append(.executable(name: "huginn-gtk", targets: ["huginn-gtk"]))
deps.append(.package(path: "../../Packages/EldrLinux"))
extra.append(
    .executableTarget(
        name: "huginn-gtk",
        dependencies: [
            "HuginnCore",
            .product(name: "GtkKit", package: "EldrLinux"),
            .product(name: "PQRCACP", package: "PQRCACP"),
            .product(name: "PQRCNostr", package: "PQRCNostr"),
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]))
#endif

let package = Package(
    name: "HuginnLinux",
    platforms: [.macOS(.v26)],
    products: products,
    dependencies: deps,
    targets: [
        .target(
            name: "HuginnCore",
            dependencies: [
                .product(name: "PQRCCore", package: "PQRCCore"),
                .product(name: "PQRCNostr", package: "PQRCNostr"),
                .product(name: "PQRCACP", package: "PQRCACP"),
                .product(name: "EldrKeystore", package: "EldrKeystore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "huginn-cli",
            dependencies: [
                "HuginnCore",
                .product(name: "PQRCACP", package: "PQRCACP"),
                .product(name: "PQRCNostr", package: "PQRCNostr"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "HuginnCoreTests",
            dependencies: [
                "HuginnCore",
                .product(name: "PQRCCore", package: "PQRCCore"),
                .product(name: "PQRCNostr", package: "PQRCNostr"),
                .product(name: "PQRCACP", package: "PQRCACP"),
                .product(name: "EldrKeystore", package: "EldrKeystore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ] + extra
)
