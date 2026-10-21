// SPDX-License-Identifier: Apache-2.0
import EldrKeystore
import Foundation

// WS-L3 — the node's Linux keystore (CLAUDE.md invariant 10). The implementation
// (FileIdentityStore, the TPM → refuse → scrypt-passphrase ladder, KeystorePosture) now
// lives in the shared `EldrKeystore` package so the Linux client uses the SAME code; this
// file keeps only the node's own wiring: its data directory and `KeystoreProfile.eldrNode`
// (byte-identical HKDF label / env names / credential name, so existing keystores load).

/// Build the Linux identity store and report which rung protects it. Returns the store and
/// the DERIVED posture (from what actually resolved the master key). Fail-closed at every
/// doubt (SPEC §0). Injectable environment for tests.
func makeLinuxIdentityStore(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    tpmPresent: () -> Bool = defaultTpmPresent
) throws -> (store: any IdentityStore, posture: KeystorePosture) {
    let (store, posture) = try makeLinuxKeystore(
        directory: keystoreDirectory(environment), profile: .eldrNode,
        environment: environment, tpmPresent: tpmPresent)
    return (store, posture)
}

/// `$ELDR_NODE_DATA_DIR` (tests) → `$XDG_DATA_HOME/eldr-node` → `$HOME/.local/share/eldr-node`.
private func keystoreDirectory(_ env: [String: String]) -> URL {
    if let override = env["ELDR_NODE_DATA_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    let base: String
    if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
        base = xdg
    } else if let home = env["HOME"], !home.isEmpty {
        base = home + "/.local/share"
    } else {
        base = FileManager.default.currentDirectoryPath + "/.eldr-node-data"
    }
    return URL(fileURLWithPath: base).appendingPathComponent("eldr-node")
}

