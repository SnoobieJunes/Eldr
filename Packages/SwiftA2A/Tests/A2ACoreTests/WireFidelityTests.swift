import Foundation
import Testing

@testable import A2ACore

// Wire-fidelity proofs: every fixture under Fixtures/ is frozen verbatim from the
// canonical JSON examples in a2aproject/A2A docs/specification.md (v1.0). Each test
// decodes the fixture into its typed model, re-encodes it, and requires semantic
// JSON equality with the original — so every field spelling, enum wire name, and
// oneof key is pinned to the spec, not to memory.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(name).json")
    return try Data(contentsOf: url)
}

/// Decode → encode → compare as parsed JSON trees (numeric equality is semantic).
private func assertRoundTrip<T: Codable & Equatable>(
    _ type: T.Type, fixtureNamed name: String
) throws {
    let original = try fixture(name)
    let decoded = try A2AWireCodec.decode(T.self, from: original)
    let reencoded = try A2AWireCodec.encode(decoded)

    let originalTree = try A2AWireCodec.decode(A2AJSONValue.self, from: original)
    let reencodedTree = try A2AWireCodec.decode(A2AJSONValue.self, from: reencoded)
    #expect(reencodedTree == originalTree, "re-encoded JSON diverges for \(name)")

    // And the decoded value itself must survive a full round trip.
    let redecoded = try A2AWireCodec.decode(T.self, from: reencoded)
    #expect(redecoded == decoded)
}

@Suite struct WireFidelityTests {
    @Test func agentCardFull() throws {
        try assertRoundTrip(A2AAgentCard.self, fixtureNamed: "agent-card-full")
    }

    @Test func agentCardFragmentWithSecuritySchemes() throws {
        try assertRoundTrip(A2AAgentCard.self, fixtureNamed: "security-schemes")
    }

    @Test func message() throws {
        try assertRoundTrip(A2AMessage.self, fixtureNamed: "message")
    }

    @Test func artifact() throws {
        try assertRoundTrip(A2AArtifact.self, fixtureNamed: "artifact")
    }

    @Test func partText() throws {
        try assertRoundTrip(A2APart.self, fixtureNamed: "part-text")
    }

    @Test func partRaw() throws {
        try assertRoundTrip(A2APart.self, fixtureNamed: "part-raw")
    }

    @Test func sendMessageResponseTask() throws {
        try assertRoundTrip(
            A2ASendMessageResponse.self, fixtureNamed: "send-message-response-task")
    }

    @Test func streamResponseStatusUpdate() throws {
        try assertRoundTrip(
            A2AStreamResponse.self, fixtureNamed: "stream-response-status-update")
    }

    @Test func supportedInterfaces() throws {
        // The fixture wraps an AgentInterface list demonstrating a custom
        // (extension-defined) protocolBinding URI.
        struct Wrapper: Codable, Equatable {
            var supportedInterfaces: [A2AAgentInterface]
        }
        try assertRoundTrip(Wrapper.self, fixtureNamed: "supported-interfaces")
    }

    @Test(arguments: [
        "rpc-get-task", "rpc-list-tasks", "rpc-cancel-task", "rpc-subscribe-task",
        "rpc-extended-card",
    ])
    func jsonRPCRequests(name: String) throws {
        try assertRoundTrip(JSONRPCRequest.self, fixtureNamed: name)
    }

    @Test(arguments: ["rpc-error-invalid-params", "rpc-error-task-not-found"])
    func jsonRPCErrorResponses(name: String) throws {
        try assertRoundTrip(JSONRPCResponse.self, fixtureNamed: name)
    }

    // Spot-pins for spellings that MUST match the spec even if fixtures evolve.
    @Test func pinnedWireSpellings() throws {
        #expect(A2ATaskState.inputRequired.wireName == "TASK_STATE_INPUT_REQUIRED")
        #expect(A2ATaskState.authRequired.wireName == "TASK_STATE_AUTH_REQUIRED")
        #expect(A2ARole.agent.wireName == "ROLE_AGENT")
        #expect(A2AMethod.sendMessage.rawValue == "SendMessage")
        #expect(A2AMethod.subscribeToTask.rawValue == "SubscribeToTask")
        #expect(A2AAgentCard.wellKnownPath == "/.well-known/agent-card.json")
        #expect(A2AErrorCode.taskNotFound.rawValue == -32001)
        #expect(A2AErrorCode.versionNotSupported.rawValue == -32009)
        #expect(A2AVersion.headerName == "A2A-Version")
    }

    @Test func typedParamsRoundTripThroughRequest() throws {
        let request = try JSONRPCRequest(
            id: .int(7), method: .getTask,
            params: A2AGetTaskRequest(id: "task-1", historyLength: 5))
        let line = try A2AWireCodec.encodeString(request)
        let decoded = try A2AWireCodec.decode(JSONRPCRequest.self, from: line)
        let params = try decoded.decodeParams(A2AGetTaskRequest.self)
        #expect(params.id == "task-1")
        #expect(params.historyLength == 5)
        #expect(decoded.method == "GetTask")
    }
}
