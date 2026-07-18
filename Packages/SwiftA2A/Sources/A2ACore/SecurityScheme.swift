import Foundation

// Security scheme types from lf.a2a.v1 (a2a.proto), mirroring the OpenAPI 3.2
// Security Scheme Object. `SecurityScheme` and `OAuthFlows` are proto `oneof`s;
// unknown scheme kinds are preserved as `.unknown` (forward compatibility).

public struct A2AAPIKeySecurityScheme: Codable, Sendable, Equatable {
    public var description: String?
    /// "query", "header", or "cookie".
    public var location: String
    public var name: String

    public init(description: String? = nil, location: String, name: String) {
        self.description = description
        self.location = location
        self.name = name
    }
}

public struct A2AHTTPAuthSecurityScheme: Codable, Sendable, Equatable {
    public var description: String?
    /// IANA HTTP auth scheme, e.g. "Bearer".
    public var scheme: String
    public var bearerFormat: String?

    public init(description: String? = nil, scheme: String, bearerFormat: String? = nil) {
        self.description = description
        self.scheme = scheme
        self.bearerFormat = bearerFormat
    }
}

public struct A2AOAuth2SecurityScheme: Codable, Sendable, Equatable {
    public var description: String?
    public var flows: A2AOAuthFlows
    public var oauth2MetadataUrl: String?

    public init(
        description: String? = nil, flows: A2AOAuthFlows, oauth2MetadataUrl: String? = nil
    ) {
        self.description = description
        self.flows = flows
        self.oauth2MetadataUrl = oauth2MetadataUrl
    }
}

public struct A2AOpenIdConnectSecurityScheme: Codable, Sendable, Equatable {
    public var description: String?
    public var openIdConnectUrl: String

    public init(description: String? = nil, openIdConnectUrl: String) {
        self.description = description
        self.openIdConnectUrl = openIdConnectUrl
    }
}

public struct A2AMutualTlsSecurityScheme: Codable, Sendable, Equatable {
    public var description: String?

    public init(description: String? = nil) {
        self.description = description
    }
}

public struct A2AAuthorizationCodeOAuthFlow: Codable, Sendable, Equatable {
    public var authorizationUrl: String
    public var tokenUrl: String
    public var refreshUrl: String?
    public var scopes: [String: String]
    public var pkceRequired: Bool?

    public init(
        authorizationUrl: String, tokenUrl: String, refreshUrl: String? = nil,
        scopes: [String: String], pkceRequired: Bool? = nil
    ) {
        self.authorizationUrl = authorizationUrl
        self.tokenUrl = tokenUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
        self.pkceRequired = pkceRequired
    }
}

public struct A2AClientCredentialsOAuthFlow: Codable, Sendable, Equatable {
    public var tokenUrl: String
    public var refreshUrl: String?
    public var scopes: [String: String]

    public init(tokenUrl: String, refreshUrl: String? = nil, scopes: [String: String]) {
        self.tokenUrl = tokenUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
    }
}

public struct A2ADeviceCodeOAuthFlow: Codable, Sendable, Equatable {
    public var deviceAuthorizationUrl: String
    public var tokenUrl: String
    public var refreshUrl: String?
    public var scopes: [String: String]

    public init(
        deviceAuthorizationUrl: String, tokenUrl: String, refreshUrl: String? = nil,
        scopes: [String: String]
    ) {
        self.deviceAuthorizationUrl = deviceAuthorizationUrl
        self.tokenUrl = tokenUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
    }
}

/// OAuth 2.0 flow configuration (`OAuthFlows` oneof). The deprecated implicit and
/// password flows are intentionally not modeled; their wire keys decode to `.unknown`.
public enum A2AOAuthFlows: Sendable, Equatable {
    case authorizationCode(A2AAuthorizationCodeOAuthFlow)
    case clientCredentials(A2AClientCredentialsOAuthFlow)
    case deviceCode(A2ADeviceCodeOAuthFlow)
    /// A flow this SDK does not model (including the spec-deprecated implicit and
    /// password flows). The raw JSON is preserved for round-tripping.
    case unknown([String: A2AJSONValue])
}

extension A2AOAuthFlows: Codable {
    private enum CodingKeys: String, CodingKey {
        case authorizationCode, clientCredentials, deviceCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let flow = try container.decodeIfPresent(
            A2AAuthorizationCodeOAuthFlow.self, forKey: .authorizationCode)
        {
            self = .authorizationCode(flow)
        } else if let flow = try container.decodeIfPresent(
            A2AClientCredentialsOAuthFlow.self, forKey: .clientCredentials)
        {
            self = .clientCredentials(flow)
        } else if let flow = try container.decodeIfPresent(
            A2ADeviceCodeOAuthFlow.self, forKey: .deviceCode)
        {
            self = .deviceCode(flow)
        } else {
            let raw = try decoder.singleValueContainer().decode(A2AJSONValue.self)
            self = .unknown(raw.objectValue ?? [:])
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .authorizationCode(let flow):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(flow, forKey: .authorizationCode)
        case .clientCredentials(let flow):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(flow, forKey: .clientCredentials)
        case .deviceCode(let flow):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(flow, forKey: .deviceCode)
        case .unknown(let members):
            var container = encoder.singleValueContainer()
            try container.encode(A2AJSONValue.object(members))
        }
    }
}

/// A security scheme securing an agent's endpoints (`SecurityScheme` oneof).
public enum A2ASecurityScheme: Sendable, Equatable {
    case apiKey(A2AAPIKeySecurityScheme)
    case httpAuth(A2AHTTPAuthSecurityScheme)
    case oauth2(A2AOAuth2SecurityScheme)
    case openIdConnect(A2AOpenIdConnectSecurityScheme)
    case mtls(A2AMutualTlsSecurityScheme)
    /// A scheme kind this SDK does not know; raw JSON preserved.
    case unknown([String: A2AJSONValue])
}

extension A2ASecurityScheme: Codable {
    private enum CodingKeys: String, CodingKey {
        case apiKeySecurityScheme
        case httpAuthSecurityScheme
        case oauth2SecurityScheme
        case openIdConnectSecurityScheme
        case mtlsSecurityScheme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let scheme = try container.decodeIfPresent(
            A2AAPIKeySecurityScheme.self, forKey: .apiKeySecurityScheme)
        {
            self = .apiKey(scheme)
        } else if let scheme = try container.decodeIfPresent(
            A2AHTTPAuthSecurityScheme.self, forKey: .httpAuthSecurityScheme)
        {
            self = .httpAuth(scheme)
        } else if let scheme = try container.decodeIfPresent(
            A2AOAuth2SecurityScheme.self, forKey: .oauth2SecurityScheme)
        {
            self = .oauth2(scheme)
        } else if let scheme = try container.decodeIfPresent(
            A2AOpenIdConnectSecurityScheme.self, forKey: .openIdConnectSecurityScheme)
        {
            self = .openIdConnect(scheme)
        } else if let scheme = try container.decodeIfPresent(
            A2AMutualTlsSecurityScheme.self, forKey: .mtlsSecurityScheme)
        {
            self = .mtls(scheme)
        } else {
            let raw = try decoder.singleValueContainer().decode(A2AJSONValue.self)
            self = .unknown(raw.objectValue ?? [:])
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .apiKey(let scheme):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scheme, forKey: .apiKeySecurityScheme)
        case .httpAuth(let scheme):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scheme, forKey: .httpAuthSecurityScheme)
        case .oauth2(let scheme):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scheme, forKey: .oauth2SecurityScheme)
        case .openIdConnect(let scheme):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scheme, forKey: .openIdConnectSecurityScheme)
        case .mtls(let scheme):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scheme, forKey: .mtlsSecurityScheme)
        case .unknown(let members):
            var container = encoder.singleValueContainer()
            try container.encode(A2AJSONValue.object(members))
        }
    }
}

/// A security requirement: scheme name → required scopes.
///
/// Wire note: the canonical AgentCard example serializes this OpenAPI-style
/// (`{"google": ["openid", "profile"]}`) under the key `security`, while a strict
/// proto3-JSON rendering of `SecurityRequirement` would be
/// `{"schemes": {"google": {"list": [...]}}}`. This SDK decodes both shapes and
/// encodes the documented OpenAPI style, which is what deployed agents publish.
public struct A2ASecurityRequirement: Sendable, Equatable {
    public var schemes: [String: [String]]

    public init(schemes: [String: [String]]) {
        self.schemes = schemes
    }
}

extension A2ASecurityRequirement: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: A2AJSONValue].self)
        // Proto3-JSON shape: {"schemes": {name: {"list": [...]}}}
        if raw.count == 1, let inner = raw["schemes"]?.objectValue {
            var decoded: [String: [String]] = [:]
            var protoShaped = true
            for (name, value) in inner {
                if let list = value["list"], case .array(let items) = list {
                    decoded[name] = items.compactMap(\.stringValue)
                } else {
                    protoShaped = false
                    break
                }
            }
            if protoShaped {
                schemes = decoded
                return
            }
        }
        // OpenAPI shape (the documented canonical form): {name: [scope, ...]}
        var decoded: [String: [String]] = [:]
        for (name, value) in raw {
            guard case .array(let items) = value else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "SecurityRequirement scopes must be a string array")
            }
            decoded[name] = items.compactMap(\.stringValue)
        }
        schemes = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(schemes)
    }
}
