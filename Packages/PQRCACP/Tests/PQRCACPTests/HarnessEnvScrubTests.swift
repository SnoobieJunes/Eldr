import Testing

@testable import PQRCACP

/// Env-hygiene for spawned children (Workstream 3a): the shared secret-scrub that both
/// `shellEnvironment` (run_shell / open_terminal) and `StdioHarnessTransport` (external cloud
/// CLI) use. The agent's OWN secrets must never reach a child; a user's vendor key must.
@Suite("Harness env hygiene")
struct HarnessEnvScrubTests {
    @Test func agentSecretsStrippedButVendorKeyAndBuildVarsSurvive() {
        let env = [
            // Agent's own long-term secrets — MUST be stripped.
            "ELDR_LLM_TOKEN": "s1",
            "ELDR_ACP_METADATA_KEY": "s2",
            "SYBILCLAW_GATEWAY_TOKEN": "s3",
            "PQRC_SIGNING_KEY": "s4",  // secret-shaped, in our namespace
            // A user's OWN vendor key + a normal build var — MUST survive (the cloud CLI
            // needs its key; scrub is scoped to our namespaces only).
            "ANTHROPIC_API_KEY": "vendor-key",
            "PATH": "/usr/bin:/bin",
        ]
        let scrubbed = ToolEnvironment.scrubbingAgentSecrets(env)

        #expect(scrubbed["ELDR_LLM_TOKEN"] == nil)
        #expect(scrubbed["ELDR_ACP_METADATA_KEY"] == nil)
        #expect(scrubbed["SYBILCLAW_GATEWAY_TOKEN"] == nil)
        #expect(scrubbed["PQRC_SIGNING_KEY"] == nil)
        #expect(scrubbed["ANTHROPIC_API_KEY"] == "vendor-key")
        #expect(scrubbed["PATH"] == "/usr/bin:/bin")
    }
}
