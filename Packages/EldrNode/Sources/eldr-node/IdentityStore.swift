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

/// Select the node's identity store for the current platform.
/// - Apple: the Secure-Enclave-backed `NodeKeychain`.
/// - Linux: the `FileIdentityStore` ladder (WS-L3) — TPM-sealed via systemd-creds where a
///   secure element exists, else a scrypt-passphrase KEK; fail-closed at every doubt. The
///   RESOLVED posture is reported LOUDLY so an operator never gets a silent downgrade
///   (invariant 10). The Linux fail-closed cases live in `LinuxKeystoreError`.
func makeIdentityStore() throws -> any IdentityStore {
    #if canImport(Security)
    return NodeKeychain()
    #else
    let (store, posture) = try makeLinuxIdentityStore()
    FileHandle.standardError.write(Data(("eldr-node: " + posture.report + "\n").utf8))
    return store
    #endif
}
