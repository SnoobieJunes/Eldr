// swift-tools-version: 6.0
import PackageDescription

// PQRCMCP — EldrChat's local Model Context Protocol (MCP) server. Exposes the
// user's secure chat (firewall-redacted reads + window-gated write tools) to a
// LOCAL MCP client (Goose, Xcode, Claude, OpenClaw, …) over stdio JSON-RPC. The
// server is client-agnostic: any spec-compliant MCP client can use it. The write
// tools reuse the app's existing send/draft/mark paths and preserve the hard
// invariants (agent-labeled + ai_window-gated send; see SecureChatBridge).
//
// The library has NO app/crypto dependencies — it speaks MCP against a
// `SecureChatBridge` the app implements (firewall-redacted) and a demo bridge
// fakes, so the protocol is testable headlessly and runnable before the
// runtime bridge is wired. Builds/tests on macOS (`swift test`).
let package = Package(
    name: "PQRCMCP",
    // Floor is intentionally lower than the v26 app fleet: PQRCMCP is a headless,
    // dependency-free MCP server + stdio shim with no v26-SDK needs, kept broadly
    // portable so the bridge binary runs across a wider range of hosts. (swift-tools
    // 6.0 above is deliberate for the same reason — no 6.2 manifest features are used.)
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PQRCMCP", targets: ["PQRCMCP"]),
        .executable(name: "pqrc-mcp", targets: ["pqrc-mcp"]),
        // The stdio↔in-app-server SHIM (A35 Phase 2): the binary Goose/Xcode
        // actually spawn to read REAL secure chat. NO MCP logic — it just bridges
        // the editor's stdio to the loopback socket the unlocked app is hosting.
        .executable(name: "pqrc-mcp-bridge", targets: ["pqrc-mcp-bridge"]),
    ],
    targets: [
        .target(name: "PQRCMCP"),
        .executableTarget(name: "pqrc-mcp", dependencies: ["PQRCMCP"]),
        // Deliberately depends on NOTHING (not even PQRCMCP): it carries no
        // protocol knowledge, only raw byte plumbing.
        .executableTarget(name: "pqrc-mcp-bridge"),
        .testTarget(name: "PQRCMCPTests", dependencies: ["PQRCMCP"]),
    ]
)
