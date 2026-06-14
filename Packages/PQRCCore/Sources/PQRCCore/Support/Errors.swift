import Foundation

/// Typed errors for the PQRC core (CLAUDE.md conventions: no try!, no fatalError).
public enum PQRCError: Error, Equatable, Sendable {
    // Identity / binding
    case invalidKeyLength
    case bindingVerificationFailed(BindingFailure)
    case agentKeyMismatch

    // Prekeys / handshake
    case prekeyExhausted
    case oneTimePrekeyAlreadyConsumed
    case unknownPrekey
    case invalidPrekeySignature
    case handshakeSuiteUnsupported(String)
    case handshakeMalformed

    // Ratchet
    case messageKeyUnavailable
    case skippedTooFar(requested: Int, max: Int)
    case duplicateMessage(chain: Data, n: Int)
    case decryptionFailed
    case sessionNotEstablished

    // Padding / envelope
    case plaintextExceedsInlineLimit(size: Int)
    case malformedPadding
    case malformedRumor
    case protocolViolation(String)

    // Storage
    case storeUnavailable
    case recordNotFound
    case keyWrapFailure

    // Reachability (distinguished so the UI can be honest, not guess):
    // the relay couldn't be reached at all vs. the relay is fine but the peer
    // has not published their keys to it yet.
    case relayUnreachable
    case peerKeysNotPublished

    public enum BindingFailure: Equatable, Sendable {
        case badOuterSignature
        case badCrossSignature
        case wrongVersion
        case missingTag(String)
        case agentKeyMismatch
        case keysSwapped
    }
}
