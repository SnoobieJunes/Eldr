// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import EldrKeystore
import Foundation

/// Huginn's secret storage seam: the macOS app uses the Keychain; Linux uses an
/// EldrKeystore `FileIdentityStore` (per-account AES-GCM files under a master key from
/// the TPM/systemd-creds or scrypt-passphrase ladder). Accounts mirror the Mac names:
/// `llm-token`, `metadata-key`, `buzzagent.<id>`.
public protocol SecretStore: Sendable {
    func load(account: String) -> Data?
    func save(_ data: Data, account: String) throws
    func delete(account: String)
}

extension FileIdentityStore: SecretStore {}

public enum HuginnSecrets {
    /// Huginn's own keystore profile: separate directory, HKDF label and credential from
    /// eldr-node and eldr-chat, so the three never share key material.
    public static let profile = KeystoreProfile(
        tool: "huginn", hkdfSaltLabel: "huginn/keystore/v1", credentialName: "huginn-master",
        passphraseEnv: "HUGINN_PASSPHRASE", passphraseFileEnv: "HUGINN_PASSPHRASE_FILE")

    public static let llmTokenAccount = "llm-token"
    public static let metadataKeyAccount = "metadata-key"

    /// Open the keystore (fails closed exactly like eldr-node: TPM present but unused ⇒
    /// refuse; no passphrase source ⇒ throw). Returns the store and the posture label.
    public static func open(
        paths: HuginnPaths, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (store: any SecretStore, posture: String) {
        let (store, posture) = try makeLinuxKeystore(
            directory: URL(fileURLWithPath: paths.keystoreDir), profile: profile,
            environment: environment)
        return (store, label(posture))
    }

    /// Protection label shown persistently (AC218): a non-hardware posture is a warning.
    public static func label(_ p: KeystorePosture) -> String {
        p.isHardwareBacked ? "🔒 Keys: \(p.shortLabel)" : "⚠️ Keys: \(p.shortLabel)"
    }

    /// True when `label` describes a non-hardware (warning) posture.
    public static func isWarning(_ label: String) -> Bool { label.hasPrefix("⚠️") }

    public static func string(_ store: any SecretStore, _ account: String) -> String? {
        store.load(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The B2 metadata key (32 random bytes) that seals `events.jsonl` lines and
    /// `eldr.md`. The Mac app wraps it with the Secure Enclave; here it lives in the
    /// keystore and is minted on first use.
    public static func metadataKey(_ store: any SecretStore) throws -> Data {
        if let k = store.load(account: metadataKeyAccount), k.count == 32 { return k }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try store.save(key, account: metadataKeyAccount)
        return key
    }
}
