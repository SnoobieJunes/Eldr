// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import PQRCACP
import PQRCCore
import PQRCMCP
import PQRCNostr
import Testing

@testable import EldrNodeCore

// Phase D3 — the LOAD-BEARING security matrix for MCP passthrough over the relay,
// end-to-end over a `LocalRelaySimulator` with two real `PQRCMessenger`s.
//
// Roles (the real architecture):
//   NODE  = the Mac coding agent  = MCP CLIENT. Runs `EldrNodeCore.serve`, which now
//           wires an `MCPOverRelayClient` (the phone's chat tools) as the agent's
//           `extraTools`. A scripted LLM makes the agent CALL `mcp_read_conversation`
//           / `mcp_send_as_my_ai`, so the call genuinely round-trips the relay.
//   OWNER = the phone            = MCP SERVER. Modeled here by an `MCPServer(bridge:
//           DemoSecureChatBridge)` — the SAME redacting/window-gating server the phone
//           hosts (`RelayMCPHost` runs exactly this). Its reads return CODENAMES and
//           `send_as_my_ai` FAILS CLOSED unless a window is open. A `PhoneMCPTap`
//           routes the node's `MCP1|` request frames into it and frames the redacted
//           responses back over a `RelayMCPTransport`.
//
// The matrix proves, over the real wire:
//   (1) a consented node's agent calls a chat tool → it gets REDACTED output
//       (codenames, never real names) that crossed the relay;
//   (2) `mcp_send_as_my_ai` FAILS CLOSED when no AI window is open (and succeeds when
//       one is) — the node can't make the phone speak outside a human-opened window;
//   (3) the phone advertising NO `mcpServers` (its "share chat context" consent OFF)
//       ⇒ the node never advertises/routes the chat tools — the path is inert.
//
// `runACPAgent` + ToolExecutor are `#if os(macOS)`, so the suite is macOS-only.
#if os(macOS)
@Suite("MCP passthrough over relay — security (Phase D3)", .tags(.transport, .security))
struct MCPOverRelaySecurityTests {

    private let maxFrame = 16 * 1024

    private func makePair(seedBase: UInt64) async throws -> (
        owner: NodePersona, node: NodePersona, relay: LocalRelaySimulator
    ) {
        let relay = LocalRelaySimulator()
        let owner = try await NodePersona.make(
            name: "Owner", seedByte: "0a", seed: seedBase, transports: [await relay.connect()])
        let node = try await NodePersona.make(
            name: "Node", seedByte: "0b", seed: seedBase &+ 1, transports: [await relay.connect()])
        await owner.messenger.addContact(try node.asContact())
        await node.messenger.addContact(try owner.asContact())
        return (owner, node, relay)
    }

    /// The PHONE end of the MCP channel: drains the owner messenger's stream, routes
    /// the node's `MCP1|` request frames into an `MCPServer` (the redacting bridge),
    /// and frames the redacted responses back over a `RelayMCPTransport` to the node.
    /// Models `RelayMCPHost` exactly (same `MCPServer.handle` → bridge path). Also
    /// routes ACP frames into the phone's `RelayACPTransport` so the node can be driven.
    actor PhoneMCPTap {
        private var task: Task<Void, Never>?
        private let server: MCPServer
        private let mcpTransport: RelayMCPTransport
        private let acpRoute: @Sendable (String) async -> Void
        private let acpAccept: @Sendable (String) -> Bool
        private var pump: Task<Void, Never>?

        init(
            bridge: any SecureChatBridge,
            mcpTransport: RelayMCPTransport,
            acpAccept: @escaping @Sendable (String) -> Bool,
            acpRoute: @escaping @Sendable (String) async -> Void
        ) {
            self.server = MCPServer(bridge: bridge)
            self.mcpTransport = mcpTransport
            self.acpAccept = acpAccept
            self.acpRoute = acpRoute
        }

        func start(_ stream: AsyncStream<MessengerEvent>) {
            // Pump the MCP transport's reassembled request lines through the server and
            // frame each redacted response back — exactly RelayMCPHost.start().
            let server = self.server
            let mcpTransport = self.mcpTransport
            pump = Task {
                for await line in mcpTransport.inboundLines() {
                    guard let response = await server.handle(line: line) else { continue }
                    mcpTransport.send(response)
                }
            }
            task = Task {
                for await event in stream {
                    guard case .message(let m) = event else { continue }
                    await self.handle(m)
                }
            }
        }

        private func handle(_ m: ReceivedMessage) async {
            let body = m.body.text
            if RelayMCPTransport.isMCPFrame(body) {
                // The phone's C-3 owner pin is the node's identity check (acpAccept here
                // reused as the owner gate): only the paired node's MCP frames are served.
                guard acpAccept(m.senderIdentityHex) else { return }
                await mcpTransport.deliverInbound(body)
            } else if RelayACPTransport.isACPFrame(body) {
                guard acpAccept(m.senderIdentityHex) else { return }
                await acpRoute(body)
            }
        }

        /// Let the relay deliver the owner→node handshake so the node builds its
        /// responder session before the ACP client drives a turn. Deterministic settle
        /// (the phone tap doesn't observe the node's session state). Always true.
        func waitForHandshakeSettled(millis: Int = 400) async -> Bool {
            try? await Task.sleep(for: .milliseconds(millis))
            return true
        }

        func stop() {
            task?.cancel()
            pump?.cancel()
            mcpTransport.close()
        }
    }

    // MARK: - (1)+(2) consented node reads REDACTED chat; send_as_my_ai fails closed

    /// The node's agent (driven by a scripted LLM) calls `mcp_read_conversation` then
    /// `mcp_send_as_my_ai`. The read returns CODENAMES; the send FAILS CLOSED (no
    /// window). Everything crosses the real relay.
    @Test func consentedNode_readsRedacted_andSendFailsClosed() async throws {
        let pair = try await makePair(seedBase: 9_100)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex

        let workdir = try makeNodeWorkdir("mcp-redact")
        defer { try? FileManager.default.removeItem(atPath: workdir) }

        // Scripted node brain: turn 1 → call the chat READ tool; turn 2 → call
        // send_as_my_ai (which the phone refuses, no window); turn 3 → finish.
        let llm = ScriptedLLM([
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "r1", name: "mcp_read_conversation",
                        arguments: #"{"conversationID":"alice","limit":20}"#)
                ]),
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "s1", name: "mcp_send_as_my_ai",
                        arguments: #"{"conversationID":"alice","text":"auto reply"}"#)
                ]),
            LLMResponse(content: "done with chat tools"),
        ])

        // Phone → node ACP transport (the owner drives the node).
        let seq = NodeSeq()
        let phoneACP = RelayACPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        // Phone → node MCP transport (the phone's MCP responses go back to the node).
        let phoneMCP = RelayMCPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        // No active AI window anywhere ⇒ send_as_my_ai must fail closed.
        let tap = PhoneMCPTap(
            bridge: DemoSecureChatBridge(activeWindowConversationID: nil),
            mcpTransport: phoneMCP,
            acpAccept: { $0 == nodeHex },
            acpRoute: { [phoneACP] body in await phoneACP.deliverInbound(body) })
        await tap.start(try await owner.messenger.start())
        defer { Task { await tap.stop() } }

        // Launch the node serve loop — it wires the MCPOverRelayClient as extraTools.
        let serveTask = Task {
            let core = EldrNodeCore()
            await core.serve(
                messenger: PQRCNodeMessenger(messenger: node.messenger),
                ownerIdentityHex: ownerHex,
                maxFrameBytes: maxFrame,
                llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default,
                streamingEnabled: false)
        }
        defer { serveTask.cancel() }

        // Establish the owner→node session.
        try await owner.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        _ = await tap.waitForHandshakeSettled()

        // The phone is the CLIENT: advertise the chat tools (consent ON).
        let client = ACPClient(
            transport: phoneACP, permissionHandler: { _, _ in true }, advertiseChatTools: true)
        let uiEvents = NodeUIEventCollector()
        await uiEvents.attach(client.events)
        defer { Task { await uiEvents.stop() } }

        _ = try await withNodeTimeout(30, "client.start") { try await client.start(cwd: workdir) }

        // Prompt 1: the agent calls mcp_read_conversation → the REDACTED transcript
        // (codenames) must come back over the relay and surface as the tool result.
        let stop1 = try await withNodeTimeout(40, "prompt #1 (chat read)") {
            try await client.prompt("read my chat with alice")
        }
        #expect(stop1 == "end_turn")
        let toolText1 = await uiEvents.toolResultJoined(containing: "a contact")
        #expect(
            toolText1.contains("a contact"),
            "the chat tool result must be REDACTED codenames, returned over the relay; got: \(toolText1)")
        // And it must NOT contain a raw identity hex (the phone never emits one).
        #expect(!toolText1.contains(ownerHex), "no identity hex may appear in the chat tool result")
        #expect(!toolText1.contains(nodeHex), "no identity hex may appear in the chat tool result")

        // Prompt 2: the agent calls mcp_send_as_my_ai with NO window → FAIL CLOSED.
        let stop2 = try await withNodeTimeout(40, "prompt #2 (gated send)") {
            try await client.prompt("send a reply as my AI to alice")
        }
        #expect(stop2 == "end_turn")
        let toolText2 = await uiEvents.toolResultJoined(containing: "No active AI window")
        #expect(
            toolText2.contains("No active AI window"),
            "send_as_my_ai must FAIL CLOSED with no window (the node can't make the phone speak); got: \(toolText2)")

        await client.shutdown()
    }

    // MARK: - (2b) with a window open, the gated send SUCCEEDS

    @Test func consentedNode_sendSucceeds_whenWindowOpen() async throws {
        let pair = try await makePair(seedBase: 9_200)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex
        let workdir = try makeNodeWorkdir("mcp-window")
        defer { try? FileManager.default.removeItem(atPath: workdir) }

        let llm = ScriptedLLM([
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "s1", name: "mcp_send_as_my_ai",
                        arguments: #"{"conversationID":"alice","text":"auto reply"}"#)
                ]),
            LLMResponse(content: "sent"),
        ])

        let seq = NodeSeq()
        let phoneACP = RelayACPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        let phoneMCP = RelayMCPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        // A window IS open for "alice" → the gated send is allowed.
        let tap = PhoneMCPTap(
            bridge: DemoSecureChatBridge(activeWindowConversationID: "alice"),
            mcpTransport: phoneMCP,
            acpAccept: { $0 == nodeHex },
            acpRoute: { [phoneACP] body in await phoneACP.deliverInbound(body) })
        await tap.start(try await owner.messenger.start())
        defer { Task { await tap.stop() } }

        let serveTask = Task {
            let core = EldrNodeCore()
            await core.serve(
                messenger: PQRCNodeMessenger(messenger: node.messenger),
                ownerIdentityHex: ownerHex, maxFrameBytes: maxFrame, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default, streamingEnabled: false)
        }
        defer { serveTask.cancel() }

        try await owner.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        _ = await tap.waitForHandshakeSettled()

        let client = ACPClient(
            transport: phoneACP, permissionHandler: { _, _ in true }, advertiseChatTools: true)
        let uiEvents = NodeUIEventCollector()
        await uiEvents.attach(client.events)
        defer { Task { await uiEvents.stop() } }
        _ = try await withNodeTimeout(30, "client.start") { try await client.start(cwd: workdir) }

        let stop = try await withNodeTimeout(40, "prompt (gated send, window open)") {
            try await client.prompt("send a reply as my AI to alice")
        }
        #expect(stop == "end_turn")
        let toolText = await uiEvents.toolResultJoined(containing: "Sent as your AI")
        #expect(
            toolText.contains("Sent as your AI"),
            "with a window open the phone-gated send succeeds over the relay; got: \(toolText)")

        await client.shutdown()
    }

    // MARK: - (3) consent OFF (no mcpServers advertised) ⇒ chat tools inert

    /// When the phone does NOT advertise `mcpServers` (the "share chat context"
    /// consent is OFF), the node's agent must NOT see or call any chat tool — even
    /// though the `MCPOverRelayClient` is wired in `serve`. The gate is `ACPAgent`'s
    /// per-session `mcpServers` check. The phone serves nothing.
    @Test func noAdvertise_chatToolsAreInert() async throws {
        let pair = try await makePair(seedBase: 9_300)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex
        let workdir = try makeNodeWorkdir("mcp-inert")
        defer { try? FileManager.default.removeItem(atPath: workdir) }

        // The agent TRIES to call the chat tool on turn 1. With no advertisement the
        // tool isn't merged/routed → the built-in executor reports it unknown, and the
        // phone is asked nothing. Turn 2 finishes.
        let llm = ScriptedLLM([
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "r1", name: "mcp_read_conversation",
                        arguments: #"{"conversationID":"alice"}"#)
                ]),
            LLMResponse(content: "finished"),
        ])

        let seq = NodeSeq()
        let phoneACP = RelayACPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        let phoneMCP = RelayMCPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        // Track whether the phone's MCP server is EVER asked anything.
        let askedBridge = AskRecordingBridge()
        let tap = PhoneMCPTap(
            bridge: askedBridge, mcpTransport: phoneMCP,
            acpAccept: { $0 == nodeHex },
            acpRoute: { [phoneACP] body in await phoneACP.deliverInbound(body) })
        await tap.start(try await owner.messenger.start())
        defer { Task { await tap.stop() } }

        let serveTask = Task {
            let core = EldrNodeCore()
            await core.serve(
                messenger: PQRCNodeMessenger(messenger: node.messenger),
                ownerIdentityHex: ownerHex, maxFrameBytes: maxFrame, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default, streamingEnabled: false)
        }
        defer { serveTask.cancel() }

        try await owner.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        _ = await tap.waitForHandshakeSettled()

        // CONSENT OFF: advertiseChatTools = false (the default — the phone never opted in).
        let client = ACPClient(
            transport: phoneACP, permissionHandler: { _, _ in true }, advertiseChatTools: false)
        let uiEvents = NodeUIEventCollector()
        await uiEvents.attach(client.events)
        defer { Task { await uiEvents.stop() } }
        _ = try await withNodeTimeout(30, "client.start") { try await client.start(cwd: workdir) }

        let stop = try await withNodeTimeout(40, "prompt (inert chat tools)") {
            try await client.prompt("try to read my chat")
        }
        #expect(stop == "end_turn")

        // The phone's MCP server was NEVER asked a single tool (no read happened).
        try? await Task.sleep(for: .milliseconds(300))
        let asked = await askedBridge.callCount
        #expect(
            asked == 0,
            "with no mcpServers advertised the phone must serve NO chat tools (got \(asked) calls)")
    }

    /// A bridge that records whether ANY method was invoked — proves the phone serves
    /// nothing when the chat tools are inert. Returns empty/failed for everything.
    actor AskRecordingBridge: SecureChatBridge {
        private(set) var callCount = 0
        private func bump() { callCount += 1 }
        func conversations() async -> [MCPConversation] { bump(); return [] }
        func messages(conversationID: String, limit: Int) async -> [MCPMessage] { bump(); return [] }
        func search(query: String, limit: Int) async -> [MCPMessage] { bump(); return [] }
        func contextPreview(conversationID: String) async -> [MCPMessage] { bump(); return [] }
        func draftReply(conversationID: String, text: String) async -> MCPWriteResult {
            bump(); return .failedClosed(reason: "inert")
        }
        func markAIContext(conversationID: String, messageIDs: [String], value: Bool) async
            -> MCPWriteResult
        { bump(); return .failedClosed(reason: "inert") }
        func sendAsMyAI(conversationID: String, text: String) async -> MCPWriteResult {
            bump(); return .failedClosed(reason: "inert")
        }
    }
}
#endif  // os(macOS)
