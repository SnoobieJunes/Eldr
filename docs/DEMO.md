# PQRC — Local Universe Demo

The Local Universe (APP-SPEC §15) is a complete PQRC deployment inside one
process: five seeded personas (Alice, Bob, Carol, Dave — and Eve, whom nobody
knows), an in-process AUTH-gated relay, and a Blossom blob store with a mirror.
No bytes leave the device.

## Running it

**From the app:** Settings → *Try the demo (Local Universe)* (Debug builds;
the reviewer-facing entry per TESTFLIGHT-GUIDE §F).

**From Xcode / CLI:** launch the `EldrChat` scheme (renamed from `PQRC`; the old
scheme is stale) with arguments:

```
--local-universe                # boot the universe, no script
--local-universe --demo-script  # boot + run the full scripted demo below
```

UI tests replay this script via `--uitest --demo-script`
(`App/PQRCUITests/PQRCUITests.swift`).

A segmented persona switcher appears at the top: you are whoever is selected,
with that persona's keys, store, and agent. Switch personas at any time to see
the other side of the conversation.

> The Local Universe predates the deniable-silo work (DEVIATIONS A23/A33): it
> boots a fixed test silo using the bare (empty-`siloID`) keys and bypasses the
> passphrase lock screen, so the demo and the existing test suite are unaffected
> by multi-account isolation. The silo lock screen is exercised separately by
> `SiloKeyTests` and the app account-gate tests, not by the demo script.

## The scripted demo (what `--demo-script` does, in order)

1. **Greeting exchange.** Alice fetches Bob's kind-10420 binding and kind-10421
   prekey bundle from the relay, verifies both directions, runs PQXDH and sends
   "Hey Bob! Trying out PQRC." with message #0 piggybacked on the handshake.
   Bob replies. *Verify:* both personas show the 1:1 conversation; as Bob, the
   first message arrived decrypted.

2. **AI-drafted message.** Alice's agent drafts a reply ("Sounds great — how
   about Tuesday at noon?") and it is sent **as Alice's AI**: agent-signed,
   `participant_type: "agent"`. *Verify:* the message renders as the distinct
   agent bubble — purple outline, sparkles badge, "⟡ Alice's AI" caption — on
   BOTH sides. There is no way to make it look human-authored.

3. **30-minute ai_window.** Alice enables always-on AI. The signed announcement
   broadcasts to the conversation. *Verify:* switch to Bob — the pinned glass
   banner "Alice's AI is active · NNm left" counts down. Only Alice's human
   identity key could have produced it.

4. **Shared AI thread.** Alice creates the thread "Plan lunch" and invites her
   AI (30 min); Bob invites his. The two agents converse autonomously **inside
   the thread only**: each contributes a "Context:" message (folder glyph) —
   Alice's calendar availability, Bob's conflict — then proposals, until the
   loop guard pauses them at 6 consecutive agent messages. *Verify:* open the
   thread chip "✳︎ Plan lunch"; the full agent exchange is recorded as ordinary
   signed thread messages (nothing happened off the record); the yellow "AIs
   paused — waiting for a human" row is visible; sending a human message
   resumes them.

5. **Large paste (≈218 KB).** Alice sends a paste far above the 64 KB inline
   limit. In the text-only product this takes the **relay-chunking** path
   (DEVIATIONS N26/A25): the message splits across several ratcheted gift-wrap
   envelopes (each a one-time key), sized to the relay's content limit, and is
   rejoined on receipt — no blob server. *Verify:* the composer collapsed it into
   a chip; each stored envelope is bucket-padded (the relay sees only a burst of
   N constant-size events, never the total size). (The `ptr`/Blossom pointer path
   exists in core but is reserved for binary attachments, out of scope for v1.)

5.5 **Message request.** Eve — whom Alice has never verified — initiates a
   handshake. *Verify:* as Alice, Eve appears under **Message Requests**, never
   as a conversation (D12).

6. **Group of 4.** Alice creates "Lunch crew" with Bob, Carol and Dave —
   pairwise fan-out: the same padded plaintext encrypted once per member
   session. *Verify:* switch to Carol or Dave; the group and its greeting are
   there. Every pairwise link keeps full FS/PCS/PQ properties.

## What to look at while it runs

- **Relay surface:** every message on the wire is an opaque kind-1059 event
  with a random pubkey, a fuzzed past timestamp, and the recipient tag —
  nothing else (Settings → Relays describes this honestly).
- **AUTH gating:** the relay serves envelopes only to the authenticated
  recipient — the conformance suite (`swapPoint_transportConformanceSuite`)
  is the acceptance gate for the future real-network transport.
- **Rekeys:** keep a conversation going past 50 messages and the ML-KEM rekey
  rides along invisibly (header `pq` field; chaos suite exercises this under
  drops, duplicates, reordering and jitter).
- **Per-party color (display-only):** in a group, each human gets a deterministic
  solid color derived from their identity hex, and their tethered AI a lighter
  tint of the same hue, so you can tell parties apart at a glance. It is **purely
  local** — computed on-device, never stored, never on the wire — and color is
  never the only AI signal (the outline + sparkles badge still mark every agent
  bubble for colorblind/grayscale users). It does not affect codename redaction.

## Performance notes

Budgets (APP-SPEC §12) are wired in `PQRCTests/PerformancePipelineTests` and
`PQRCUITests/PerformanceUITests` with XCTest metrics; CI treats them
baseline-relative. Simulator reference numbers from this machine (Apple
silicon, iPhone 17 Pro simulator): 1 KB pad+encrypt+wrap ≈ 5.5 ms (budget
10 ms); 64 KB inline encrypt ≈ 0.13 ms; 1 MB blob path ≈ well under 250 ms;
500-envelope drain ≈ 4.4 s against a 3 s budget on hardware — simulator
numbers are soft (TEST-PLAN §11); record device numbers here when hardware
runs happen.
