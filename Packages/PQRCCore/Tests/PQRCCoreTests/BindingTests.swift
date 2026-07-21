// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

struct BindingVector: Codable {
    struct Case: Codable {
        let name: String
        let nostrPubkey: String
        let identityPubkey: String
        let agentPubkey: String
        let version: String
        let crossSignature: String
        let outerSignatureValid: Bool
        let expectValid: Bool
    }
    let identitySeed: String
    let cases: [Case]
}

@Suite("Identity binding 10420 (SPEC §3.3)", .tags(.crypto))
struct BindingTests {
    static func makeVector() throws -> BindingVector {
        let identity = try PQRCIdentity(seed: hexData(String(repeating: "d4", count: 32)))
        let otherIdentity = try PQRCIdentity(seed: hexData(String(repeating: "e5", count: 32)))
        let nostrPub = hexData(String(repeating: "0f", count: 32))
        let valid = try IdentityBinding.make(identity: identity, nostrPubkey: nostrPub)
        let otherAgent = try AgentKeyDeriver.deriveAgentKey(from: otherIdentity)

        func caseFrom(
            _ name: String, _ binding: IdentityBinding, outerValid: Bool = true, expectValid: Bool
        ) -> BindingVector.Case {
            BindingVector.Case(
                name: name,
                nostrPubkey: binding.nostrPubkey.hex,
                identityPubkey: binding.identityPubkey.hex,
                agentPubkey: binding.agentPubkey.hex,
                version: binding.version,
                crossSignature: binding.crossSignature.hex,
                outerSignatureValid: outerValid,
                expectValid: expectValid
            )
        }

        var cases: [BindingVector.Case] = [caseFrom("valid", valid, expectValid: true)]
        // The six invalid mutations (TEST-PLAN §2).
        var tamperedSig = valid.crossSignature
        tamperedSig[tamperedSig.startIndex] ^= 0xFF
        cases.append(
            caseFrom(
                "bad_cross_sig",
                IdentityBinding(
                    nostrPubkey: valid.nostrPubkey, identityPubkey: valid.identityPubkey,
                    agentPubkey: valid.agentPubkey, crossSignature: tamperedSig
                ), expectValid: false))
        cases.append(caseFrom("bad_outer_sig", valid, outerValid: false, expectValid: false))
        cases.append(
            caseFrom(
                "swapped_keys",
                IdentityBinding(
                    nostrPubkey: valid.nostrPubkey, identityPubkey: valid.agentPubkey,
                    agentPubkey: valid.identityPubkey, crossSignature: valid.crossSignature
                ), expectValid: false))
        cases.append(
            caseFrom(
                "wrong_version",
                IdentityBinding(
                    nostrPubkey: valid.nostrPubkey, identityPubkey: valid.identityPubkey,
                    agentPubkey: valid.agentPubkey, version: "0", crossSignature: valid.crossSignature
                ), expectValid: false))
        cases.append(
            caseFrom(
                "missing_tag",
                IdentityBinding(
                    nostrPubkey: valid.nostrPubkey, identityPubkey: valid.identityPubkey,
                    agentPubkey: Data(), crossSignature: valid.crossSignature
                ), expectValid: false))
        cases.append(
            caseFrom(
                "agent_key_mismatch",
                IdentityBinding(
                    nostrPubkey: valid.nostrPubkey, identityPubkey: valid.identityPubkey,
                    agentPubkey: otherAgent.publicKey.rawRepresentation,
                    crossSignature: valid.crossSignature
                ), expectValid: false))
        return BindingVector(
            identitySeed: identity.privateKey.rawRepresentation.hex, cases: cases
        )
    }

    @Test func binding_verifiesBothDirections() throws {
        let vector: BindingVector = try Vectors.loadOrGenerate(
            "binding_10420.json", generate: Self.makeVector)
        let valid = try #require(vector.cases.first { $0.name == "valid" })
        let binding = IdentityBinding(
            nostrPubkey: hexData(valid.nostrPubkey),
            identityPubkey: hexData(valid.identityPubkey),
            agentPubkey: hexData(valid.agentPubkey),
            version: valid.version,
            crossSignature: hexData(valid.crossSignature)
        )
        let verified = try BindingVerifier.verify(binding, outerSignatureValid: true)
        #expect(verified.agentPubkey == hexData(valid.agentPubkey))
        #expect(verified.identityPubkey == hexData(valid.identityPubkey))

        // The binding really is bidirectional: outer-only is insufficient.
        #expect(throws: PQRCError.self) {
            _ = try BindingVerifier.verify(binding, outerSignatureValid: false)
        }
    }

    @Test func binding_rejectsEachMutation() throws {
        let vector: BindingVector = try Vectors.loadOrGenerate(
            "binding_10420.json", generate: Self.makeVector)
        for testCase in vector.cases where !testCase.expectValid {
            let binding = IdentityBinding(
                nostrPubkey: hexData(testCase.nostrPubkey),
                identityPubkey: hexData(testCase.identityPubkey),
                agentPubkey: hexData(testCase.agentPubkey),
                version: testCase.version,
                crossSignature: hexData(testCase.crossSignature)
            )
            // No key from an unverified binding is ever returned.
            #expect(throws: PQRCError.self, "mutation \(testCase.name) must be rejected") {
                _ = try BindingVerifier.verify(
                    binding, outerSignatureValid: testCase.outerSignatureValid)
            }
        }
    }
}
