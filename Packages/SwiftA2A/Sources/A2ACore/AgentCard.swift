import Foundation

// `AgentCard` and its component types from lf.a2a.v1 (a2a.proto). The card is the
// agent's self-describing manifest, discovered at
// `https://{host}/.well-known/agent-card.json` for HTTP bindings (other transports
// may exchange it in-band).

/// A transport binding the agent is reachable over (`AgentInterface`).
/// Core `protocolBinding` values: "JSONRPC", "GRPC", "HTTP+JSON"; the field is an
/// open string so extensions can declare their own bindings.
public struct A2AAgentInterface: Sendable, Equatable {
    public var url: String
    public var protocolBinding: String
    /// Opaque routing identifier for multi-tenant endpoints; when set, clients MUST
    /// echo it in the `tenant` field of every request to this interface.
    public var tenant: String?
    /// A2A protocol version exposed here, e.g. "1.0".
    public var protocolVersion: String

    public init(
        url: String, protocolBinding: String, tenant: String? = nil,
        protocolVersion: String
    ) {
        self.url = url
        self.protocolBinding = protocolBinding
        self.tenant = tenant
        self.protocolVersion = protocolVersion
    }

    public static let jsonRPCBinding = "JSONRPC"
    public static let gRPCBinding = "GRPC"
    public static let httpJSONBinding = "HTTP+JSON"
}

extension A2AAgentInterface: Codable {
    private enum CodingKeys: String, CodingKey {
        case url, protocolBinding, tenant, protocolVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        protocolBinding =
            try container.decodeIfPresent(String.self, forKey: .protocolBinding) ?? ""
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant)
        protocolVersion =
            try container.decodeIfPresent(String.self, forKey: .protocolVersion) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(url, forKey: .url)
        try container.encodeIfNotEmpty(protocolBinding, forKey: .protocolBinding)
        try container.encodeIfPresent(tenant, forKey: .tenant)
        try container.encodeIfNotEmpty(protocolVersion, forKey: .protocolVersion)
    }
}

/// The service provider of an agent (`AgentProvider`).
public struct A2AAgentProvider: Codable, Sendable, Equatable {
    public var url: String
    public var organization: String

    public init(url: String, organization: String) {
        self.url = url
        self.organization = organization
    }
}

/// A protocol extension the agent supports (`AgentExtension`).
public struct A2AAgentExtension: Sendable, Equatable {
    public var uri: String
    public var description: String
    /// When true, clients must understand and comply with the extension.
    public var required: Bool
    public var params: A2AJSONValue?

    public init(
        uri: String, description: String = "", required: Bool = false,
        params: A2AJSONValue? = nil
    ) {
        self.uri = uri
        self.description = description
        self.required = required
        self.params = params
    }
}

extension A2AAgentExtension: Codable {
    private enum CodingKeys: String, CodingKey { case uri, description, required, params }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decodeIfPresent(String.self, forKey: .uri) ?? ""
        description =
            try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        params = try container.decodeIfPresent(A2AJSONValue.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(uri, forKey: .uri)
        try container.encodeIfNotEmpty(description, forKey: .description)
        if required { try container.encode(true, forKey: .required) }
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// Optional capability flags (`AgentCapabilities`).
public struct A2AAgentCapabilities: Sendable, Equatable {
    public var streaming: Bool?
    public var pushNotifications: Bool?
    public var extensions: [A2AAgentExtension]
    public var extendedAgentCard: Bool?

    public init(
        streaming: Bool? = nil, pushNotifications: Bool? = nil,
        extensions: [A2AAgentExtension] = [], extendedAgentCard: Bool? = nil
    ) {
        self.streaming = streaming
        self.pushNotifications = pushNotifications
        self.extensions = extensions
        self.extendedAgentCard = extendedAgentCard
    }
}

extension A2AAgentCapabilities: Codable {
    private enum CodingKeys: String, CodingKey {
        case streaming, pushNotifications, extensions, extendedAgentCard
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming)
        pushNotifications =
            try container.decodeIfPresent(Bool.self, forKey: .pushNotifications)
        extensions =
            try container.decodeIfPresent([A2AAgentExtension].self, forKey: .extensions)
            ?? []
        extendedAgentCard =
            try container.decodeIfPresent(Bool.self, forKey: .extendedAgentCard)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(streaming, forKey: .streaming)
        try container.encodeIfPresent(pushNotifications, forKey: .pushNotifications)
        try container.encodeIfNotEmpty(extensions, forKey: .extensions)
        try container.encodeIfPresent(extendedAgentCard, forKey: .extendedAgentCard)
    }
}

/// A distinct capability the agent can perform (`AgentSkill`).
public struct A2AAgentSkill: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var tags: [String]
    public var examples: [String]
    public var inputModes: [String]
    public var outputModes: [String]
    public var securityRequirements: [A2ASecurityRequirement]

    public init(
        id: String, name: String, description: String = "", tags: [String] = [],
        examples: [String] = [], inputModes: [String] = [], outputModes: [String] = [],
        securityRequirements: [A2ASecurityRequirement] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.tags = tags
        self.examples = examples
        self.inputModes = inputModes
        self.outputModes = outputModes
        self.securityRequirements = securityRequirements
    }
}

extension A2AAgentSkill: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, description, tags, examples, inputModes, outputModes
        case securityRequirements
        // The doc examples use OpenAPI-style "security" alongside the proto's
        // security_requirements; accept both on decode (see A2ASecurityRequirement).
        case security
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description =
            try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        examples = try container.decodeIfPresent([String].self, forKey: .examples) ?? []
        inputModes =
            try container.decodeIfPresent([String].self, forKey: .inputModes) ?? []
        outputModes =
            try container.decodeIfPresent([String].self, forKey: .outputModes) ?? []
        securityRequirements =
            try container.decodeIfPresent(
                [A2ASecurityRequirement].self, forKey: .securityRequirements)
            ?? container.decodeIfPresent(
                [A2ASecurityRequirement].self, forKey: .security)
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(id, forKey: .id)
        try container.encodeIfNotEmpty(name, forKey: .name)
        try container.encodeIfNotEmpty(description, forKey: .description)
        try container.encodeIfNotEmpty(tags, forKey: .tags)
        try container.encodeIfNotEmpty(examples, forKey: .examples)
        try container.encodeIfNotEmpty(inputModes, forKey: .inputModes)
        try container.encodeIfNotEmpty(outputModes, forKey: .outputModes)
        try container.encodeIfNotEmpty(securityRequirements, forKey: .security)
    }
}

/// An RFC 7515 JWS signature over the card (`AgentCardSignature`). This SDK parses
/// and preserves signatures; verification is behind a seam in A2AClient (not yet
/// implemented — see DEVIATIONS).
public struct A2AAgentCardSignature: Sendable, Equatable {
    /// Base64url-encoded protected JWS header.
    public var protected: String
    /// Base64url-encoded signature.
    public var signature: String
    /// Unprotected JWS header values.
    public var header: A2AJSONValue?

    public init(protected: String, signature: String, header: A2AJSONValue? = nil) {
        self.protected = protected
        self.signature = signature
        self.header = header
    }
}

extension A2AAgentCardSignature: Codable {
    private enum CodingKeys: String, CodingKey { case protected, signature, header }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protected = try container.decodeIfPresent(String.self, forKey: .protected) ?? ""
        signature = try container.decodeIfPresent(String.self, forKey: .signature) ?? ""
        header = try container.decodeIfPresent(A2AJSONValue.self, forKey: .header)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(protected, forKey: .protected)
        try container.encodeIfNotEmpty(signature, forKey: .signature)
        try container.encodeIfPresent(header, forKey: .header)
    }
}

/// The agent's self-describing manifest (`AgentCard`).
public struct A2AAgentCard: Sendable, Equatable {
    public var name: String
    public var description: String
    /// Ordered; the first entry is preferred.
    public var supportedInterfaces: [A2AAgentInterface]
    public var provider: A2AAgentProvider?
    public var version: String
    public var documentationUrl: String?
    public var capabilities: A2AAgentCapabilities
    public var securitySchemes: [String: A2ASecurityScheme]
    public var securityRequirements: [A2ASecurityRequirement]
    public var defaultInputModes: [String]
    public var defaultOutputModes: [String]
    public var skills: [A2AAgentSkill]
    public var signatures: [A2AAgentCardSignature]
    public var iconUrl: String?

    public init(
        name: String, description: String, supportedInterfaces: [A2AAgentInterface],
        provider: A2AAgentProvider? = nil, version: String,
        documentationUrl: String? = nil, capabilities: A2AAgentCapabilities,
        securitySchemes: [String: A2ASecurityScheme] = [:],
        securityRequirements: [A2ASecurityRequirement] = [],
        defaultInputModes: [String] = [], defaultOutputModes: [String] = [],
        skills: [A2AAgentSkill] = [], signatures: [A2AAgentCardSignature] = [],
        iconUrl: String? = nil
    ) {
        self.name = name
        self.description = description
        self.supportedInterfaces = supportedInterfaces
        self.provider = provider
        self.version = version
        self.documentationUrl = documentationUrl
        self.capabilities = capabilities
        self.securitySchemes = securitySchemes
        self.securityRequirements = securityRequirements
        self.defaultInputModes = defaultInputModes
        self.defaultOutputModes = defaultOutputModes
        self.skills = skills
        self.signatures = signatures
        self.iconUrl = iconUrl
    }

    /// The first interface with the given binding, honoring card order.
    public func preferredInterface(binding: String) -> A2AAgentInterface? {
        supportedInterfaces.first { $0.protocolBinding == binding }
    }

    /// The well-known discovery path for HTTP-served cards.
    public static let wellKnownPath = "/.well-known/agent-card.json"
}

extension A2AAgentCard: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, description, supportedInterfaces, provider, version
        case documentationUrl, capabilities, securitySchemes
        case securityRequirements, security
        case defaultInputModes, defaultOutputModes, skills, signatures, iconUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description =
            try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        supportedInterfaces =
            try container.decodeIfPresent(
                [A2AAgentInterface].self, forKey: .supportedInterfaces) ?? []
        provider = try container.decodeIfPresent(A2AAgentProvider.self, forKey: .provider)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        documentationUrl =
            try container.decodeIfPresent(String.self, forKey: .documentationUrl)
        capabilities =
            try container.decodeIfPresent(A2AAgentCapabilities.self, forKey: .capabilities)
            ?? A2AAgentCapabilities()
        securitySchemes =
            try container.decodeIfPresent(
                [String: A2ASecurityScheme].self, forKey: .securitySchemes) ?? [:]
        securityRequirements =
            try container.decodeIfPresent(
                [A2ASecurityRequirement].self, forKey: .securityRequirements)
            ?? container.decodeIfPresent(
                [A2ASecurityRequirement].self, forKey: .security)
            ?? []
        defaultInputModes =
            try container.decodeIfPresent([String].self, forKey: .defaultInputModes) ?? []
        defaultOutputModes =
            try container.decodeIfPresent([String].self, forKey: .defaultOutputModes)
            ?? []
        skills = try container.decodeIfPresent([A2AAgentSkill].self, forKey: .skills) ?? []
        signatures =
            try container.decodeIfPresent(
                [A2AAgentCardSignature].self, forKey: .signatures) ?? []
        iconUrl = try container.decodeIfPresent(String.self, forKey: .iconUrl)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(name, forKey: .name)
        try container.encodeIfNotEmpty(description, forKey: .description)
        try container.encodeIfNotEmpty(supportedInterfaces, forKey: .supportedInterfaces)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfNotEmpty(version, forKey: .version)
        try container.encodeIfPresent(documentationUrl, forKey: .documentationUrl)
        if capabilities != A2AAgentCapabilities() {
            try container.encode(capabilities, forKey: .capabilities)
        }
        try container.encodeIfNotEmpty(securitySchemes, forKey: .securitySchemes)
        // Encoded under the documented "security" key, OpenAPI-style (see
        // A2ASecurityRequirement's wire note).
        try container.encodeIfNotEmpty(securityRequirements, forKey: .security)
        try container.encodeIfNotEmpty(defaultInputModes, forKey: .defaultInputModes)
        try container.encodeIfNotEmpty(defaultOutputModes, forKey: .defaultOutputModes)
        try container.encodeIfNotEmpty(skills, forKey: .skills)
        try container.encodeIfNotEmpty(signatures, forKey: .signatures)
        try container.encodeIfPresent(iconUrl, forKey: .iconUrl)
    }
}
