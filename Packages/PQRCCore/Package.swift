// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "PQRCCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PQRCCore", targets: ["PQRCCore"])
    ],
    dependencies: [
        // SPEC §2: swift-crypto >= 4.3.1 REQUIRED (X-Wing decapsulation CVE-2026-28815 fix).
        // Do not lower this pin.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1")
    ],
    targets: [
        .target(
            name: "PQRCCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: [
                // Swift 6 language mode == -strict-concurrency=complete (CLAUDE.md requirement).
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "PQRCCoreTests",
            dependencies: ["PQRCCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
