// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCMCP

// EldrChat MCP server over stdio: read newline-delimited JSON-RPC from stdin,
// dispatch, write the response to stdout. Diagnostics go to stderr so they never
// corrupt the protocol stream. Backed by the demo bridge for now; the app wires a
// PersonaRuntime-backed (firewall-redacted) bridge later.
//
// Configure an MCP client (Goose / Xcode / Claude / OpenClaw) to launch this
// binary as a stdio server. No network, no ports — local-spawn trust only.

let server = MCPServer(bridge: DemoSecureChatBridge())
FileHandle.standardError.write(
    Data("pqrc-mcp: EldrChat MCP server (demo bridge) ready on stdio\n".utf8))

while let line = readLine(strippingNewline: true) {
    if let response = await server.handle(line: line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
