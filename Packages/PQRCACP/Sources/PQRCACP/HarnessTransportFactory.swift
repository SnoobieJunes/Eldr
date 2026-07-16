import Foundation

// The seam that keeps PQRCACP dependency-free while still supporting harness kinds that
// NEED a dependency to reach (SwiftA2A for `.a2aRemote`), mirroring how `ExtraToolProvider`
// lets the agent gain MCP-passthrough capability without importing PQRCMCP: `runHarness`
// (ACPProxy.swift) and `ACPAgent.delegateToCloudAgent` never construct a concrete
// transport themselves for a non-`.builtIn` descriptor — they ask an injected
// `HarnessTransportFactory`. Production (macOS node) defaults to
// `DefaultHarnessTransportFactory`, which only knows `.stdioSpawn`; the `A2AHarness`
// target (the one place in this package that depends on `SwiftA2A`) supplies its OWN
// factory that also handles `.a2aRemote` and delegates `.stdioSpawn` back to this one.
// Adding a new non-built-in `HarnessKind` is therefore a new factory + an injection site,
// never a new dependency on the core `PQRCACP` target.

/// Failures constructing a transport for a non-`.builtIn` harness descriptor.
public enum HarnessTransportError: Error, Sendable, Equatable {
    /// No factory in the chain knows how to reach this `HarnessKind` (e.g. a bare
    /// `DefaultHarnessTransportFactory` asked to build `.a2aRemote`, or any factory asked
    /// to build `.builtIn` — that kind never goes through a transport factory at all, it
    /// runs `runACPAgent` in-process).
    case unsupportedKind(HarnessKind)
}

/// Builds a started `ACPTransport` for a non-`.builtIn` harness descriptor. `Sendable` so
/// it can be injected into the actor-isolated `ACPAgent` and passed into `runHarness`
/// across `await` boundaries.
public protocol HarnessTransportFactory: Sendable {
    /// Build a started `ACPTransport` for `descriptor`, or throw. The returned transport
    /// must already be reading (equivalent to `StdioHarnessTransport.start()` having
    /// succeeded) — the caller pipes it into `runACPProxy`/`ACPClientDriver` immediately,
    /// it does not call any further lifecycle method before use. `descriptor.kind` is
    /// never `.builtIn` here (that kind is handled entirely by `runACPAgent`, in-process,
    /// before a factory is ever consulted).
    func makeTransport(for descriptor: HarnessDescriptor) throws -> any ACPTransport
}

#if os(macOS)
/// The production default: `.stdioSpawn` spawns the descriptor as a subprocess via
/// `StdioHarnessTransport` (macOS-only — `Process` is unavailable on iOS, same gating as
/// that type). Every other kind — `.builtIn` (never reaches a factory) and `.a2aRemote`
/// (needs `A2AHarness`'s factory) — throws `HarnessTransportError.unsupportedKind` rather
/// than silently doing nothing, so a caller that forgets to inject the richer factory
/// fails loudly instead of hanging.
public struct DefaultHarnessTransportFactory: HarnessTransportFactory {
    public init() {}

    public func makeTransport(for descriptor: HarnessDescriptor) throws -> any ACPTransport {
        switch descriptor.kind {
        case .stdioSpawn:
            let transport = StdioHarnessTransport(descriptor: descriptor)
            try transport.start()
            return transport
        case .builtIn, .a2aRemote:
            throw HarnessTransportError.unsupportedKind(descriptor.kind)
        }
    }
}
#endif  // os(macOS) — DefaultHarnessTransportFactory spawns a Process for .stdioSpawn
