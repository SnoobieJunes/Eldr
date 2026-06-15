import Foundation
import Testing

@testable import PQRCMCP

/// Network-free protocol checks: drive `MCPServer.handle` with JSON-RPC lines and
/// assert the MCP shapes + that the read-only contract holds (no write tools, data
/// arrives as codenames).
@Suite("MCP server")
struct MCPServerTests {
    private func server() -> MCPServer { MCPServer(bridge: DemoSecureChatBridge()) }

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

    @Test func toolsList_isReadOnly_noWriteTools() async throws {
        let json = try parse(await server().handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.contains("list_conversations"))
        #expect(names.contains("read_conversation"))
        #expect(names.contains("search_messages"))
        #expect(names.contains("get_context_preview"))
        // Read-only contract: no post/send/write tool is exposed (no autonomous send).
        #expect(!names.contains { $0.contains("post") || $0.contains("send") || $0.contains("write") })
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
