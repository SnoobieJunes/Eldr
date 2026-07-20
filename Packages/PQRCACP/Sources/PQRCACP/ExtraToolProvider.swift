// SPDX-License-Identifier: Apache-2.0
import Foundation

// Phase D3 — MCP passthrough over the relay, the PQRCACP (dependency-free) seam.
//
// GOAL: let the node's ACP coding agent ALSO use a SECOND set of tools that the
// node itself does not implement — specifically, the PHONE's MCP chat tools (read
// redacted conversations, draft replies, search), so the coding agent shares chat
// context. The agent must stay ignorant of *where* those tools live or *how* they
// are served; that knowledge belongs to the implementation, not to `ACPAgent`.
//
// `ExtraToolProvider` is that seam. `ACPAgent` takes an optional provider, merges
// its `toolDefinitions()` into the tools it advertises to the LLM, and routes any
// tool the provider owns to `provider.call(...)` instead of the built-in
// `ToolExecutor`. PQRCACP therefore gains MCP-passthrough capability WITHOUT
// importing PQRCMCP, PQRCCore, or any networking — the concrete provider
// (`MCPOverRelayClient`, below) speaks MCP JSON-RPC over an injected line seam, and
// the relay/crypto layer that backs that seam is wired by the node integration.
//
// Security note (why this is safe): the provider only ever exposes tools the PHONE
// chose to serve, and every call round-trips to the phone, which answers from its
// redacting + ai_window-gating `MCPServer`. The node — and this seam — never see
// unredacted chat, and a write the agent attempts (`send_as_my_ai`) is gated
// phone-side exactly as a local MCP client's would be. See `MCPOverRelayClient`.

/// A source of EXTRA tools the agent can call, beyond its built-in `ToolExecutor`
/// file/shell tools. `Sendable` so it can be injected into the actor-isolated
/// `ACPAgent` and called across its turn loop.
///
/// The agent treats these as opaque: it advertises whatever `toolDefinitions()`
/// returns and, when the model calls a tool whose name appears in that set, hands
/// the call to `call(name:arguments:)`. The result is a `ToolResult` (the same type
/// the built-in executor returns), so the turn loop is uniform regardless of which
/// side actually ran the tool.
public protocol ExtraToolProvider: Sendable {
    /// The tool/function definitions to advertise to the LLM, in addition to the
    /// built-in ones. May be empty (e.g. before a remote handshake completes), in
    /// which case nothing extra is advertised and nothing is routed here.
    func toolDefinitions() async -> [LLMTool]
    /// Execute one tool this provider owns. `name` is guaranteed by `ACPAgent` to be
    /// one of the names `toolDefinitions()` returned; `arguments` is the decoded
    /// model-produced argument object. Returns a `ToolResult` (text fed back to the
    /// model, plus an `isError` flag) — a failure (transport down, the phone refused)
    /// comes back as `ToolResult(text:isError:true)`, never a throw, so the turn loop
    /// surfaces it as a tool error and keeps going.
    func call(name: String, arguments: JSONValue) async -> ToolResult
}
