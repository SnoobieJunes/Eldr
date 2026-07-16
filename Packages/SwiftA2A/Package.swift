// swift-tools-version: 6.0
import PackageDescription

// SwiftA2A — a clean-room Swift SDK for the Agent2Agent (A2A) protocol v1.0
// (https://a2a-protocol.org, Linux Foundation). Zero non-Apple dependencies by
// design: this package is built to be extracted to a standalone public repo and
// proposed to the a2aproject as the official Swift SDK, so nothing in here may
// depend on the rest of the Eldr workspace.
//
// Wire-format source of truth: specification/a2a.proto (package lf.a2a.v1) with
// the proto3 canonical JSON mapping, cross-checked against the JSON examples in
// docs/specification.md — frozen copies of those examples live in
// Tests/A2ACoreTests/Fixtures and the round-trip tests pin every spelling.
let package = Package(
    name: "SwiftA2A",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "A2ACore", targets: ["A2ACore"]),
        .library(name: "A2AClient", targets: ["A2AClient"]),
        .library(name: "A2AServer", targets: ["A2AServer"]),
        .library(name: "A2AHTTPServer", targets: ["A2AHTTPServer"]),
    ],
    targets: [
        .target(name: "A2ACore"),
        .target(name: "A2AClient", dependencies: ["A2ACore"]),
        // Transport-agnostic server core: business logic (`AgentExecutor`) plugs in;
        // no networking here at all, so it builds and tests on every platform.
        .target(name: "A2AServer", dependencies: ["A2ACore"]),
        // The macOS-only Network.framework HTTP binding on top of A2AServer. Every
        // source file wraps its contents in `#if os(macOS)` (see CLAUDE.md-style
        // rationale in the files themselves) rather than gating the target in this
        // manifest, so the target declaration itself stays platform-unconditional
        // and simple; on non-macOS platforms the target just compiles empty.
        .target(name: "A2AHTTPServer", dependencies: ["A2AServer", "A2ACore"]),
        .testTarget(
            name: "A2ACoreTests",
            dependencies: ["A2ACore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "A2AClientTests",
            dependencies: ["A2AClient"]
        ),
        .testTarget(
            name: "A2AServerTests",
            dependencies: ["A2AServer"]
        ),
        .testTarget(
            name: "A2AHTTPServerTests",
            dependencies: ["A2AHTTPServer", "A2AServer", "A2ACore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
