// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

struct AgentDerivationVector: Codable {
    let identitySeed: String
    let identityPub: String
    let agentPub: String
    let agentSignatureOverCanary: String
}

@Suite("Agent key derivation (SPEC §3.2)", .tags(.crypto))
struct AgentDerivationTests {
    static let canary = Data("pqrc-agent-canary".utf8)

    @Test func agentKey_derivesPerSpec_andIsOneWay() throws {
        let vector: AgentDerivationVector = try Vectors.loadOrGenerate("agent_derivation.json") {
            let identity = try PQRCIdentity(seed: hexData(String(repeating: "a1", count: 32)))
            let agent = try AgentKeyDeriver.deriveAgentKey(from: identity)
            return AgentDerivationVector(
                identitySeed: identity.privateKey.rawRepresentation.hex,
                identityPub: identity.publicKeyData.hex,
                agentPub: agent.publicKey.rawRepresentation.hex,
                agentSignatureOverCanary: try agent.signature(for: Self.canary).hex
            )
        }
        let identity = try PQRCIdentity(seed: hexData(vector.identitySeed))
        #expect(identity.publicKeyData.hex == vector.identityPub)

        let agent = try AgentKeyDeriver.deriveAgentKey(from: identity)
        // Matches the frozen vector: HKDF salt "pqrc-v1", info "pqrc-agent-v1"||identity_pub.
        #expect(agent.publicKey.rawRepresentation.hex == vector.agentPub)

        // Agent pub != identity pub (different key, different declared role).
        #expect(agent.publicKey.rawRepresentation != identity.publicKeyData)

        // One-way: an agent signature never verifies under the identity key.
        let signature = try agent.signature(for: Self.canary)
        #expect(
            !PQRCIdentity.verify(
                signature: signature, message: Self.canary, publicKey: identity.publicKeyData
            ))
        // And the frozen agent signature still verifies under the derived agent key.
        #expect(
            PQRCIdentity.verify(
                signature: hexData(vector.agentSignatureOverCanary),
                message: Self.canary,
                publicKey: hexData(vector.agentPub)
            ))
    }

    @Test func agentDerivation_isDeterministic_andIdentityDependent() throws {
        let identityA = try PQRCIdentity(seed: hexData(String(repeating: "b2", count: 32)))
        let identityB = try PQRCIdentity(seed: hexData(String(repeating: "c3", count: 32)))
        let agentA1 = try AgentKeyDeriver.deriveAgentKey(from: identityA)
        let agentA2 = try AgentKeyDeriver.deriveAgentKey(from: identityA)
        let agentB = try AgentKeyDeriver.deriveAgentKey(from: identityB)
        #expect(agentA1.publicKey.rawRepresentation == agentA2.publicKey.rawRepresentation)
        #expect(agentA1.publicKey.rawRepresentation != agentB.publicKey.rawRepresentation)
    }
}

extension Tag {
    @Tag static var crypto: Tag
    @Tag static var envelope: Tag
    @Tag static var transport: Tag
    @Tag static var agent: Tag
    @Tag static var group: Tag
    @Tag static var security: Tag
    @Tag static var perf: Tag
}
