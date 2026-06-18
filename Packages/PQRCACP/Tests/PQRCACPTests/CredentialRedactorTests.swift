import Foundation
import Testing

@testable import PQRCACP

// The security-critical seam of the PQRC watch-along bridge: secrets must never
// survive `scrub` into a non-owner's copy. These assert detection across the common
// shapes AND that the markers never echo the secret, plus that ordinary prose is left
// intact (conservative, but not destructive).
@Suite("CredentialRedactor")
struct CredentialRedactorTests {

    private func assertRedacted(_ secret: String, in text: String) {
        let scrubbed = CredentialRedactor.scrub(text)
        #expect(!scrubbed.contains(secret), "secret leaked: \(scrubbed)")
        #expect(scrubbed.contains("‹redacted:"))
    }

    @Test func redactsOpenAIStyleKey() {
        assertRedacted(
            "sk-abc123DEF456ghi789JKL012",
            in: "Your key is sk-abc123DEF456ghi789JKL012 — keep it secret.")
    }

    @Test func redactsAnthropicStyleKey() {
        let key = "sk-ant-api03-AbC123_dEf456-GhI789jkl012MNO"
        assertRedacted(key, in: "export ANTHROPIC_API_KEY=\(key)")
    }

    @Test func redactsAWSAccessKeyID() {
        assertRedacted("AKIAIOSFODNN7EXAMPLE", in: "aws id AKIAIOSFODNN7EXAMPLE here")
    }

    @Test func redactsBearerTokenButKeepsPrefix() {
        let scrubbed = CredentialRedactor.scrub("Authorization: Bearer abc123XYZ789tokenvalue")
        #expect(!scrubbed.contains("abc123XYZ789tokenvalue"))
        #expect(scrubbed.contains("Bearer ‹redacted:token›"))
    }

    @Test func redactsKeyValueAssignmentKeepingTheKeyName() {
        // The owner asked the agent to read config.env; the non-owner copy must keep
        // the variable NAME (so the conversation still makes sense) but hide the value.
        let scrubbed = CredentialRedactor.scrub("API_KEY=supersecretvalue123")
        #expect(!scrubbed.contains("supersecretvalue123"))
        #expect(scrubbed.contains("API_KEY="))
        #expect(scrubbed.contains("‹redacted:token›"))
    }

    @Test func redactsQuotedPasswordAssignment() {
        let scrubbed = CredentialRedactor.scrub(#"password: "hunter2hunter2""#)
        #expect(!scrubbed.contains("hunter2hunter2"))
        #expect(scrubbed.contains("password"))
        #expect(scrubbed.contains("‹redacted:token›"))
    }

    @Test func redactsLongHighEntropyRun() {
        // A 48-char base64-ish blob with letters AND digits → redacted.
        let blob = "Zm9vYmFy0123456789AbCdEfGhIjKlMnOpQrStUvWx9876"
        assertRedacted(blob, in: "token=\(blob)")
    }

    @Test func leavesOrdinaryProseAlone() {
        let prose = "I read the file and updated the function to return early on nil."
        #expect(CredentialRedactor.scrub(prose) == prose)
        #expect(!CredentialRedactor.containsSecret(prose))
    }

    @Test func leavesNormalPathsAndWordsAlone() {
        // Long all-letter path component (no digit) must NOT trip the entropy rule.
        let text = "See Sources/PQRCACP/CredentialRedactorImplementationDetails.swift"
        #expect(CredentialRedactor.scrub(text) == text)
    }

    @Test func scrubIsIdempotent() {
        let once = CredentialRedactor.scrub("key sk-abc123DEF456ghi789JKL012 done")
        #expect(CredentialRedactor.scrub(once) == once)
    }

    @Test func containsSecretFlagsDetection() {
        #expect(CredentialRedactor.containsSecret("AKIAIOSFODNN7EXAMPLE"))
        #expect(!CredentialRedactor.containsSecret("just a friendly message"))
    }
}
