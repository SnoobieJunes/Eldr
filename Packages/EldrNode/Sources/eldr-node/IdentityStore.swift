// SPDX-License-Identifier: Apache-2.0
import EldrKeystore
import Foundation


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
