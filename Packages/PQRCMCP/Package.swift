// swift-tools-version: 6.0
import PackageDescription

// PQRCMCP — EldrChat's local Model Context Protocol (MCP) server. Exposes the
// user's secure chat (read-only, firewall-redacted) to a LOCAL MCP client
// (Goose, Xcode, Claude, OpenClaw, …) over stdio JSON-RPC. The server is
// client-agnostic: any spec-compliant MCP client can use it.
//
// The library has NO app/crypto dependencies — it speaks MCP against a
// `SecureChatBridge` the app implements (firewall-redacted) and a demo bridge
// fakes, so the protocol is testable headlessly and runnable before the
// runtime bridge is wired. Builds/tests on macOS (`swift test`).
let package = Package(
    name: "PQRCMCP",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PQRCMCP", targets: ["PQRCMCP"]),
        .executable(name: "pqrc-mcp", targets: ["pqrc-mcp"]),
    ],
    targets: [
        .target(name: "PQRCMCP"),
        .executableTarget(name: "pqrc-mcp", dependencies: ["PQRCMCP"]),
        .testTarget(name: "PQRCMCPTests", dependencies: ["PQRCMCP"]),
    ]
)
