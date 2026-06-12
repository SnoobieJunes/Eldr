import Foundation
import Testing

@testable import PQRCCore

/// Frozen test vector plumbing (TEST-PLAN §2). Vectors are generated once
/// (when the file is absent), committed, and asserted forever after.
enum Vectors {
    static var directory: URL {
        // Packages/PQRCCore/Tests/PQRCCoreTests/VectorSupport.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // -> PQRCCoreTests/
            .deletingLastPathComponent()  // -> Tests/
            .deletingLastPathComponent()  // -> PQRCCore/
            .deletingLastPathComponent()  // -> Packages/
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("TestVectors")
    }

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    /// Loads a frozen vector, generating + freezing it first if absent.
    /// Generation happens at most once per checkout; afterwards the committed
    /// bytes are the contract.
    static func loadOrGenerateAsync<V: Codable>(
        _ name: String, generate: () async throws -> V
    ) async throws -> V {
        let fileURL = url(name)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let value = try await generate()
            try freeze(value, to: fileURL)
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(V.self, from: data)
    }

    static func loadOrGenerate<V: Codable>(_ name: String, generate: () throws -> V) throws -> V {
        let fileURL = url(name)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let value = try generate()
            try freeze(value, to: fileURL)
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(V.self, from: data)
    }

    private static func freeze<V: Encodable>(_ value: V, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}

extension Data {
    var hex: String { hexString }
}

func hexData(_ hex: String) -> Data {
    Data(hexString: hex) ?? Data()
}
