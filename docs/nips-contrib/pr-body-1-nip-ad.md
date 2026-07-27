## What this adds

One new draft: `docs/nips/NIP-AD.md` — **Untrusted Data Admission for Agent
Contexts**. It specifies how a harness frames attacker-influenceable text before
handing it to a model, so remote content can be read and reasoned over without
being executed as instructions.

No new event kind. No relay support required. No key material. It is a rendering
convention and a set of verification rules — deliberately the cheapest possible
answer to the problem.

## The problem it addresses

NIP-AE §Security considerations names this and leaves it open:

> **Memory poisoning.** Encryption protects confidentiality, not the
> truthfulness of what the agent decides to remember. Admission control is the
> implementer's problem.

and:

> **No owner write authority.** [...] This NIP defines no protocol-level
> mechanism by which an owner directs the agent's memory; that interaction is out
> of band.

That's a reasonable scoping decision for NIP-AE. But it means every implementer
independently invents an answer to "how do I put this text in front of a model
without it being read as a command?" — and most of the obvious answers are
wrong in the same few ways. The moment two independently operated agents
exchange text, both sides are consuming bytes an attacker influenced.

This draft proposes one shared answer, so the agent plane isn't relying on each
harness getting Unicode line-break handling right by itself.

## What it specifies

Four rules, each closing a specific, demonstrated bypass:

1. **Per-read 128-bit nonce markers**, minted locally *after* the content
   arrives and never transmitted with it — so a hostile author cannot forge a
   closing marker.
2. **Quoting applied after splitting on every Unicode line break** — LF, CR,
   CRLF, VT, FF, NEL, U+2028, U+2029. Splitting on `\n` alone is the common bug:
   `line\u{2028}=== END … ===` forges a terminator in every renderer that treats
   U+2028 as a break. Marker lines never start with the quote prefix, so content
   cannot occupy a structural line even if the nonce leaks.
3. **C0/C1, DEL, and FS/GS/RS escaped, not passed through** — so `\e[2J\e[H`
   renders as inert text instead of clearing a human operator's screen and
   redrawing a forged envelope.
4. **Bidi controls escaped and line breaks collapsed in single-line metadata
   fields** rendered outside the quoted block (Trojan Source / CVE-2021-42574,
   and forged roster rows).

In addition: refuse oversize content rather than truncate (truncation can strip a
closing marker), and compute structural header fields from typed values rather
than from content text.

## Test vectors

Seven, in the spec, generated from a shipping implementation rather than written
by hand — including the U+2028 marker forgery, the ANSI/CR case, a Trojan-Source
bidi override, and a complete rendered envelope with a pinned nonce. The
adversarial cases show the attack *contained*, not just the happy path.

## Disclosure

I build [Eldr](https://github.com/SnoobieJunes/Eldr), a privacy-first personal
messenger on the same Nostr substrate. It's a different shape from Buzz — solo /
untrusted-relay, post-quantum ratcheted, E2EE — and I'm not proposing anything
that would pull Buzz toward it. This draft is a spec Eldr already runs, offered
for the shared agent plane because NIP-AE names the gap and I had a
tested answer already implemented. The reference implementation is Eldr's
`UntrustedDataEnvelope`; the vectors above are its literal output.

Eldr also speaks Buzz's existing agent-plane crypto byte-exact against your own
vectors (NIP-44 v2, NIP-OA, NIP-AM, NIP-AO — all green in Eldr's suite,
including "NIP-OA verifies the spec-provided signature"). Mutual conformance is
the point; this is a contribution, not a fork.

## Licensing

Eldr's protocol documents are CC0 1.0 (public domain) by deliberate choice, so
contributing this under Apache-2.0 is unencumbered. I'm the sole copyright
holder, there's no employer with a claim, and per CONTRIBUTING I'm submitting it
under the Apache-2.0 license with the right to do so.

## Notes for review

- **Naming.** I used `NIP-AD` to fit the existing `A*` agent-plane family
  (`AA`/`AE`/`AM`/`AO`/`AP`) and because it's unclaimed in `docs/nips/`. Rename
  it as you see fit — the file says so.
- **CI.** This is documentation-only; `just ci` covers Rust fmt/clippy/tests and
  mobile, none of which this touches. I haven't run it locally (it requires
  Docker, Postgres, Redis, Flutter, and a Rust toolchain, and this change is
  markdown-only). I can run it if you'd like.
- **Cross-links.** This draft links only to `NIP-AE.md`, `NIP-AM.md`,
  `NIP-AO.md`, `NIP-AP.md` and `NIP-OA.md`, all already in the tree. Nothing here
  depends on a companion PR.
- **I'm happy to move this to a Discussion or issue** if you'd rather talk about the
  approach before a file lands in the tree. I opened it as a PR because the
  draft is complete and concrete, not to skip the conversation.
