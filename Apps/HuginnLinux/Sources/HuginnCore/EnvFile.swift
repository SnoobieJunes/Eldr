// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The `env` file format both bash (`source env`) and Huginn read: one
/// `export KEY='value'` per line. Values are single-quoted for the shell (a `'` inside
/// becomes `'\''`), so nothing in a value is ever expanded or executed when the launcher
/// sources it. The parser accepts what a person hand-editing the file writes too:
/// `KEY=value`, `export KEY=value`, double quotes, comments and blank lines.
public enum EnvFile {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func render(_ pairs: [(String, String)], header: String) -> String {
        var out = header.split(separator: "\n").map { "# \($0)" }.joined(separator: "\n")
        out += "\n"
        for (k, v) in pairs { out += "export \(k)=\(quote(v))\n" }
        return out
    }

    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            out[key] = unquote(String(line[line.index(after: eq)...]))
        }
        return out
    }

    /// Inverse of `quote` for the shapes the file actually holds: concatenated
    /// single-quoted segments joined by `\'`, a double-quoted value, or a bare word.
    static func unquote(_ s: String) -> String {
        let chars = Array(s.trimmingCharacters(in: .whitespaces))
        if chars.count >= 2, chars.first == "\"", chars.last == "\"" {
            return String(chars[1..<(chars.count - 1)])
        }
        guard chars.first == "'" else { return String(chars) }
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "'" {
                i += 1
                while i < chars.count, chars[i] != "'" { out.append(chars[i]); i += 1 }
                i += 1
            } else if chars[i] == "\\", i + 1 < chars.count {
                out.append(chars[i + 1]); i += 2
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    public static func read(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        return parse(text)
    }
}
