// SPDX-License-Identifier: Apache-2.0
import A2ACore
import A2AServer
import Foundation

enum Fixtures {
    static func card(extendedAgentCard: Bool? = nil) -> A2AAgentCard {
        A2AAgentCard(
            name: "Test Agent", description: "a test fixture agent",
            supportedInterfaces: [], version: "1.0",
            capabilities: A2AAgentCapabilities(
                streaming: true, extendedAgentCard: extendedAgentCard))
    }

    static func context(version: String? = "1.0") -> A2ARequestContext {
        A2ARequestContext(declaredVersion: version, isAuthenticated: true)
    }

    static func message(text: String = "hello") -> A2AMessage {
        A2AMessage(role: .user, parts: [.text(text)])
    }

    /// A typed-params request line.
    static func line(id: Int = 1, method: A2AMethod, params: some Encodable) throws -> String {
        let request = try JSONRPCRequest(id: .int(id), method: method, params: params)
        return try A2AWireCodec.encodeString(request)
    }

    /// A request line with no params at all (the four push-notification-config
    /// methods and GetExtendedAgentCard don't need a typed request model here since
    /// `A2AServer` never decodes their params).
    static func rawLine(id: Int = 1, method: A2AMethod) throws -> String {
        let request = JSONRPCRequest(id: .int(id), method: method.rawValue, params: nil)
        return try A2AWireCodec.encodeString(request)
    }

    enum FixtureError: Error { case unexpectedResponseShape }

    static func decodeSingle(_ response: A2AServer.Response?) throws -> JSONRPCResponse {
        guard case .single(let line) = response else {
            throw FixtureError.unexpectedResponseShape
        }
        return try A2AWireCodec.decode(JSONRPCResponse.self, from: line)
    }

    static func decodeStream(_ response: A2AServer.Response?) throws -> AsyncStream<String> {
        guard case .stream(let stream) = response else {
            throw FixtureError.unexpectedResponseShape
        }
        return stream
    }

    static func collectStreamResponses(_ stream: AsyncStream<String>) async throws
        -> [A2AStreamResponse]
    {
        var result: [A2AStreamResponse] = []
        for await line in stream {
            let decoded = try A2AWireCodec.decode(JSONRPCResponse.self, from: line)
            result.append(try decoded.decodeResult(A2AStreamResponse.self))
        }
        return result
    }
}
