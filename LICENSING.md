# Licensing

Copyright (C) 2026 Eldr contributors.

This repository is deliberately split-licensed:

The rule in one line: **anything another implementation needs in order to
interoperate is public domain; the reference code is permissive; the shipped
apps are copyleft.**

| Path | License | SPDX | Why |
|---|---|---|---|
| **The protocol** — [`docs/pqrc-SPEC-v1_1.md`](docs/pqrc-SPEC-v1_1.md), [`docs/NIP-XX-pqrc.md`](docs/NIP-XX-pqrc.md), [`docs/A2A-PQRC-EXTENSION.md`](docs/A2A-PQRC-EXTENSION.md), any future PQRC extension profile, and [`TestVectors/`](TestVectors/) | CC0 1.0 Universal (public domain) — [`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt) | `CC0-1.0` | A spec nobody may implement is not a spec. `nostr-protocol/nips` requires public domain ("all NIPs are public domain"), the A2A extension is intended for submission to the a2aproject community, and interop vectors are useless unless *rival* implementations can check themselves against them. No copyleft, no attribution burden, no patent ambiguity. |
| `Packages/` — all eight SPM packages (PQRCCore, PQRCNostr, PQRCAgent, PQRCACP, PQRCMCP, EldrNode, Eldrctl, SwiftA2A) | Apache License 2.0 — each package carries its own `LICENSE` | `Apache-2.0` | The reference stack is meant to be embedded anywhere, including closed-source products. Apache 2.0 adds an express patent grant and matches the Swift ecosystem (swift-crypto is Apache 2.0). |
| Everything else — `App/` (EldrChat), `Apps/Huginn/`, the remaining docs, tooling | GNU Affero General Public License v3 only — root [`LICENSE`](LICENSE) | `AGPL-3.0-only` | The apps stay copyleft: anyone shipping or network-deploying a fork must publish their complete source under the AGPL. |

**Why this direction is legal.** Apache-2.0 is one-way compatible with AGPL-3.0:
Apache code may be combined into an AGPL work, never the reverse. Every
dependency arrow in this repo points that way — the packages depend only on each
other and on permissive third parties, the apps import the packages, and nothing
in `Packages/` imports app code. Combining does not relicense the packages:
`PQRCCore` remains Apache-2.0 even though EldrChat links it under the AGPL.

**What the AGPL does and does not do.** It does *not* prohibit anyone from
forking, rebranding, or redistributing the apps — it requires that they publish
complete corresponding source under the AGPL when they do, including for network
use (§13). The names **Eldr**, **EldrChat**, and **Huginn**, and the project's
logos, are *not* licensed by either grant — see [`TRADEMARKS.md`](TRADEMARKS.md).

Two riders:

- **App store exception.** Apple's App Store terms conflict with the AGPL's
  freedoms, so the copyright holders grant an additional permission under
  AGPL §7 — see [`LICENSE-EXCEPTIONS.md`](LICENSE-EXCEPTIONS.md). The source
  obligation is unchanged: complete corresponding source stays available under
  the AGPL here.
- **Contribution terms** (details in `CONTRIBUTING.md`):
  - The CC0 protocol documents and `TestVectors/` — DCO sign-off; contributions
    are dedicated to the public domain along with the rest of the document.
  - `Packages/` — DCO sign-off (`git commit -s`); inbound = outbound Apache-2.0.
  - `App/` and `Apps/` — contributions additionally require a Contributor
    License Agreement, preserving the maintainers' ability to offer
    commercially licensed app builds.

Every Swift source file carries a one-line `SPDX-License-Identifier` header
stating which side of the split it is on, as do the CC0 protocol documents
(`<!-- SPDX-License-Identifier: CC0-1.0 -->`). The eight `Package.swift`
manifests are the exception (the `swift-tools-version` declaration must stay on
line 1); they are covered by their package's `LICENSE` file. `TestVectors/` is
covered by [`TestVectors/LICENSE`](TestVectors/LICENSE) rather than per-file
headers, because the vectors are frozen byte-for-byte and JSON has no comment
syntax.

Third-party dependencies: [swift-crypto](https://github.com/apple/swift-crypto)
(Apache-2.0), its transitive [swift-asn1](https://github.com/apple/swift-asn1)
(Apache-2.0), and [swift-secp256k1](https://github.com/21-DOT-DEV/swift-secp256k1)
(MIT). All are compatible with every side of the split.
