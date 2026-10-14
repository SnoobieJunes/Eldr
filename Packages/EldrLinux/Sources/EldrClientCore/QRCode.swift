// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A small QR Code encoder for pairing links (WS-N4, DEVIATIONS AC175). It writes only
/// byte mode at error-correction level M, versions 1–10, which fits up to 213 bytes, and
/// a `pqrc:add` link is about 110. There are no dependencies. ISO/IEC 18004 structure:
/// finder/timing/alignment patterns, RS over GF(256) (poly 0x11D), and all eight masks
/// with the standard penalty score.
public struct QRCode: Sendable, Equatable {
    public let size: Int
    /// Row-major; true = dark.
    public let modules: [Bool]

    public enum EncodeError: Error, Equatable { case tooLong(Int) }

    public func isDark(_ x: Int, _ y: Int) -> Bool { modules[y * size + x] }

    // (data codewords per block, block count) groups, EC codewords per block — level M.
    static let blocks: [(groups: [(Int, Int)], ec: Int)] = [
        ([(16, 1)], 10), ([(28, 1)], 16), ([(44, 1)], 26), ([(32, 2)], 18), ([(43, 2)], 24),
        ([(27, 4)], 16), ([(31, 4)], 18), ([(38, 2), (39, 2)], 22), ([(36, 3), (37, 2)], 22),
        ([(43, 4), (44, 1)], 26),
    ]
    static let alignment: [[Int]] = [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
    ]

    public static func encode(_ text: String) throws -> QRCode {
        let data = Array(text.utf8)
        var version = 0
        for v in 1...10 {
            let cap = blocks[v - 1].groups.reduce(0) { $0 + $1.0 * $1.1 }
            let countBits = v < 10 ? 8 : 16
            if 4 + countBits + data.count * 8 <= cap * 8 { version = v; break }
        }
        guard version > 0 else { throw EncodeError.tooLong(data.count) }
        let spec = blocks[version - 1]
        let dataCap = spec.groups.reduce(0) { $0 + $1.0 * $1.1 }

        // Bit stream: mode 0100, count, bytes, terminator, pad to byte, pad codewords.
        var bits: [Bool] = []
        func put(_ v: Int, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bits.append((v >> i) & 1 == 1) } }
        put(0b0100, 4)
        put(data.count, version < 10 ? 8 : 16)
        for b in data { put(Int(b), 8) }
        put(0, min(4, dataCap * 8 - bits.count))
        while bits.count % 8 != 0 { bits.append(false) }
        var codewords: [UInt8] = stride(from: 0, to: bits.count, by: 8).map { i in
            (0..<8).reduce(UInt8(0)) { $0 << 1 | (bits[i + $1] ? 1 : 0) }
        }
        var pad: UInt8 = 0xEC
        while codewords.count < dataCap { codewords.append(pad); pad = pad == 0xEC ? 0x11 : 0xEC }

        // Split into blocks, add RS, interleave.
        var dataBlocks: [[UInt8]] = []
        var off = 0
        for (len, count) in spec.groups {
            for _ in 0..<count { dataBlocks.append(Array(codewords[off..<off + len])); off += len }
        }
        let gen = RS.generator(spec.ec)
        let ecBlocks = dataBlocks.map { RS.remainder($0, gen) }
        var final: [UInt8] = []
        let maxLen = dataBlocks.map(\.count).max() ?? 0
        for i in 0..<maxLen { for b in dataBlocks where i < b.count { final.append(b[i]) } }
        for i in 0..<spec.ec { for b in ecBlocks { final.append(b[i]) } }

        var m = Matrix(version: version)
        m.drawFunctionPatterns()
        m.drawCodewords(final)
        var best: Matrix?
        var bestPenalty = Int.max
        for mask in 0..<8 {
            var t = m
            t.applyMask(mask)
            t.drawFormat(mask)
            let p = t.penalty()
            if p < bestPenalty { bestPenalty = p; best = t }
        }
        let chosen = best ?? m
        return QRCode(size: chosen.size, modules: chosen.dark)
    }

    /// Terminal rendering with half-block characters (two module rows per line) and a
    /// 2-module quiet zone. Dark-on-light, the way scanners expect.
    public func terminalString() -> String {
        let q = 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let xx = x - q, yy = y - q
            return xx >= 0 && yy >= 0 && xx < size && yy < size && isDark(xx, yy)
        }
        var out = ""
        let n = size + 2 * q
        for y in stride(from: 0, to: n, by: 2) {
            for x in 0..<n {
                let top = dark(x, y), bottom = y + 1 < n && dark(x, y + 1)
                switch (top, bottom) {
                case (false, false): out += "█"
                case (true, false): out += "▄"
                case (false, true): out += "▀"
                case (true, true): out += " "
                }
            }
            out += "\n"
        }
        return out
    }

    /// RGBA pixels (scale px per module, 4-module quiet zone) for a GdkMemoryTexture.
    public func rgba(scale: Int) -> (width: Int, bytes: [UInt8]) {
        let q = 4, n = (size + 2 * q) * scale
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<size { for x in 0..<size where isDark(x, y) {
            for dy in 0..<scale { for dx in 0..<scale {
                let i = (((y + q) * scale + dy) * n + (x + q) * scale + dx) * 4
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0
            } }
        } }
        return (n, px)
    }
}

enum RS {
    static let exp: [UInt8] = {
        var e = [UInt8](repeating: 0, count: 512)
        var x = 1
        for i in 0..<255 { e[i] = UInt8(x); x <<= 1; if x & 0x100 != 0 { x ^= 0x11D } }
        for i in 255..<512 { e[i] = e[i - 255] }
        return e
    }()
    static let log: [Int] = {
        var l = [Int](repeating: 0, count: 256)
        for i in 0..<255 { l[Int(exp[i])] = i }
        return l
    }()
    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }
    /// Generator polynomial coefficients (highest degree first, leading 1 omitted).
    static func generator(_ degree: Int) -> [UInt8] {
        var g: [UInt8] = [1]
        for i in 0..<degree {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, c) in g.enumerated() {
                next[j] ^= c
                next[j + 1] ^= mul(c, exp[i])
            }
            g = next
        }
        return Array(g.dropFirst())
    }
    static func remainder(_ data: [UInt8], _ gen: [UInt8]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: gen.count)
        for d in data {
            let factor = d ^ r[0]
            r.removeFirst(); r.append(0)
            for i in 0..<gen.count { r[i] ^= mul(gen[i], factor) }
        }
        return r
    }
}

struct Matrix {
    let version: Int
    let size: Int
    var dark: [Bool]
    var function: [Bool]

    init(version: Int) {
        self.version = version
        size = version * 4 + 17
        dark = [Bool](repeating: false, count: size * size)
        function = dark
    }
    mutating func set(_ x: Int, _ y: Int, _ d: Bool) { dark[y * size + x] = d; function[y * size + x] = true }

    mutating func drawFunctionPatterns() {
        for i in 0..<size { set(6, i, i % 2 == 0); set(i, 6, i % 2 == 0) }
        finder(3, 3); finder(size - 4, 3); finder(3, size - 4)
        let pos = QRCode.alignment[version - 1]
        for (i, a) in pos.enumerated() { for (j, b) in pos.enumerated() {
            if (i == 0 && j == 0) || (i == 0 && j == pos.count - 1) || (i == pos.count - 1 && j == 0) { continue }
            for dy in -2...2 { for dx in -2...2 { set(a + dx, b + dy, max(abs(dx), abs(dy)) != 1) } }
        } }
        drawFormat(0)  // reserve; rewritten per mask
        if version >= 7 {
            var rem = version
            for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
            let bits = version << 12 | rem
            for i in 0..<18 {
                let d = (bits >> i) & 1 == 1
                let a = size - 11 + i % 3, b = i / 3
                set(a, b, d); set(b, a, d)
            }
        }
    }
    mutating func finder(_ cx: Int, _ cy: Int) {
        for dy in -4...4 { for dx in -4...4 {
            let x = cx + dx, y = cy + dy
            guard x >= 0, y >= 0, x < size, y < size else { continue }
            let dist = max(abs(dx), abs(dy))
            set(x, y, dist != 2 && dist != 4)
        } }
    }
    mutating func drawFormat(_ mask: Int) {
        let data = 0b00 << 3 | mask  // level M = 00
        var rem = data
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        let bits = (data << 10 | rem) ^ 0x5412
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
        for i in 0...5 { set(8, i, bit(i)) }
        set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8))
        for i in 9..<15 { set(14 - i, 8, bit(i)) }
        for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
        set(8, size - 8, true)  // the always-dark module
    }
    mutating func drawCodewords(_ cw: [UInt8]) {
        var i = 0
        let total = cw.count * 8
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = ((right + 1) & 2) == 0
                    let y = upward ? size - 1 - vert : vert
                    if !function[y * size + x] && i < total {
                        dark[y * size + x] = (cw[i >> 3] >> (7 - (i & 7))) & 1 == 1
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }
    mutating func applyMask(_ mask: Int) {
        for y in 0..<size { for x in 0..<size where !function[y * size + x] {
            let inv: Bool
            switch mask {
            case 0: inv = (x + y) % 2 == 0
            case 1: inv = y % 2 == 0
            case 2: inv = x % 3 == 0
            case 3: inv = (x + y) % 3 == 0
            case 4: inv = (x / 3 + y / 2) % 2 == 0
            case 5: inv = x * y % 2 + x * y % 3 == 0
            case 6: inv = (x * y % 2 + x * y % 3) % 2 == 0
            default: inv = ((x + y) % 2 + x * y % 3) % 2 == 0
            }
            if inv { dark[y * size + x].toggle() }
        } }
    }
    func penalty() -> Int {
        var p = 0
        func at(_ x: Int, _ y: Int) -> Bool { dark[y * size + x] }
        for horizontal in [true, false] {
            for a in 0..<size {
                var run = 1
                for b in 1..<size {
                    let cur = horizontal ? at(b, a) : at(a, b), prev = horizontal ? at(b - 1, a) : at(a, b - 1)
                    if cur == prev { run += 1; if run == 5 { p += 3 } else if run > 5 { p += 1 } } else { run = 1 }
                }
                // 1:1:3:1:1 finder-like patterns with 4 light modules on one side.
                if size >= 11 {
                    for b in 0...(size - 11) {
                        let s = (0..<11).map { horizontal ? at(b + $0, a) : at(a, b + $0) }
                        let f1: [Bool] = [true, false, true, true, true, false, true, false, false, false, false]
                        if s == f1 || s == Array(f1.reversed()) { p += 40 }
                    }
                }
            }
        }
        for y in 0..<(size - 1) { for x in 0..<(size - 1) {
            let c = at(x, y)
            if c == at(x + 1, y) && c == at(x, y + 1) && c == at(x + 1, y + 1) { p += 3 }
        } }
        let darkCount = dark.filter { $0 }.count
        let k = (abs(darkCount * 20 - size * size * 10) + size * size - 1) / (size * size) - 1
        p += max(0, k) * 10
        return p
    }
}
