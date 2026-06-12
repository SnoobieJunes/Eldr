import Foundation

// MARK: - Determinism seams (TEST-PLAN §1)
//
// Production uses the system implementations; tests inject seeded/fixed ones.
// No unit test touches the network, the real clock, or system randomness.

/// Source of random bytes. Production: `SystemRandomSource`. Tests: `SeededRandomSource`.
public protocol RandomSource: Sendable {
    /// Returns `count` random bytes.
    func bytes(_ count: Int) -> Data
}

/// Source of AEAD nonces. Kept distinct from `RandomSource` so tests can assert
/// nonce uniqueness and reproduce exact ciphertexts.
public protocol NonceSource: Sendable {
    /// Returns a fresh 12-byte AES-GCM/ChaChaPoly nonce.
    func nextNonce() -> Data
}

/// Source of the current time. The key schedule MUST NOT depend on this
/// (SPEC §5.2); it exists only for timestamp fuzzing, ai_window expiry checks,
/// and UI concerns.
public protocol Clock: Sendable {
    /// Current time as Unix seconds.
    func now() -> Int64
}

// MARK: - Production implementations

public struct SystemRandomSource: RandomSource {
    public init() {}
    public func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            var generator = SystemRandomNumberGenerator()
            for i in 0..<buffer.count {
                buffer[i] = UInt8.random(in: .min ... .max, using: &generator)
            }
        }
        return data
    }
}

public struct SystemNonceSource: NonceSource {
    private let random = SystemRandomSource()
    public init() {}
    public func nextNonce() -> Data { random.bytes(12) }
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
}

// MARK: - Deterministic implementations (tests, vector generation, Local Universe)

/// Deterministic random source: a SHA-256-based counter stream over a seed.
/// Not a cryptographic primitive — a test fixture for reproducible byte streams.
public final class SeededRandomSource: RandomSource, NonceSource, @unchecked Sendable {
    // @unchecked Sendable justification: all mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var state: Data
    private var counter: UInt64 = 0
    private var pool = Data()

    public init(seed: UInt64) {
        var seedData = Data("pqrc-seeded-random".utf8)
        withUnsafeBytes(of: seed.bigEndian) { seedData.append(contentsOf: $0) }
        self.state = seedData
    }

    public init(seed: Data) {
        self.state = Data("pqrc-seeded-random".utf8) + seed
    }

    public func bytes(_ count: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        while pool.count < count {
            var block = state
            withUnsafeBytes(of: counter.bigEndian) { block.append(contentsOf: $0) }
            counter += 1
            pool.append(contentsOf: sha256(block))
        }
        let out = pool.prefix(count)
        pool.removeFirst(count)
        return Data(out)
    }

    public func nextNonce() -> Data { bytes(12) }
}

/// Fixed, mutable test clock. Mutating it mid-conversation MUST have zero
/// effect on the key schedule (TEST-PLAN §4 `noTimers_keyScheduleHasNoClockDependency`).
public final class FixedClock: Clock, @unchecked Sendable {
    // @unchecked Sendable justification: single Int64 guarded by `lock`.
    private let lock = NSLock()
    private var time: Int64

    public init(now: Int64 = 1_750_000_000) {
        self.time = now
    }

    public func now() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    public func set(_ newTime: Int64) {
        lock.lock()
        defer { lock.unlock() }
        time = newTime
    }

    public func advance(by seconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        time += seconds
    }
}
