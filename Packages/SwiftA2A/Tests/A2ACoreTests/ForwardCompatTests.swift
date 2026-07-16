import Foundation
import Testing

@testable import A2ACore

// Forward-compatibility proofs: unknown JSON fields, enum values, and oneof arms are
// ignored-or-preserved, never fatal (the same rule PQRC applies per SPEC §12).

@Suite struct ForwardCompatTests {
    @Test func unknownFieldsAreIgnoredOnEveryCoreType() throws {
        // Inject unknown sibling keys into minimal valid JSON for each type.
        let cases: [(String, (Data) throws -> Void)] = [
            (
                #"{"id":"t1","status":{"state":"TASK_STATE_WORKING"},"futureField":123}"#,
                { _ = try A2AWireCodec.decode(A2ATask.self, from: $0) }
            ),
            (
                #"{"role":"ROLE_USER","parts":[{"text":"hi"}],"newThing":{"a":1}}"#,
                { _ = try A2AWireCodec.decode(A2AMessage.self, from: $0) }
            ),
            (
                #"{"artifactId":"a1","parts":[{"text":"x"}],"shiny":[1,2]}"#,
                { _ = try A2AWireCodec.decode(A2AArtifact.self, from: $0) }
            ),
            (
                #"{"text":"hi","annotations":["future"]}"#,
                { _ = try A2AWireCodec.decode(A2APart.self, from: $0) }
            ),
            (
                #"{"name":"n","description":"d","version":"1","capabilities":{},"quantum":true}"#,
                { _ = try A2AWireCodec.decode(A2AAgentCard.self, from: $0) }
            ),
            (
                #"{"state":"TASK_STATE_WORKING","confidence":0.9}"#,
                { _ = try A2AWireCodec.decode(A2ATaskStatus.self, from: $0) }
            ),
        ]
        for (json, decode) in cases {
            try decode(Data(json.utf8))
        }
    }

    @Test func unknownTaskStateIsPreservedNotFatal() throws {
        let status = try A2AWireCodec.decode(
            A2ATaskStatus.self, from: #"{"state":"TASK_STATE_PONDERING"}"#)
        #expect(status.state == .unknown("TASK_STATE_PONDERING"))
        #expect(!status.state.isTerminal)
        let reencoded = try A2AWireCodec.encodeString(status)
        #expect(reencoded.contains("TASK_STATE_PONDERING"))
    }

    @Test func unknownRoleIsPreservedNotFatal() throws {
        let message = try A2AWireCodec.decode(
            A2AMessage.self, from: #"{"role":"ROLE_OVERSEER","parts":[{"text":"x"}]}"#)
        #expect(message.role == .unknown("ROLE_OVERSEER"))
    }

    @Test func unknownSecuritySchemeKindIsPreserved() throws {
        let json = #"{"webauthnSecurityScheme":{"rpId":"example.com"}}"#
        let scheme = try A2AWireCodec.decode(A2ASecurityScheme.self, from: json)
        guard case .unknown(let members) = scheme else {
            Issue.record("expected .unknown, got \(scheme)")
            return
        }
        #expect(members["webauthnSecurityScheme"] != nil)
        // Round-trips without loss.
        let tree = try A2AWireCodec.decode(
            A2AJSONValue.self, from: try A2AWireCodec.encode(scheme))
        #expect(tree == (try A2AWireCodec.decode(A2AJSONValue.self, from: json)))
    }

    @Test func unknownStreamResponseArmIsFatalButTyped() throws {
        // A genuinely unknown oneof arm cannot be dispatched; it must surface as a
        // DecodingError (typed), never a crash.
        #expect(throws: DecodingError.self) {
            _ = try A2AWireCodec.decode(
                A2AStreamResponse.self, from: #"{"telemetryUpdate":{"x":1}}"#)
        }
    }

    @Test func securityRequirementDecodesBothWireShapes() throws {
        // Documented OpenAPI shape.
        let openAPI = try A2AWireCodec.decode(
            A2ASecurityRequirement.self, from: #"{"google":["openid","email"]}"#)
        #expect(openAPI.schemes["google"] == ["openid", "email"])
        // Strict proto3-JSON shape.
        let proto = try A2AWireCodec.decode(
            A2ASecurityRequirement.self,
            from: #"{"schemes":{"google":{"list":["openid","email"]}}}"#)
        #expect(proto.schemes == openAPI.schemes)
    }
}

@Suite struct PartOneOfTests {
    @Test func zeroContentArmsIsATypedError() throws {
        #expect(throws: DecodingError.self) {
            _ = try A2AWireCodec.decode(A2APart.self, from: #"{"filename":"x.txt"}"#)
        }
    }

    @Test func multipleContentArmsIsATypedError() throws {
        #expect(throws: DecodingError.self) {
            _ = try A2AWireCodec.decode(
                A2APart.self, from: #"{"text":"hi","url":"https://example.com"}"#)
        }
    }

    @Test func rawPartKeepsWireBase64EvenWhenInvalid() throws {
        // The spec's own example uses truncated base64 ("iVBORw0KGgo..."); a relay
        // must round-trip it byte-for-byte rather than failing.
        let part = try A2AWireCodec.decode(
            A2APart.self, from: #"{"raw":"iVBORw0KGgo...","mediaType":"image/png"}"#)
        guard case .raw(let base64) = part.content else {
            Issue.record("expected .raw")
            return
        }
        #expect(base64 == "iVBORw0KGgo...")
        #expect(part.rawData == nil)  // invalid base64 → no bytes, no crash
    }

    @Test func dataPartAcceptsAnyJSONValue() throws {
        let objectPart = try A2AWireCodec.decode(
            A2APart.self, from: #"{"data":{"lat":37.4,"lng":-122.1}}"#)
        #expect(objectPart.content == .data(["lat": 37.4, "lng": -122.1]))
        let scalarPart = try A2AWireCodec.decode(A2APart.self, from: #"{"data":42}"#)
        #expect(scalarPart.content == .data(.int(42)))
    }
}

@Suite struct TaskStateTests {
    @Test func terminalAndInterruptedClassification() {
        let terminal: [A2ATaskState] = [.completed, .failed, .canceled, .rejected]
        let interrupted: [A2ATaskState] = [.inputRequired, .authRequired]
        let active: [A2ATaskState] = [.unspecified, .submitted, .working]
        for state in terminal {
            #expect(state.isTerminal && !state.isInterrupted)
        }
        for state in interrupted {
            #expect(!state.isTerminal && state.isInterrupted)
        }
        for state in active {
            #expect(!state.isTerminal && !state.isInterrupted)
        }
    }

    @Test func allWireNamesRoundTrip() {
        let states: [A2ATaskState] = [
            .unspecified, .submitted, .working, .completed, .failed, .canceled,
            .inputRequired, .rejected, .authRequired,
        ]
        for state in states {
            #expect(A2ATaskState(wireName: state.wireName) == state)
        }
    }

    @Test func statusTimestampParses() {
        let millis = A2ATaskStatus(
            state: .working, timestamp: "2025-10-28T10:30:00.000Z")
        #expect(millis.date != nil)
        let seconds = A2ATaskStatus(state: .working, timestamp: "2024-03-15T11:00:00Z")
        #expect(seconds.date != nil)
    }
}

@Suite struct JSONRPCEnvelopeTests {
    @Test func responseMustCarryExactlyOneOfResultError() throws {
        #expect(throws: DecodingError.self) {
            _ = try A2AWireCodec.decode(
                JSONRPCResponse.self, from: #"{"jsonrpc":"2.0","id":1}"#)
        }
        #expect(throws: DecodingError.self) {
            _ = try A2AWireCodec.decode(
                JSONRPCResponse.self,
                from:
                    #"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-32603,"message":"x"}}"#
            )
        }
    }

    @Test func wrongJSONRPCVersionRejected() throws {
        #expect(throws: DecodingError.self) {
            _ = try A2AWireCodec.decode(
                JSONRPCRequest.self, from: #"{"jsonrpc":"1.0","id":1,"method":"GetTask"}"#)
        }
    }

    @Test func stringAndIntIDsBothWork() throws {
        let intID = try A2AWireCodec.decode(
            JSONRPCRequest.self, from: #"{"jsonrpc":"2.0","id":7,"method":"GetTask"}"#)
        #expect(intID.id == .int(7))
        let stringID = try A2AWireCodec.decode(
            JSONRPCRequest.self,
            from: #"{"jsonrpc":"2.0","id":"req-1","method":"GetTask"}"#)
        #expect(stringID.id == .string("req-1"))
    }

    @Test func endpointErrorSurfacesAsTypedThrow() throws {
        let response = JSONRPCResponse(
            id: .int(1), error: A2AErrorObject(code: .taskNotFound))
        #expect(throws: A2AClientError.endpoint(A2AErrorObject(code: .taskNotFound))) {
            _ = try response.decodeResult(A2ATask.self)
        }
    }

    @Test func versionNegotiation() {
        #expect(A2AVersion.isSupported("1.0"))
        #expect(!A2AVersion.isSupported("0.3"))
        #expect(!A2AVersion.isSupported(""))  // empty = 0.3 per spec → unsupported
        #expect(!A2AVersion.isSupported(nil))
        #expect(!A2AVersion.isSupported("2.0"))
    }
}
