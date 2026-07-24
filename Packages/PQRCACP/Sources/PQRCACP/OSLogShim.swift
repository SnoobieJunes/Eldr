// SPDX-License-Identifier: Apache-2.0
#if !canImport(os)
import Foundation

// Non-Apple (Linux node) shim for the SUBSET of OSLog this module uses, so the
// production call sites compile UNCHANGED and keep invariant-12 semantics: a value
// marked `privacy: .public` is logged; everything else (the privacy-first default,
// `.private`) is redacted to `<private>` before it can reach a log sink. Lines go to
// stderr so systemd/journalctl captures them on a headless Linux node.
//
// Vendored (not shared from another package) on purpose: PQRCACP keeps its
// zero-external-package boundary on Apple platforms, so it cannot import a shared
// shim. This is intentionally minimal — extend the interpolation overloads only as
// real call sites require, and never widen the default away from `.private` (SPEC §0).
enum OSLogPrivacy { case `public`, `private` }

struct PQRCLogMessage: ExpressibleByStringInterpolation {
    let rendered: String
    init(stringLiteral value: String) { rendered = value }
    init(stringInterpolation: StringInterpolation) { rendered = stringInterpolation.text }
    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ literal: String) { text += literal }
        mutating func appendInterpolation<T>(
            _ value: @autoclosure () -> T, privacy: OSLogPrivacy = .private
        ) {
            text += (privacy == .public) ? "\(value())" : "<private>"
        }
    }
}

struct Logger {
    private let label: String
    init(subsystem: String, category: String) { label = "\(subsystem)/\(category)" }
    private func emit(_ level: String, _ m: PQRCLogMessage) {
        FileHandle.standardError.write(Data("[\(level)] \(label): \(m.rendered)\n".utf8))
    }
    func log(_ m: PQRCLogMessage) { emit("log", m) }
    func info(_ m: PQRCLogMessage) { emit("info", m) }
    func debug(_ m: PQRCLogMessage) { emit("debug", m) }
    func notice(_ m: PQRCLogMessage) { emit("notice", m) }
    func warning(_ m: PQRCLogMessage) { emit("warning", m) }
    func error(_ m: PQRCLogMessage) { emit("error", m) }
    func critical(_ m: PQRCLogMessage) { emit("critical", m) }
    func fault(_ m: PQRCLogMessage) { emit("fault", m) }
}
#endif
