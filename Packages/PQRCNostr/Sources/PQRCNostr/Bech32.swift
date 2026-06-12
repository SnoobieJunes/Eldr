import Foundation

/// Bech32 encoding (BIP-173) for npub/nsec display. An encoding, not a
/// cryptographic primitive.
public enum Bech32 {
    static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    static let generator: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]

    static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ff_ffff) << 5 ^ UInt32(value)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 {
                chk ^= generator[i]
            }
        }
        return chk
    }

    static func hrpExpand(_ hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        return (0..<6).map { UInt8((mod >> (5 * (5 - UInt32($0)))) & 31) }
    }

    static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var out: [UInt8] = []
        let maxv = (1 << to) - 1
        for value in data {
            if Int(value) >> from != 0 { return nil }
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }

    public static func encode(hrp: String, data: Data) -> String {
        let five = convertBits(Array(data), from: 8, to: 5, pad: true) ?? []
        let checksum = createChecksum(hrp: hrp, data: five)
        return hrp + "1" + (five + checksum).map { String(charset[Int($0)]) }.joined()
    }

    public static func decode(_ encoded: String) -> (hrp: String, data: Data)? {
        let lowered = encoded.lowercased()
        guard let separator = lowered.lastIndex(of: "1") else { return nil }
        let hrp = String(lowered[..<separator])
        let dataPart = lowered[lowered.index(after: separator)...]
        guard hrp.count >= 1, dataPart.count >= 6 else { return nil }
        var values: [UInt8] = []
        for char in dataPart {
            guard let index = charset.firstIndex(of: char) else { return nil }
            values.append(UInt8(index))
        }
        guard polymod(hrpExpand(hrp) + values) == 1 else { return nil }
        guard let eight = convertBits(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else {
            return nil
        }
        return (hrp, Data(eight))
    }

    public static func npub(_ pubkeyHex: String) -> String {
        encode(hrp: "npub", data: Data(hexString: pubkeyHex) ?? Data())
    }

    public static func pubkeyHex(fromNpub npub: String) -> String? {
        guard let (hrp, data) = decode(npub), hrp == "npub", data.count == 32 else { return nil }
        return data.hexString
    }
}
