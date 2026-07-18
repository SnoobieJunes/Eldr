import Foundation

// Phase 1 item 1 of docs/ACPRouterplan.md: "a transport-agnostic runACPAgent/runACPProxy
// driver." `runACPAgent` (ACPTransport.swift) drives the BUILT-IN agent. `runACPProxy` is its
// sibling for EXTERNAL harnesses: the node, having authenticated the phone and decrypted the
// stream, "pipes the verified, decrypted ACP stream both ways" between the phone transport
// and a locally-spawned harness transport (the plan's key design decision: "The node
// interprets little ACP itself — it pipes the verified, decrypted stream both ways").
//
// `runHarness` is the single seam the node calls to run ANY backend: it dispatches on the
// descriptor's `kind` — `.builtIn` → `runACPAgent` (unchanged), `.stdioSpawn`/`.a2aRemote` →
// build the harness's transport via an injected `HarnessTransportFactory` and `runACPProxy`
// between it and the phone. The factory is the seam that keeps `.a2aRemote` support (which
// needs `SwiftA2A`) out of this dependency-free target — see `HarnessTransportFactory.swift`.
//
// This file is transport-agnostic and largely iOS-available; only the non-`.builtIn` branch of
// `runHarness` (which builds a `HarnessTransportFactory`-produced transport, macOS-only by
// default) is macOS-gated.

/// The transport-agnostic ACP PROXY driver: forward every line from `client.inboundLines()`
/// → `harness.send`, and every line from `harness.inboundLines()` → `client.send`, until
/// EITHER side's inbound stream finishes — then close the OTHER side and return. Pure,
/// "dumb" bidirectional piping; it parses no ACP and makes no decisions.
///
/// TRUST BOUNDARY — the C-3 owner gate lives ABOVE this. The node only ever hands an
/// owner-VERIFIED client transport to this proxy (identical to how it hands one to
/// `runACPAgent` today): the phone's PQRC identity is authenticated and the transport
/// decrypted by the node host before this is called. The proxy itself does NO authn/authz and
/// MUST NOT be given an unverified transport — it forwards whatever it receives verbatim.
///
/// Structured concurrency: the two directions run as sibling tasks in one `TaskGroup`. The
/// FIRST direction to see its source stream finish (peer closed / EOF / child exit) wins;
/// `group.cancelAll()` then unblocks the other `for await`, and both transports are closed so
/// neither end is left half-open.
public func runACPProxy(client: any ACPTransport, harness: any ACPTransport) async {
    await withTaskGroup(of: Void.self) { group in
        // client → harness: forward each phone line to the harness's stdin.
        group.addTask {
            for await line in client.inboundLines() { harness.send(line) }
        }
        // harness → client: forward each harness line back to the phone.
        group.addTask {
            for await line in harness.inboundLines() { client.send(line) }
        }
        // Whichever side closes first returns here; cancel the sibling so its `for await`
        // stops, then close BOTH transports (idempotent) so the still-open side is torn down.
        await group.next()
        group.cancelAll()
        client.close()
        harness.close()
    }
}

/// The single seam the node calls to run ANY selectable backend over an already-verified
/// client transport. Dispatches on the descriptor's `kind`:
///   • `.builtIn`               → `runACPAgent(transport: client, llm: llm, …)` — the
///     unchanged Phase-1 built-in path (the bring-your-own-model reference harness, driven
///     by `llm`).
///   • `.stdioSpawn`/`.a2aRemote`→ build the harness's `ACPTransport` via `factory`
///     (`.stdioSpawn` spawns a subprocess, `.a2aRemote` bridges to an A2A agent — the
///     factory owns which), then `runACPProxy` between the phone and it; `llm` is IGNORED
///     (external harnesses bring their own model).
///
/// `client` MUST already be owner-verified (see the trust-boundary note on `runACPProxy`).
/// Returns when the session ends (transport closed / harness exited). On a factory build
/// failure the client transport is closed so the phone sees a clean disconnect rather than
/// a hang.
///
/// macOS-only because the default factory's `.stdioSpawn` branch spawns a `Process`. The
/// node (Mac/server/Pi) hosts harnesses; the phone is the ACP client and calls
/// `runACPAgent`/drives a remote one, never `runHarness`. Same gating as `runACPAgent` and
/// `StdioHarnessTransport`.
#if os(macOS)
public func runHarness(
    descriptor: HarnessDescriptor,
    client: any ACPTransport,
    llm: any LLMClient,
    toolEnvironment: ToolEnvironment = .fromEnvironment(),
    config: AgentConfig = .fromEnvironment(),
    configDir: String? = nil,
    streamingEnabled: Bool = true,
    extraTools: (any ExtraToolProvider)? = nil,
    factory: any HarnessTransportFactory = DefaultHarnessTransportFactory()
) async {
    switch descriptor.kind {
    case .builtIn:
        // Unchanged built-in path: run the in-process ACPAgent over the phone transport.
        // `extraTools` (Phase D3 MCP chat-tool passthrough) is built-in-only — an external
        // harness brings its own tools and never sees the phone's MCP seam.
        await runACPAgent(
            transport: client, llm: llm, toolEnvironment: toolEnvironment,
            config: config, configDir: configDir, streamingEnabled: streamingEnabled,
            extraTools: extraTools)

    case .stdioSpawn, .a2aRemote:
        // Build the external harness's transport (spawn or A2A bridge, per `factory`) and
        // pipe the phone's verified stream both ways.
        let harness: any ACPTransport
        do {
            harness = try factory.makeTransport(for: descriptor)
        } catch {
            // Build failed: close the phone side so it sees a clean disconnect (the phone's
            // in-flight initialize fails via failAll, not a hang). The harness never started,
            // so nothing to tear down beyond this.
            client.close()
            return
        }
        await runACPProxy(client: client, harness: harness)
    }
}
#endif  // os(macOS) — runHarness spawns a Process for .stdioSpawn (node-side only)
