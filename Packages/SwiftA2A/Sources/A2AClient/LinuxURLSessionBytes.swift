// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking

// Linux shim (DEVIATIONS AC172): swift-corelibs-foundation's URLSession has no
// `bytes(for:)`. Fall back to the buffered `data(for:)` and replay it as a byte
// sequence, so the SSE path compiles unchanged. Semantics are identical except that
// events arrive when the response completes instead of incrementally.
struct BufferedBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    let data: Data
    struct AsyncIterator: AsyncIteratorProtocol {
        var index: Data.Index
        let data: Data
        mutating func next() async throws -> UInt8? {
            guard index < data.endIndex else { return nil }
            defer { index = data.index(after: index) }
            return data[index]
        }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(index: data.startIndex, data: data) }
}

extension URLSession {
    func bytes(for request: URLRequest) async throws -> (BufferedBytes, URLResponse) {
        let (data, response) = try await data(for: request)
        return (BufferedBytes(data: data), response)
    }
}
typealias StreamBytes = BufferedBytes
#else
typealias StreamBytes = URLSession.AsyncBytes
#endif
