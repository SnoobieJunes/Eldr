# Licensing

Copyright (C) 2026 Eldr contributors.

This repository is deliberately split-licensed:

| Path | License | SPDX | Why |
|---|---|---|---|
| `Packages/` — all eight SPM packages (PQRCCore, PQRCNostr, PQRCAgent, PQRCACP, PQRCMCP, EldrNode, Eldrctl, SwiftA2A) | Apache License 2.0 — each package carries its own `LICENSE` | `Apache-2.0` | The protocol stack is meant to be embedded anywhere, including closed-source products. Apache 2.0 adds an express patent grant and matches the Swift ecosystem (swift-crypto is Apache 2.0). |
| Everything else — `App/` (EldrChat), `Apps/Huginn/`, docs, test vectors, tooling | GNU Affero General Public License v3 only — root [`LICENSE`](LICENSE) | `AGPL-3.0-only` | The apps stay copyleft: anyone shipping or network-deploying a fork must publish their complete source under the AGPL. |

Two riders:

- **App store exception.** Apple's App Store terms conflict with the AGPL's
  freedoms, so the copyright holders grant an additional permission under
  AGPL §7 — see [`LICENSE-EXCEPTIONS.md`](LICENSE-EXCEPTIONS.md). The source
  obligation is unchanged: complete corresponding source stays available under
  the AGPL here.
- **Contribution terms** (details in `CONTRIBUTING.md`):
  - `Packages/` — DCO sign-off (`git commit -s`); inbound = outbound Apache-2.0.
  - `App/` and `Apps/` — contributions additionally require a Contributor
    License Agreement, preserving the maintainers' ability to offer
    commercially licensed app builds.

Every Swift source file carries a one-line `SPDX-License-Identifier` header
stating which side of the split it is on. The eight `Package.swift` manifests
are the exception (the `swift-tools-version` declaration must stay on line 1);
they are covered by their package's `LICENSE` file.

Third-party dependencies: [swift-crypto](https://github.com/apple/swift-crypto)
(Apache-2.0) and [swift-secp256k1](https://github.com/21-DOT-DEV/swift-secp256k1)
(MIT). Both are compatible with both sides of the split.
