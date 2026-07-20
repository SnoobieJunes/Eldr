# Changelog

All notable changes to this project are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning:
[SemVer](https://semver.org/spec/v2.0.0.html) (pre-1.0, minor versions may
break anything).

## [0.1.0] — unreleased

Initial public release.

### Added

- **PQRC protocol v1** ([docs/pqrc-SPEC-v1_1.md](docs/pqrc-SPEC-v1_1.md)):
  hybrid X25519 + ML-KEM-768 handshake (PQXDH pattern), Double Ratchet with
  per-message key deletion, post-quantum rekey every 50 messages, bucket
  padding, gift-wrapped envelopes with past-fuzzed timestamps, relay chunking
  for >64 KB text (no blob storage, ever), Nostr wire format
  ([docs/NIP-XX-pqrc.md](docs/NIP-XX-pqrc.md)).
- **EldrChat** (iOS / iPadOS / Mac Catalyst): 1:1 and small-group messaging
  over Nostr relays, full-screen markdown reader, multi-account silos behind
  passphrase/biometrics, nearby (offline) mode with relay fallback, the
  five-persona "Local Universe" demo world.
- **AI, consent-boxed:** per-persona providers (on-device Apple model, tethered
  self-hosted, or cloud behind a per-chat egress firewall with codenames);
  signed, time-boxed `ai_window`; protocol-enforced AI authorship labels;
  shared AI threads; MCP context server (codenames only).
- **Huginn** (macOS companion): phone-paired tethered AI with
  Secure-Enclave-encrypted memory (unpair = key shredded), MLX workshop
  (serve / download / fine-tune), and the `eldr-acp` coding-agent conduit
  (permission-gated, path-jailed, driven from the phone).
- **SwiftA2A**: A2A v1.0 types, JSON-RPC client/server, and the draft
  "A2A over PQRC" E2EE transport extension
  ([docs/A2A-PQRC-EXTENSION.md](docs/A2A-PQRC-EXTENSION.md)).
- **Test suite as a deliverable:** ~900 tests across eight packages and two
  apps — frozen byte-for-byte crypto vectors, a networked chaos matrix,
  security-regression suites, an accessibility audit — plus CI (package
  matrix, iOS + Catalyst build gate, app tests, non-blocking perf).
- **Split licensing:** Apache-2.0 for all eight packages, AGPL-3.0-only for the
  apps with an App Store exception ([LICENSING.md](LICENSING.md)).
