// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

// WS-G5 — the node's standing-grant SOURCE (the verification side's missing half).
//
// The grant ENGINE (issue/receive/budget/revoke, AgentEngine) lives app-side with the
// human who signs; a headless node only needs to answer, per frame and per line, "does
// a live owner-signed grant cover this peer on this plane?". This store feeds that
// check from one owner-curated file under the node's data dir:
//
//     { "grants": [ <StandingGrant JSON>, ... ] }
//
// Every entry is re-verified on load — structural validity, bounded duration, the
// OWNER's signature (a grant signed by anyone else is dropped: a peer must never
// authorize itself onto this node) — and invalid entries are dropped LOUDLY on stderr,
// never silently honored. REVOCATION on a headless node = the owner removing the entry
// (or the whole file): the store re-reads on any mtime/size change and the authorizer
// consults it per frame, so removal bites on the very next frame. The signed
// `standing_grant_revocation` flow remains the phone/engine surface; this file IS
// owner-local state, so editing it carries the same authority as signing a revocation
// — with none of the key handling a daemon must not do.
public actor FileStandingGrantStore {
    public let path: String
    /// Canonical-lowercase owner hex — only grants signed by this identity load.
    public let ownerHex: String
    private let now: @Sendable () -> Int64

    private struct GrantFile: Codable {
        let grants: [StandingGrant]
    }

    /// Cache, invalidated by (mtime, size) — cheap enough to check per call while
    /// keeping per-frame file I/O off the hot path.
    private var cached: [StandingGrant] = []
    private var cachedStamp: (Date, UInt64)?

    public init(
        path: String, ownerHex: String,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.path = path
        self.ownerHex = ownerHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.now = now
    }

    /// The current live grant set: every file entry that is structurally valid,
    /// duration-bounded, owner-signed, and not yet expired. Missing file → empty
    /// (deny-all — the plane is simply off until the owner provisions grants).
    public func liveGrants() -> [StandingGrant] {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
            let mtime = attrs[.modificationDate] as? Date
        else {
            cached = []
            cachedStamp = nil
            return []
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if let stamp = cachedStamp, stamp == (mtime, size) {
            return cached.filter { $0.activeUntil > now() }
        }

        var loaded: [StandingGrant] = []
        var dropped = 0
        if let data = fm.contents(atPath: path),
            let file = try? JSONDecoder().decode(GrantFile.self, from: data)
        {
            let cutoff = now()
            for grant in file.grants {
                // The same checks the engine runs at receipt, because a store handed a
                // raw file cannot assume anyone else checked: structure, bounded
                // duration, owner signature. Expiry is re-applied per CALL above, so a
                // grant that lapses between file edits still stops admitting.
                guard (try? grant.validateStructure()) != nil,
                    grant.hasBoundedDuration(now: cutoff),
                    grant.enabledBy.hexString == ownerHex,
                    grant.hasValidSignature()
                else {
                    dropped += 1
                    continue
                }
                loaded.append(grant)
            }
        } else {
            dropped = -1  // unreadable/corrupt file — reported distinctly below
        }
        if dropped > 0 {
            FileHandle.standardError.write(Data(
                "eldr-node: town-grants: dropped \(dropped) invalid/foreign entr\(dropped == 1 ? "y" : "ies") from \(path)\n"
                    .utf8))
        } else if dropped < 0 {
            FileHandle.standardError.write(Data(
                "eldr-node: town-grants: \(path) is unreadable or not valid grant JSON — treating as EMPTY (deny-all)\n"
                    .utf8))
        }
        cached = loaded
        cachedStamp = (mtime, size)
        return cached.filter { $0.activeUntil > now() }
    }
}
