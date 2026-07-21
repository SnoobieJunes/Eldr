// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCMCP

/// Network-free protocol checks: drive `MCPServer.handle` with JSON-RPC lines and
/// assert the MCP shapes + the read/write contract — including the load-bearing
/// invariant that `send_as_my_ai` FAILS CLOSED with no active AI window (SPEC §13 /
/// CLAUDE.md invariant 9) and that messages arrive as codenames (invariant 8 honesty).
@Suite("MCP server")
struct MCPServerTests {
    /// No AI window open anywhere → `send_as_my_ai` must fail closed everywhere.
    private func server() -> MCPServer { MCPServer(bridge: DemoSecureChatBridge()) }
    /// An AI window is open for `conversationID` → `send_as_my_ai` is allowed there.
    private func server(windowOpenFor conversationID: String) -> MCPServer {
        MCPServer(bridge: DemoSecureChatBridge(activeWindowConversationID: conversationID))
    }

    /// Parse a `tools/call` response into (rendered text, isError).
    private func callResult(_ json: [String: Any]) throws -> (text: String, isError: Bool) {
        let result = try #require(json["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        return (text, (result["isError"] as? Bool) ?? false)
    }

    private func parse(_ string: String?) throws -> [String: Any] {
        let string = try #require(string)
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
        return try #require(object as? [String: Any])
    }

    @Test func initialize_returnsProtocolCapabilitiesAndServerInfo() async throws {
        let response = await server().handle(
            line:
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#
        )
        let json = try parse(response)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2024-11-05")
        let serverInfo = result["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "eldrchat")
        let caps = result["capabilities"] as? [String: Any]
        #expect(caps?["tools"] != nil)
        #expect(caps?["resources"] != nil)
    }

    @Test func initialize_echoesNewerKnownVersion() async throws {
        let response = await server().handle(
            line:
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        )
        let result = try #require(try parse(response)["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
    }

    @Test func notification_initialized_producesNoResponse() async {
        let response = await server().handle(
            line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(response == nil)
    }

    @Test func toolsList_exposesReadAndWindowGatedWriteTools() async throws {
        let json = try parse(await server().handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        // Reads stay.
        #expect(names.contains("list_conversations"))
        #expect(names.contains("read_conversation"))
        #expect(names.contains("search_messages"))
        #expect(names.contains("get_context_preview"))
        // Writes (A35 Phase 3): draft + mark (always safe) and the window-gated send.
        #expect(names.contains("draft_reply"))
        #expect(names.contains("mark_ai_context"))
        #expect(names.contains("send_as_my_ai"))
        // The ONLY send tool is the agent-labeled, window-gated one — there is no
        // tool that posts as the human or sends outside the window gate (invariants 8 + 9).
        let sendTools = names.filter { $0.contains("send") || $0.contains("post") }
        #expect(sendTools == ["send_as_my_ai"])
        // The send tool's description names the window gate so a model knows it can fail.
        let sendDesc = tools.first { $0["name"] as? String == "send_as_my_ai" }?["description"] as? String
        #expect(sendDesc?.localizedCaseInsensitiveContains("window") == true)
    }

    @Test func initialize_instructionsDescribeWindowGating() async throws {
        let json = try parse(
            await server().handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        let instructions = try #require((json["result"] as? [String: Any])?["instructions"] as? String)
        #expect(instructions.localizedCaseInsensitiveContains("draft"))
        #expect(instructions.localizedCaseInsensitiveContains("window"))
        // It must be explicit that the agent can't speak as the human.
        #expect(instructions.localizedCaseInsensitiveContains("labeled"))
    }

    @Test func draftReply_succeeds_andDoesNotClaimToSend() async throws {
        let json = try parse(
            await server().handle(
                line:
                    #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"draft_reply","arguments":{"conversationID":"alice","text":"On my way"}}}"#
            ))
        let (text, isError) = try callResult(json)
        #expect(isError == false)  // a draft never errors and never sends
        #expect(text.localizedCaseInsensitiveContains("draft"))
        #expect(text.contains("On my way"))
    }

    @Test func markAIContext_succeeds() async throws {
        let json = try parse(
            await server().handle(
                line:
                    #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"mark_ai_context","arguments":{"conversationID":"alice","messageIDs":["m1","m2"],"value":true}}}"#
            ))
        let (text, isError) = try callResult(json)
        #expect(isError == false)
        #expect(text.contains("2"))  // two messages marked
    }

    @Test func sendAsMyAI_failsClosed_withNoActiveWindow() async throws {
        // No window open anywhere: the send MUST be refused (isError) and post nothing.
        let json = try parse(
            await server().handle(
                line:
                    #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"send_as_my_ai","arguments":{"conversationID":"alice","text":"hi from the agent"}}}"#
            ))
        let (text, isError) = try callResult(json)
        #expect(isError == true)  // fail closed — surfaced as an error, not a silent drop
        #expect(text.localizedCaseInsensitiveContains("window"))
        #expect(!text.contains("hi from the agent"))  // the body was NOT posted
    }

    @Test func sendAsMyAI_succeeds_onlyInTheConversationWithAnOpenWindow() async throws {
        let srv = server(windowOpenFor: "alice")
        // Allowed in the windowed conversation.
        let ok = try parse(
            await srv.handle(
                line:
                    #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"send_as_my_ai","arguments":{"conversationID":"alice","text":"posted by AI"}}}"#
            ))
        let (okText, okIsError) = try callResult(ok)
        #expect(okIsError == false)
        #expect(okText.contains("posted by AI"))

        // A DIFFERENT conversation has no window → still fails closed (the gate is
        // per-conversation, so one open window can't be reused elsewhere).
        let blocked = try parse(
            await srv.handle(
                line:
                    #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"send_as_my_ai","arguments":{"conversationID":"bob","text":"should not post"}}}"#
            ))
        let (_, blockedIsError) = try callResult(blocked)
        #expect(blockedIsError == true)
    }

    @Test func writeTools_missingRequiredArgs_areInvalidParams() async throws {
        // draft_reply without text.
        let noText = try parse(
            await server().handle(
                line:
                    #"{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"draft_reply","arguments":{"conversationID":"alice"}}}"#
            ))
        #expect((noText["error"] as? [String: Any])?["code"] as? Int == -32602)
        // mark_ai_context without value.
        let noValue = try parse(
            await server().handle(
                line:
                    #"{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"mark_ai_context","arguments":{"conversationID":"alice","messageIDs":["m1"]}}}"#
            ))
        #expect((noValue["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func toolsCall_listConversations_returnsTextContent() async throws {
        let json = try parse(
            await server().handle(
                line:
                    #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_conversations","arguments":{}}}"#
            ))
        let content = try #require((json["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("Alice"))
        #expect(text.contains("id: alice"))
    }

    @Test func toolsCall_readConversation_returnsCodenamesNotIdentities() async throws {
        let json = try parse(
            await server().handle(
                line:
                    #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_conversation","arguments":{"conversationID":"alice"}}}"#
            ))
        let text = try #require(
            ((json["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"]
                as? String)
        #expect(text.contains("handshake"))
        // Sender labels are codenames the bridge already redacted — never identity hex.
        #expect(text.contains("you:") || text.contains("a contact:"))
        #expect(text.contains("(AI)"))  // agent messages stay labeled as AI (participant_type honesty)
    }

    @Test func toolsCall_missingRequiredArg_isInvalidParams() async throws {
        let json = try parse(
            await server().handle(
                line:
                    #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_conversation","arguments":{}}}"#
            ))
        #expect((json["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func resources_listAndRead() async throws {
        let listed = try parse(await server().handle(line: #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#))
        let resources = try #require((listed["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        let uri = try #require(resources.first?["uri"] as? String)
        #expect(uri.hasPrefix("eldrchat://conversation/"))

        let read = try parse(
            await server().handle(
                line:
                    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/read\",\"params\":{\"uri\":\"\(uri)\"}}"
            ))
        let contents = try #require((read["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        #expect(contents.first?["uri"] as? String == uri)
    }

    @Test func unknownMethod_returnsMethodNotFound() async throws {
        let json = try parse(await server().handle(line: #"{"jsonrpc":"2.0","id":8,"method":"does/notExist"}"#))
        #expect((json["error"] as? [String: Any])?["code"] as? Int == -32601)
    }
}
