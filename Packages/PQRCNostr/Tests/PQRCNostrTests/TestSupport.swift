import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

extension Tag {
    @Tag static var envelope: Tag
    @Tag static var transport: Tag
    @Tag static var group: Tag
    @Tag static var security: Tag
}

enum Vectors {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PQRCNostrTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // PQRCNostr/
            .deletingLastPathComponent()  // Packages/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("TestVectors")
    }

    static func loadOrGenerate<V: Codable>(_ name: String, generate: () throws -> V) throws -> V {
        let fileURL = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(try generate()).write(to: fileURL, options: .atomic)
        }
        return try JSONDecoder().decode(V.self, from: try Data(contentsOf: fileURL))
    }
}

/// Test-integrity guard (TEST-PLAN §2). `Vectors.loadOrGenerate` regenerates a
/// vector when its file is absent, so a deleted or never-committed vector would
/// let the generator's own output stand in for the frozen contract — silently
/// disarming the regression lock. This fails loudly if any frozen vector this
/// package's tests assert against is missing, so a fresh checkout / deletion is
/// a HARD failure, not a quiet regenerate.
@Suite("Frozen vector integrity (TEST-PLAN §2)", .tags(.envelope, .security))
struct FrozenVectorIntegrityTests {
    /// Every frozen vector loaded by PQRCNostr's tests (`Vectors.loadOrGenerate(...)`).
    static let required = [
        "giftwrap.json"  // EnvelopeTests
    ]

    @Test func frozenVectors_arePresent() {
        // A vacuous guard would pass on an empty list; assert there is work to do.
        #expect(!Self.required.isEmpty)
        for name in Self.required {
            let url = Vectors.directory.appendingPathComponent(name)
            let comment: Comment =
                "Frozen vector \(name) is missing at \(url.path) — restore it from version control; never let loadOrGenerate regenerate the regression-lock contract."
            #expect(FileManager.default.fileExists(atPath: url.path), comment)
        }
    }
}

func hexData(_ hex: String) -> Data {
    Data(hexString: hex) ?? Data()
}

/// A complete local persona: identity, nostr key, prekeys, messenger.
struct Persona {
    let name: String
    let identity: PQRCIdentity
    let nostrKeypair: NostrKeypair
    let prekeyManager: PrekeyManager
    let identityDH: Curve25519.KeyAgreement.PrivateKey
    let messenger: PQRCMessenger
    let clock: FixedClock

    var identityHex: String { identity.publicKeyData.hexString }

    static func make(
        name: String, seedByte: String, seed: UInt64,
        transports: [any RelayTransport], clock: FixedClock = FixedClock()
    ) async throws -> Persona {
        let identity = try PQRCIdentity(seed: hexData(String(repeating: seedByte, count: 32)))
        let random = SeededRandomSource(seed: seed)
        let nostrKeypair = try NostrKeypair(randomSource: random)
        let identityDH = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: random.bytes(32))
        let prekeyManager = try PrekeyManager(
            identity: identity, randomSource: random, oneTimeCount: 8)
        let messenger = try PQRCMessenger(
            identity: identity, nostrKeypair: nostrKeypair, prekeyManager: prekeyManager,
            identityDH: identityDH, transports: transports, clock: clock,
            randomSource: random, nonceSource: SeededRandomSource(seed: seed &+ 77),
            outboundRetryBaseMillis: 2)
        return Persona(
            name: name, identity: identity, nostrKeypair: nostrKeypair,
            prekeyManager: prekeyManager, identityDH: identityDH, messenger: messenger,
            clock: clock)
    }

    /// Verified contact view of another persona (as if fetched + verified).
    func asContact() throws -> VerifiedContact {
        let binding = try IdentityBinding.make(
            identity: identity, nostrPubkey: hexData(nostrKeypair.publicKeyHex))
        return VerifiedContact(binding: try BindingVerifier.verify(binding, outerSignatureValid: true))
    }
}

/// Collects raw relay events from a subscription stream.
actor NostrEventCollector {
    private var events: [NostrEvent] = []
    private var task: Task<Void, Never>?

    func attach(_ stream: AsyncThrowingStream<NostrEvent, Error>) {
        task = Task {
            do {
                for try await event in stream {
                    self.append(event)
                }
            } catch {}
        }
    }

    private func append(_ event: NostrEvent) {
        events.append(event)
    }

    func all() -> [NostrEvent] { events }
    func count() -> Int { events.count }

    /// Collects whatever arrives within the window, then cancels.
    func settle(millis: Int = 60) async -> [NostrEvent] {
        try? await Task.sleep(for: .milliseconds(millis))
        task?.cancel()
        return events
    }
}

/// Collects messenger events into an inspectable, awaitable buffer.
actor EventCollector {
    private var events: [MessengerEvent] = []
    private var task: Task<Void, Never>?

    func attach(_ stream: AsyncStream<MessengerEvent>) {
        task = Task {
            for await event in stream {
                self.append(event)
            }
        }
    }

    private func append(_ event: MessengerEvent) {
        events.append(event)
    }

    func all() -> [MessengerEvent] { events }

    func messages() -> [ReceivedMessage] {
        events.compactMap {
            if case .message(let message) = $0 { return message }
            return nil
        }
    }

    func violations() -> [String] {
        events.compactMap {
            if case .protocolViolation(_, let reason, _) = $0 { return reason }
            return nil
        }
    }

    /// Polls until `count` messages arrived or the timeout elapses.
    func waitForMessages(_ count: Int, timeoutMillis: Int = 10_000) async -> [ReceivedMessage] {
        var waited = 0
        while messages().count < count && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return messages()
    }

    func stop() {
        task?.cancel()
    }
}
