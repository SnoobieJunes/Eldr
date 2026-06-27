// swift-tools-version:6.2
import PackageDescription

// Eldrctl — the conduit installer that provisions a Mac for Eldr "conduit" mode over SSH.
// Zero dependencies (CLAUDE.md): `ConduitProvisioner` is a pure, testable generator of the
// idempotent `install-huginn.sh` + the argv the CLI feeds it; `eldrctl` is a thin ssh/scp
// driver. Runs on the controller Mac (macOS 14+), so it does NOT need the macOS-26 baseline
// the on-device packages target — it only shells out to ssh/scp.
let package = Package(
    name: "Eldrctl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConduitProvisioner", targets: ["ConduitProvisioner"]),
        .executable(name: "eldrctl", targets: ["eldrctl"]),
    ],
    targets: [
        .target(
            name: "ConduitProvisioner",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "eldrctl",
            dependencies: ["ConduitProvisioner"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConduitProvisionerTests",
            dependencies: ["ConduitProvisioner"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
