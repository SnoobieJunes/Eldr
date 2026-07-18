import PQRCACP

// The concrete `HarnessTransportFactory` a node injects into `ACPAgent`/`runHarness` when
// it wants `.a2aRemote` delegation available, alongside the always-supported `.stdioSpawn`.
// This is the ONLY place `A2AACPBridge` is wired in — `PQRCACP` itself never references it
// (see `HarnessTransportFactory.swift`'s file-header note).

#if os(macOS)
/// Handles every non-`.builtIn` `HarnessKind` this package knows about: `.stdioSpawn`
/// delegates to `DefaultHarnessTransportFactory` (unchanged spawn behavior), `.a2aRemote`
/// bridges to a real A2A agent via `A2AACPBridge`. `.builtIn` throws, same as the default
/// factory — that kind never reaches a transport factory (`runACPAgent` handles it
/// in-process).
public struct A2AHarnessFactory: HarnessTransportFactory {
    private let stdio = DefaultHarnessTransportFactory()

    public init() {}

    public func makeTransport(for descriptor: HarnessDescriptor) throws -> any ACPTransport {
        switch descriptor.kind {
        case .stdioSpawn:
            return try stdio.makeTransport(for: descriptor)
        case .a2aRemote:
            return try A2AACPBridge.makeTransport(descriptor: descriptor)
        case .builtIn:
            throw HarnessTransportError.unsupportedKind(descriptor.kind)
        }
    }
}
#endif  // os(macOS) — mirrors A2AACPBridge/DefaultHarnessTransportFactory's gating
