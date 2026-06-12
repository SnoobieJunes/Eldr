import Foundation

/// Fixed-size bucket padding (SPEC §7): defeats size-based traffic analysis.
/// Applied to plaintext BEFORE AEAD encryption.
///
/// Layout: u32be(plaintext length) || plaintext || zero fill, where the zero
/// fill extends to the bucket boundary. The 4-byte length prefix sits outside
/// the bucket accounting, so a plaintext of exactly 65536 bytes (the inline
/// limit, SPEC §11) still fits the largest bucket. Total padded size for
/// bucket B is therefore B + 4, and ciphertext size is B + 4 + 16 (GCM tag).
public enum Padding {
    /// Smallest bucket that holds `length` plaintext bytes.
    public static func bucket(for length: Int) throws -> Int {
        guard length <= PQRCConstants.inlineSizeLimit else {
            throw PQRCError.plaintextExceedsInlineLimit(size: length)
        }
        guard let bucket = PQRCConstants.paddingBuckets.first(where: { $0 >= length }) else {
            throw PQRCError.plaintextExceedsInlineLimit(size: length)
        }
        return bucket
    }

    public static func pad(_ plaintext: Data) throws -> Data {
        let bucket = try bucket(for: plaintext.count)
        var padded = Data(uint32BE: UInt32(plaintext.count))
        padded.append(plaintext)
        padded.append(Data(count: bucket - plaintext.count))
        return padded
    }

    public static func unpad(_ padded: Data) throws -> Data {
        guard let length = padded.uint32BE(at: 0), padded.count >= 4 + Int(length) else {
            throw PQRCError.malformedPadding
        }
        // The declared length must map to the bucket actually present
        // (a mismatch indicates tampering or corruption).
        guard let expectedBucket = try? bucket(for: Int(length)),
            padded.count == 4 + expectedBucket
        else {
            throw PQRCError.malformedPadding
        }
        return padded.subdata(in: 4..<(4 + Int(length)))
    }
}
