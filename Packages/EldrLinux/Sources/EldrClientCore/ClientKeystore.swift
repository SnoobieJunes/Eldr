// SPDX-License-Identifier: Apache-2.0
@_exported import EldrKeystore
import Foundation

/// The client's keystore: the shared `EldrKeystore` ladder under the `eldrChat` profile
/// (its own HKDF label, env names and credential — never the node's).
public func makeClientKeystore(
    directory: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    tpmPresent: () -> Bool = defaultTpmPresent
) throws -> (store: FileIdentityStore, posture: KeystorePosture) {
    try makeLinuxKeystore(
        directory: directory, profile: .eldrChat, environment: environment, tpmPresent: tpmPresent)
}
