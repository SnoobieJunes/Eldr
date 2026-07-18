import A2ACore
import Foundation

/// The high-level A2A client: builds typed JSON-RPC requests, sends them over a
/// pluggable `A2AClientTransport`, and decodes typed results.
///
/// An actor because request-id allocation is mutable state shared across
/// concurrent callers; the transport itself does the actual I/O.
public actor A2AClient {
    private let transport: any A2AClientTransport
    private let tenant: String
    private let activeExtensions: [String]
    private var nextID: Int = 1

    public init(
        transport: any A2AClientTransport, tenant: String = "",
        activeExtensions: [String] = []
    ) {
        self.transport = transport
        self.tenant = tenant
        self.activeExtensions = activeExtensions
    }

    /// Resolve an agent's card and connect to its preferred JSON-RPC interface in
    /// one step.
    public static func connecting(
        cardURL: URL, session: URLSession = .shared, auth: (any A2AAuthProvider)? = nil,
        verifier: any AgentCardSignatureVerifier = NoopAgentCardSignatureVerifier(),
        activeExtensions: [String] = []
    ) async throws -> (client: A2AClient, card: A2AAgentCard) {
        let resolver = AgentCardResolver(session: session, verifier: verifier)
        let (card, _) = try await resolver.fetch(from: cardURL)

        guard
            let interface = card.preferredInterface(
                binding: A2AAgentInterface.jsonRPCBinding)
        else {
            throw A2AClientError.noUsableInterface
        }
        guard A2AVersion.isSupported(interface.protocolVersion) else {
            throw A2AClientError.invalidAgentCard(
                "interface protocol version \(interface.protocolVersion) is not supported"
            )
        }
        guard let endpoint = URL(string: interface.url) else {
            throw A2AClientError.invalidAgentCard(
                "interface url \(interface.url) is not a valid URL")
        }

        let transport = HTTPJSONRPCTransport(
            endpoint: endpoint, session: session, auth: auth,
            activeExtensions: activeExtensions)
        let client = A2AClient(
            transport: transport, tenant: interface.tenant ?? "",
            activeExtensions: activeExtensions)
        return (client, card)
    }

    /// Allocate the next JSON-RPC request id for this client.
    private func allocateID() -> JSONRPCID {
        defer { nextID += 1 }
        return .int(nextID)
    }

    public func sendMessage(
        _ message: A2AMessage, configuration: A2ASendMessageConfiguration? = nil
    ) async throws -> A2ASendMessageResponse {
        let params = A2ASendMessageRequest(
            tenant: tenant, message: message, configuration: configuration)
        let request = try JSONRPCRequest(
            id: allocateID(), method: A2AMethod.sendMessage, params: params)
        let response = try await transport.send(request)
        return try response.decodeResult(A2ASendMessageResponse.self)
    }

    public func streamMessage(
        _ message: A2AMessage, configuration: A2ASendMessageConfiguration? = nil
    ) async throws -> AsyncThrowingStream<A2AStreamResponse, Error> {
        let params = A2ASendMessageRequest(
            tenant: tenant, message: message, configuration: configuration)
        let request = try JSONRPCRequest(
            id: allocateID(), method: A2AMethod.sendStreamingMessage, params: params)
        return transport.stream(request)
    }

    public func getTask(id: String, historyLength: Int? = nil) async throws -> A2ATask {
        let params = A2AGetTaskRequest(tenant: tenant, id: id, historyLength: historyLength)
        let request = try JSONRPCRequest(
            id: allocateID(), method: A2AMethod.getTask, params: params)
        let response = try await transport.send(request)
        return try response.decodeResult(A2ATask.self)
    }

    public func listTasks(_ request: A2AListTasksRequest = .init()) async throws
        -> A2AListTasksResponse
    {
        var params = request
        if !tenant.isEmpty { params.tenant = tenant }
        let rpcRequest = try JSONRPCRequest(
            id: allocateID(), method: A2AMethod.listTasks, params: params)
        let response = try await transport.send(rpcRequest)
        return try response.decodeResult(A2AListTasksResponse.self)
    }

    public func cancelTask(id: String) async throws -> A2ATask {
        let params = A2ACancelTaskRequest(tenant: tenant, id: id)
        let request = try JSONRPCRequest(
            id: allocateID(), method: A2AMethod.cancelTask, params: params)
        let response = try await transport.send(request)
        return try response.decodeResult(A2ATask.self)
    }

    public func subscribeToTask(id: String) async throws -> AsyncThrowingStream<
        A2AStreamResponse, Error
    > {
        let params = A2ASubscribeToTaskRequest(tenant: tenant, id: id)
        let request = try JSONRPCRequest(
            id: allocateID(), method: A2AMethod.subscribeToTask, params: params)
        return transport.stream(request)
    }

    public func getExtendedAgentCard() async throws -> A2AAgentCard {
        let params = A2AGetExtendedAgentCardRequest(tenant: tenant)
        let request = try JSONRPCRequest(
            id: allocateID(), method: A2AMethod.getExtendedAgentCard, params: params)
        let response = try await transport.send(request)
        return try response.decodeResult(A2AAgentCard.self)
    }

    public func shutdown() async {
        await transport.close()
    }
}
