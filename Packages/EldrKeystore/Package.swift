// swift-tools-version:6.2
import PackageDescription

// EldrKeystore — the ONE Linux keystore implementation shared by eldr-node and the Linux
// client (EldrClientCore). Per-account AES-256-GCM files under a 256-bit master key, the
// master key protected by the invariant-10 ladder: TPM-sealed systemd credential →
// refuse-if-TPM-unused → scrypt passphrase. Each consumer passes a `KeystoreProfile`
// (its own dir, env names, HKDF label, credential name), so identities and state stay
// separate — only the code is shared. Depends only on swift-crypto (+ CryptoExtras).
let package = Package(
    name: "EldrKeystore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "EldrKeystore", targets: ["EldrKeystore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1")
    ],
    targets: [
        .target(
            name: "EldrKeystore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EldrKeystoreTests",
            dependencies: ["EldrKeystore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
