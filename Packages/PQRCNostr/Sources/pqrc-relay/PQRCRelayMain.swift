// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCNostr

/// `pqrc-relay` — the localhost PQRC relay server (APP-SPEC §4, stretch goal
/// S2): a NIP-01 + NIP-42 WebSocket frontend over the same
/// `LocalRelaySimulator` the test matrix proves, including the anchor-relay
/// rule (kind-1059 served only to the AUTHed, p-tagged recipient) and
/// optional chaos injection for resilience demos.
///
/// Usage:
///   swift run pqrc-relay [--port 7777] [--drop 0.2] [--jitter 150]
///                        [--duplicate 0.1] [--reorder 8] [--seed 42]
///
/// Dev/demo tooling only — events live in memory, nothing persists across
/// restarts. Production = AUTH-gated strfry/khatru (SPEC §9.1, §15); see
/// docs/SETUP-GUIDE.md for both paths.
@main
struct PQRCRelayMain {
    static func main() async throws {
        #if canImport(Network)
        let arguments = parse(CommandLine.arguments)
        let chaos = ChaosOptions(
            latencyJitterMillis: Int(arguments["jitter"] ?? "0") ?? 0,
            dropRate: Double(arguments["drop"] ?? "0") ?? 0,
            duplicateRate: Double(arguments["duplicate"] ?? "0") ?? 0,
            reorderWindow: Int(arguments["reorder"] ?? "0") ?? 0,
            seed: UInt64(arguments["seed"] ?? "1") ?? 1)
        let port = UInt16(arguments["port"] ?? "7777") ?? 7777

        let relay = LocalRelaySimulator(url: "ws://127.0.0.1:\(port)", chaos: chaos)
        let server = NostrRelayServer(relay: relay, port: port)
        let bound = try await server.start()

        print("pqrc-relay listening on ws://127.0.0.1:\(bound)")
        print("  NIP-01 subset: EVENT / REQ / EOSE / OK / CLOSE")
        print("  NIP-42 AUTH: kind-1059 envelopes served only to the AUTHed recipient")
        if chaos.dropRate > 0 || chaos.latencyJitterMillis > 0 || chaos.duplicateRate > 0
            || chaos.reorderWindow > 0 {
            print(
                "  chaos: drop=\(chaos.dropRate) jitter=\(chaos.latencyJitterMillis)ms "
                    + "duplicate=\(chaos.duplicateRate) reorder=\(chaos.reorderWindow) seed=\(chaos.seed)")
        }
        print("Stop with Ctrl-C.")

        // Park the main task forever; connections are served by the server actor.
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
        #else
        // The built-in relay server uses Network.framework (Apple-only). A Linux host runs a
        // khatru/strfry relay instead, or the Linux node connects to a relay hosted elsewhere.
        // (A NIO-based Linux relay is a natural follow-up — the NIO WebSocket code exists in
        // NIOWebSocketChannel/WS-L5.)
        FileHandle.standardError.write(Data(
            ("pqrc-relay: the built-in relay uses Network.framework (Apple-only). On Linux run a "
                + "khatru/strfry relay, or point the node at a relay hosted elsewhere.\n").utf8))
        exit(1)
        #endif
    }

    /// Tiny `--flag value` parser — avoids an ArgumentParser dependency for a
    /// six-flag dev tool (CLAUDE.md: no dependencies beyond the pinned set).
    private static func parse(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 1
        while index + 1 < arguments.count {
            if arguments[index].hasPrefix("--") {
                result[String(arguments[index].dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }
}
