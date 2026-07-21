// SPDX-License-Identifier: Apache-2.0
import A2ACore
import Foundation

/// The client transport seam: anything that can carry one JSON-RPC request to an
/// A2A agent and return its response(s). `HTTPJSONRPCTransport` is the standard
/// HTTPS binding; the A2A-over-PQRC E2EE relay binding implements the same seam.
public protocol A2AClientTransport: Sendable {
    /// Send a unary request and await its response.
    func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse

    /// Send a streaming request (`SendStreamingMessage` / `SubscribeToTask`).
    /// The stream yields `StreamResponse` payloads in generation order and finishes
    /// when the server closes the stream (terminal task state) or throws on error.
    func stream(_ request: JSONRPCRequest) -> AsyncThrowingStream<A2AStreamResponse, Error>

    /// Release any underlying connections. Idempotent.
    func close() async
}

extension A2AClientTransport {
    public func close() async {}
}

/// Supplies request credentials. Implementations return a header name/value pair
/// (e.g. `Authorization: Bearer …` or an API-key header). Credentials are
/// operator-provisioned; OAuth token acquisition flows are out of scope for the SDK.
public protocol A2AAuthProvider: Sendable {
    func authorizationHeader() async throws -> (name: String, value: String)?
}

/// Static bearer-token auth (`Authorization: Bearer <token>`).
public struct A2ABearerAuth: A2AAuthProvider {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    public func authorizationHeader() async throws -> (name: String, value: String)? {
        ("Authorization", "Bearer \(token)")
    }
}

/// Static API-key auth in a named header.
public struct A2AAPIKeyAuth: A2AAuthProvider {
    private let headerName: String
    private let key: String

    public init(headerName: String, key: String) {
        self.headerName = headerName
        self.key = key
    }

    public func authorizationHeader() async throws -> (name: String, value: String)? {
        (headerName, key)
    }
}
