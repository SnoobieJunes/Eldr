# RELAY-DEPLOY-CROSTINI.md — deploying the PQRC anchor relay on Crostini/Linux

Runbook for standing up the PQRC anchor relay on a Debian (Crostini) host —
e.g. the Linux container on a Pixel Slate. This is the **production-shaped**
path (SPEC §9.1, §15, SETUP-GUIDE §7), not the macOS-only `pqrc-relay` dev tool.

## 0. Why not `pqrc-relay` here

`Packages/PQRCNostr/.../NostrRelayServer.swift` is gated behind
`#if canImport(Network)` (Apple's `Network.framework`), and `Package.swift`
declares only iOS/macOS platforms. It **cannot build or run on Linux**. On a
Crostini host the relay is **strfry** (or khatru); `pqrc-relay` stays on a Mac
for local two-simulator demos only.

## 1. The acceptance criterion (memorize this — it's the whole point)

From `ConformanceSuite.swift` / `TransportTests.swift`, a PQRC anchor relay MUST:

1. Serve **zero** kind-1059 events to an **unauthenticated** reader.
2. Serve a kind-1059 envelope **only** to the NIP-42-AUTHed connection whose
   pubkey **equals the envelope's `p` tag**.
3. Serve **nothing** to a reader AUTHed as the wrong key.

A vanilla public relay fails #1 — that failure is the point. Do not route PQRC
traffic through a relay until the gate (§5) passes.

## 2. Clone the repo (for the gate + reference, not as the webserver)

```bash
git clone https://github.com/SnoobieJunes/Eldr.git
```

strfry is the binary that serves traffic; this clone only provides the
conformance gate and config reference.

## 3. strfry config (writes + size)

In your `strfry.conf` (see the template shipped with your strfry build for the
exact key names — they vary by version):

- Bind loopback, fixed port (TLS is terminated by a reverse proxy, §4):
  `relay.bind = "127.0.0.1"`, `relay.port = 7777`.
- Max event size **≥ 1 MB** (SPEC §11.2): set the max-event/message-size key to
  at least `1048576`.
- Restrict accepted **write** kinds to the PQRC set — **1059, 10420, 10421,
  10050** — via a write-policy plugin: `relay.writePolicy.plugin = "<path>"`.
  The plugin reads one JSON event per line on stdin and emits an accept/reject
  decision; reject any `event.kind` outside that set.

## 4. The AUTH read-gate (the hard requirement)

strfry's plugin hook governs **writes**, not reads, so the anchor rule (§1) —
read-side gating of kind-1059 by NIP-42 AUTH + `p`-tag match — is **not**
something a stock strfry write-policy plugin can do. Options, in order of
reliability:

1. **khatru (Go)** — its `RejectFilter` callbacks receive the AUTHed pubkey, so
   you can reject any kind-1059 subscription whose `p` filter ≠ the authed key,
   and require AUTH before serving 1059 at all. Best fit for this requirement.
2. A strfry build/version with native NIP-42 read-auth, configured to require
   AUTH for kind-1059 and match `p` to the authed pubkey. Verify with §5 — do
   not assume.

Whichever path: the relay must send the AUTH challenge unprompted on connect
and withhold all kind-1059 traffic until the client answers with a signed
auth event whose pubkey matches the requested `p` tag.

## 5. Prove it before routing traffic (the gate)

```bash
PQRC_RELAY_URL=wss://<your-host> swift test \
  --package-path Packages/PQRCNostr \
  --filter swapPoint_deployedRelayConformance
```

This needs the Swift 6.2 toolchain. The package targets macOS/iOS, so the
reliable place to run the gate is a **Mac**; running it on Crostini is not
supported by the package's declared platforms. Run it from a Mac pointed at
your deployed `wss://` URL. **Do not point clients at the relay until it
passes.**

## 6. TLS + keep-it-running (persistence)

- Terminate TLS with nginx or Caddy in front of `127.0.0.1:7777`, exposing
  `wss://<your-host>`. (Debug/LAN builds tolerate `ws://`; TestFlight/Release
  require `wss://`.)
- Run strfry under **systemd** so it survives reboots and restarts on failure.
  strfry persists events to its LMDB `db` directory on disk (unlike
  `pqrc-relay`, which is in-memory only) — point `db` at a path on your
  256 GB volume.

## 7. Publish the operator policy

Decide and publish the IP-visibility / retention policy for this relay
(THREAT_MODEL §2.1, §2.7). Operating an anchor relay means you can see
connecting IPs and recipient `p` tags; be honest about retention.

## Checklist

- [ ] strfry installed and running under systemd, LMDB `db` on persistent disk
- [ ] max event size ≥ 1 MB; writes restricted to kinds 1059/10420/10421/10050
- [ ] NIP-42 AUTH challenge sent on connect; kind-1059 withheld until AUTH
- [ ] kind-1059 served only when authed pubkey == envelope `p` tag (§1)
- [ ] `swapPoint_deployedRelayConformance` passes against the `wss://` URL (§5)
- [ ] TLS (`wss://`) terminated by reverse proxy
- [ ] operator IP/retention policy published
