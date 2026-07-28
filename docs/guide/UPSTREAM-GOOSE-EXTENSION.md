<!-- SPDX-License-Identifier: Apache-2.0 -->
# Upstream prep — the goose extension (NOT yet published)

**Status: publication-READY draft, deliberately unpublished.** Publishing is an
owner action (WS-G7): it is outward-facing, and the naming rule below must hold.
Nothing in this file grants permission to post anywhere.

## Naming (decided, GOOSEWORLD §6)

- "**gooseworld**" is an INTERNAL codename until the goose/AAIF trademark posture is
  checked. It appears in no public copy.
- Public framing: **"Eldr — secure inter-town transport for Goosetown."**
- The extension's public name: **`eldr` extension for goose** (binary `eldr-gooseworld`
  may keep its name — it is an internal wire detail — but listings say "Eldr").

## The one-sentence pitch

> Your goosetown already coordinates on a wall; Eldr lets two towns share one — over a
> post-quantum, end-to-end-encrypted, human-authorized channel their owners can revoke
> at any moment.

(For Spiral/Block specifically: "the secure transport for your own agent ecosystem.")

## What the extension is (public copy, ready to paste)

The `eldr` extension gives a goose flock four MCP tools backed by a local Eldr node:

- `world_towns` — the paired towns and what each is authorized for (wall / delegate),
  straight from human-signed, day-bounded, revocable standing grants.
- `world_wall_post` — post to the shared wall. The NODE stamps the author; an agent
  cannot pick its own name, so cross-town impersonation is not a prompt away.
- `world_wall_read` — read what this reader hasn't seen. Remote content arrives
  QUARANTINED: nonce-delimited, line-quoted, control-escaped, headers rebuilt — a wall
  post cannot forge a marker, a header, or a priority flag, and injection payloads
  render as inert text.
- `world_delegate` — hand a task to a peer town's flock. Fails closed without a
  standing grant on the delegate plane; the wall grant never opens it.

The extension itself is a dumb byte pump to a token-gated loopback socket — it holds no
key, no wall state, and no policy. Everything that matters lives in the node: PQ-E2EE
(ML-KEM hybrid + Double Ratchet with PQ rekey), metadata-private gift-wrap on a plain
Nostr relay, and authorization that is a human's signature, not a config flag.

## Why goose folks might care (the honest differentiators)

1. **gtwall semantics, hardened**: monotonic cursors (no truncation replay), bounded
   retention with COUNTED gaps, structured author/priority fields that post text cannot
   forge.
2. **Injection containment as a first-class deliverable** — the four-layer envelope was
   adversarially audited; the audit's one real breakout (a label rendered outside the
   envelope) is fixed and regression-tested. This is the problem Buzz's NIP-AE names as
   unsolved.
3. **Authorization humans can see and kill**: owner-signed grants, per peer, per plane,
   day-bounded, revocable mid-stream — not an allowlist in a config file.
4. **Untrusted-relay posture**: towns coordinate over ANY Nostr relay without trusting
   it; the relay sees ephemeral-key ciphertext.

## Publication checklist (owner actions)

- [ ] Trademark check: goose / AAIF / "goosetown" usage rules; confirm "gooseworld"
      stays internal.
- [ ] Perform the live two-machine DEMO-GOOSEWORLD ritual once; update that doc's
      status line (publishing before the Phase-2 hardening is exercised on-device is
      the one unforgivable version — THREAT_MODEL §4a).
- [ ] Decide the repo boundary (the OSS extraction catalog lists the extension as an
      extract candidate — a single-purpose repo fits the many-small-repos strategy).
- [ ] Post to the goose community (extension registry / discussion), framed per the
      naming rule; link WHY-ELDR for the Buzz-relationship honesty.
- [ ] Spiral outreach with the one-sentence pitch (funding table already lists them).
