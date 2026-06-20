import Crypto
import Foundation

// Small byte-level helpers shared across the core. Not cryptographic primitives.

@inlinable
public func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

extension Data {
    /// Lowercase hex encoding.
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Decode lowercase/uppercase hex; nil on malformed input.
    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    /// Big-endian 4-byte encoding of a UInt32.
    public init(uint32BE value: UInt32) {
        self.init([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    /// Big-endian 8-byte encoding of an Int64 (used for fuzzed timestamps in AD).
    public init(int64BE value: Int64) {
        let v = UInt64(bitPattern: value)
        self.init([
            UInt8(truncatingIfNeeded: v >> 56),
            UInt8(truncatingIfNeeded: v >> 48),
            UInt8(truncatingIfNeeded: v >> 40),
            UInt8(truncatingIfNeeded: v >> 32),
            UInt8(truncatingIfNeeded: v >> 24),
            UInt8(truncatingIfNeeded: v >> 16),
            UInt8(truncatingIfNeeded: v >> 8),
            UInt8(truncatingIfNeeded: v),
        ])
    }

    /// Reads a big-endian UInt32 at `offset`; nil if out of bounds.
    public func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else { return nil }
        let i = startIndex + offset
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16)
            | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }

    /// Overwrites every byte of this buffer with zero, in place.
    ///
    /// Best-effort heap hygiene for transient secret copies (key/IKM bytes
    /// extracted from CryptoKit, which zeroes only its own `SymmetricKey` /
    /// `SharedSecret`). Call once the value has been fully consumed. Routed
    /// through Foundation's `resetBytes(in:)` — an opaque, non-inlinable call
    /// the optimizer cannot prove dead and elide. Not a substitute for keeping
    /// secrets out of swappable memory; it only shortens the window a copy
    /// lingers in the heap. No-op on an empty buffer.
    @inlinable
    public mutating func zeroize() {
        guard !isEmpty else { return }
        resetBytes(in: startIndex..<endIndex)
    }
}

extension SymmetricKey {
    /// Raw key bytes. Used at controlled points (KDF chaining); never logged.
    public var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}
