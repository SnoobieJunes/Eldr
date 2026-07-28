// SPDX-License-Identifier: Apache-2.0
import Foundation

// Shared by the PTY no-orphan proofs (PTYProcessTests / PTYTerminalACPTests).
#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// True while `pid` names a LIVE (running/sleeping) process — the thing the no-orphan
/// proofs assert on. `kill(pid, 0)` alone is not enough on Linux: in a container the
/// test runner is commonly pid 1 and never reaps children reparented to it, so a KILLED
/// child lingers as a signalable ZOMBIE and `kill(pid, 0)` keeps returning 0 forever. A
/// zombie is dead for every purpose the guarantee cares about (it executes nothing and
/// holds no fds), so on Linux additionally read /proc/<pid>/stat's state field — parsed
/// after the LAST ')' so a comm with spaces/parens can't shift it — and count
/// Z(ombie)/X(dead) as gone. On macOS there is no /proc and launchd reaps reparented
/// children promptly, so `kill` suffices.
func testProcessIsAlive(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    #if !canImport(Darwin)
    if let data = FileManager.default.contents(atPath: "/proc/\(pid)/stat") {
        let stat = String(decoding: data, as: UTF8.self)
        if let close = stat.lastIndex(of: ")") {
            let fields = stat[stat.index(after: close)...].split(separator: " ")
            if let state = fields.first, state == "Z" || state == "X" { return false }
        }
    }
    #endif
    return true
}
#endif  // os(macOS) || os(Linux)
