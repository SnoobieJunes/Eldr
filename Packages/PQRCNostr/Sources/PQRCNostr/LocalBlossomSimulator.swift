// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import PQRCCore

/// In-process Blossom server (SPEC §11): content-addressed put/get by SHA-256,
/// with optional mirrors (BUD-04 durability). Stores only opaque ciphertext —
/// blobs are encrypted BEFORE upload.
public actor LocalBlossomSimulator: BlobStore {
    public let baseURL: String
    private var blobs: [String: Data] = [:]
    private var mirrors: [LocalBlossomSimulator] = []
    private var failing = false

    public init(baseURL: String = "local://blossom") {
        self.baseURL = baseURL
    }

    public func addMirror(_ mirror: LocalBlossomSimulator) {
        mirrors.append(mirror)
    }

    /// Simulates an outage: gets fail, forcing mirror fallback.
    public func setFailing(_ value: Bool) {
        failing = value
    }

    public func put(_ data: Data) async throws -> String {
        let hash = sha256(data).hexString
        blobs[hash] = data
        for mirror in mirrors {
            _ = try await mirror.put(data)
        }
        return hash
    }

    public func get(_ sha256Hex: String) async throws -> Data {
        if !failing, let blob = blobs[sha256Hex] {
            // Content addressing is verified on read, not trusted.
            guard sha256(blob).hexString == sha256Hex else {
                throw NostrError.blobIntegrityFailure
            }
            return blob
        }
        for mirror in mirrors {
            if let blob = try? await mirror.get(sha256Hex) {
                return blob
            }
        }
        throw NostrError.blobNotFound
    }

    public var blobCount: Int { blobs.count }
}

/// The >64 KB content path (SPEC §11): encrypt with a fresh symmetric key,
/// upload ciphertext, carry a fixed-size pointer inside the ratchet payload.
public enum BlobCipher {
    public struct Prepared: Sendable {
        public let pointer: ContentPointer
        public let ciphertext: Data
    }

    /// Encrypts and uploads; returns the pointer to embed in the rumor.
    public static func encryptAndStore(
        _ plaintext: Data, store: any BlobStore, mirrorURLs: [String] = [],
        randomSource: any RandomSource, nonceSource: any NonceSource
    ) async throws -> ContentPointer {
        let key = SymmetricKey(data: randomSource.bytes(32))
        let nonce = nonceSource.nextNonce()
        let sealed = try AES.GCM.seal(
            plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce))
        let blob = nonce + sealed.ciphertext + sealed.tag
        let hash = try await store.put(blob)
        return ContentPointer(
            blossomURL: "blossom/\(hash)",
            decryptionKey: key.rawData,
            sha256: hash,
            sizeBytes: blob.count,
            mirrorURLs: mirrorURLs
        )
    }

    public static func fetchAndDecrypt(
        _ pointer: ContentPointer, store: any BlobStore
    ) async throws -> Data {
        let blob = try await store.get(pointer.sha256)
        guard sha256(blob).hexString == pointer.sha256 else {
            throw NostrError.blobIntegrityFailure
        }
        guard blob.count >= 28 else { throw NostrError.blobIntegrityFailure }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: blob.prefix(12)),
                ciphertext: blob.dropFirst(12).dropLast(16),
                tag: blob.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: pointer.decryptionKey))
        } catch {
            throw NostrError.blobIntegrityFailure
        }
    }
}
