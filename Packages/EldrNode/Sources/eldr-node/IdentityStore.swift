// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The node's long-term-secret store seam (CLAUDE.md invariant 10). Extracted from the
/// concrete macOS `NodeKeychain` so the node's identity load/create path is platform-
/// agnostic: Apple conforms via the Secure-Enclave-backed Keychain; a Linux host will
/// conform via a hardware-wrapped file store (WS-L3: a TPM-sealed KEK via systemd-creds,
/// or a scrypt-passphrase KEK only where no secure element exists). The surface is exactly
/// what `EldrNodeMain`'s load-or-create helpers need — nothing more (least authority).
protocol IdentityStore: Sendable {
    /// Read the item for `account`, or nil if absent. MUST never log the bytes (inv. 12).
    func load(account: String) -> Data?
    /// Store `data` for `account`, replacing any prior value, bound to this device and
    /// readable only while unlocked (inv. 10). Throws on a hard store error.
    func save(_ data: Data, account: String) throws
    /// Remove the item for `account` (no-op if absent).
    func delete(account: String)
}

enum IdentityStoreError: Error, CustomStringConvertible {
    /// No hardened keystore conformance exists for this platform yet — fail closed rather
    /// than write long-term secrets unwrapped (SPEC §0, invariant 10).
    case noHardenedKeystore(String)
    var description: String {
        switch self {
        case .noHardenedKeystore(let why): return why
        }
    }
}

/// Select the node's identity store for the current platform.
/// - Apple: the Secure-Enclave-backed `NodeKeychain`.
/// - Elsewhere (Linux): the hardware-wrapped file store is WS-L3 and not built yet, so this
///   FAILS CLOSED — the `eldr-node` executable compiles and the port is unblocked, but the
///   node refuses to run until invariant 10 is actually satisfied on this host. This is the
///   exact seam WS-L3 fills (TPM-sealed via systemd-creds; scrypt-passphrase KEK fallback).
func makeIdentityStore() throws -> any IdentityStore {
    #if canImport(Security)
    return NodeKeychain()
    #else
    throw IdentityStoreError.noHardenedKeystore(
        "eldr-node: no hardened keystore on this platform yet. The Linux keystore ladder "
        + "(TPM-sealed via systemd-creds, or a scrypt-passphrase KEK where no secure element "
        + "exists — invariant 10) is WS-L3 and not built. Refusing to store long-term secrets "
        + "unwrapped (SPEC §0, fail-closed).")
    #endif
}
