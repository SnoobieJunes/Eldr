# Eldr as a Buzz mobile client / relay — feasibility analysis + build plan

Status: **analysis 2026-07-24; WS-BM1 + WS-BM2 built and green the same day**
(`PQRCNostr`: `NIP98.swift`, `BuzzInvite.swift`, `BuzzWorkspace.swift`,
`BuzzWorkspaceClient.swift`; 34 tests in `BuzzWorkspaceClientTests`, full
8-package suite green — DEVIATIONS AC147–AC151). WS-BM3 onward is not started,
and nothing has been run against a live Buzz relay. Companion to
[`ELDR-BUZZ-INTEROP.md`](../guide/ELDR-BUZZ-INTEROP.md) (the *agent*-plane bridge, shipped
as AC144) and [`INTEROP-LANDSCAPE.md`](../done/2026-07-24/INTEROP-LANDSCAPE.md) (why a gateway, and
the "don't ask Buzz to change" rule). This doc answers a different question:
**can the Eldr iPhone app carry human messages into a Buzz workspace, and should
the product be repositioned around that?**

> **Truthful-reporting note (CLAUDE.md).** Claims are labelled *verified*
> (read in the source named, this session), *proven* (a test ran and passed —
> only AC144 items qualify), or *unverified* (design/inference). Nothing here
> was run against a live Buzz relay.

---

## 1. Verdict

**Technically: yes, and the lift is smaller than it looks.** Buzz is explicitly
designed to accept third-party clients, and Eldr already links the entire crypto
and transport stack needed to be one.

**Strategically: the framing in the goal needs one correction.** Buzz already
ships a mobile client. The value-add is *not* "be Buzz's phone app" — it is the
plane Buzz cannot ship on any client it has: **end-to-end (and post-quantum)
encrypted DMs inside a Buzz workspace, over Buzz's own relay, with zero changes
to Buzz.** That is the acquisition-shaped asset. §4 is the honest strategy read.

---

## 2. What makes it possible (verified)

### 2.1 Buzz invites third-party clients by design

`buzz/NOSTR.md:3` — *"Buzz is a Nostr relay that speaks NIP-29 (relay-based
groups) natively. Third-party Nostr clients connect directly to `buzz-relay`
using NIP-29 and NIP-42 authentication."* The doc is a compatibility contract:
a support matrix for kind:9 messages, reactions, deletions, profiles, group
creation/membership, discovery, presence, typing, NIP-50 search, NIP-10
threading, and NIP-17 gift wraps — plus the two clients they expect to work
(0xchat, Chachi). This is not a hole we squeeze through; it is a front door.

### 2.2 The onboarding gate is already open

`buzz-relay/src/api/invites.rs:289` — `POST /api/invites/claim`, NIP-98 signed by
the *joining* pubkey, **deliberately exempt from the relay-membership gate**
("the whole point is that the caller is not a member yet"). Body is
`{code, policy_receipt?}`; success inserts the membership row, publishes the
NIP-43 deltas, and returns `{status, community_id, host, role}`.

Buzz's own Flutter client uses exactly this path
(`mobile/lib/features/invites/invite_join_provider.dart:94-160`): generate keys →
NIP-98 header → POST claim → you are a member. **An Eldr user joins a Buzz
workspace by opening an invite link. No operator SQL, no allowlist row, no
negotiation with Block.** This is a materially easier on-ramp than the
NIP-OA/attestation dance `archive/2026-07-24/ELDR-BUZZ-PAIRING.md` was written around — that doc's
Options A and B are for *gateway/agent* keys; a human joining uses invites.

### 2.3 Eldr already links ~70% of the client

The iOS target links `PQRCCore`, `PQRCNostr`, `PQRCAgent`, `PQRCMCP`, `PQRCACP`
(`App/EldrChat.xcodeproj/project.pbxproj:10-18`). `PQRCNostr` already contains,
and AC144 already *proved byte-exact against Block's own vectors*:

| Need | Where it already is | Status |
|---|---|---|
| BIP-340 / NIP-01 canonical events | `NostrEvent.swift`, `NostrKeypair.swift` | proven (AC144) |
| NIP-42 AUTH client | `NostrWebSocketTransport.swift`, `NIONostrTransport.swift:26` | proven |
| NIP-44 v2 | `NIP44.swift` + `ChaCha20.swift` | proven byte-exact vs Buzz vectors |
| NIP-OA attestation | `NIPOA.swift` | proven vs `nip_oa.rs` |
| Buzz kinds 0/9/9000/10100/44200/24200 | `BuzzEvents.swift` | proven |
| WebSocket relay transport (Apple) | `NostrWebSocketTransport.swift:384` (URLSession) | in production use |
| Connect→AUTH→subscribe→post loop | `EldrBuzzGateway/BuzzGateway.swift` (537 lines total) | proven E2E |

The gateway that already talks to a Buzz relay is **537 lines**. It lives in
`EldrNode` (a daemon package) but every primitive it uses is in `PQRCNostr`,
which the phone already links.

### 2.4 The relay accepts Eldr's E2EE envelope

`NOSTR.md:71` — *"NIP-17 DMs (gift wrap) ✅ kind:1059 accepted with ephemeral
signing keys. Stored community-globally. Delivered via `#p`-filtered
subscriptions."* Confirmed against `required_scope_for_kind` in AC144's
source-grounded pass: kind:1059 → `MessagesWrite`, recipient-`#p`-gated read —
the same gate Eldr's own anchor relay enforces.

And Eldr's messenger already fans out across multiple transports
(`PQRCMessenger.swift:81,618-619` — `for transport in transports { publish }`),
so **adding a Buzz relay URL to the existing relay list is the entire transport
change** for carrying PQ-ratcheted traffic over Buzz infrastructure.

---

## 3. What is actually blocking (verified constraints, stated plainly)

These are real and each one shapes the plan. None is fatal; two are expensive.

### 3.1 Push notifications — the biggest product risk

A mobile chat client without background push is dead on arrival. Buzz's answer
is **NIP-PL Push Leases** (`docs/nips/NIP-PL.md`), and it is a genuinely good
spec — no event bytes transit Apple/Google, just a wake signal. But:

- the **executor** holds the *app's* APNs credentials, selected by
  `app_profile: "com.example.app/ios"` in the encrypted lease body;
- the spec states outright: *"this NIP defines no protocol by which an untrusted
  third party can act as an executor."*

So Eldr gets push only if (a) **Block provisions an Eldr app profile in their
push gateway** — a partnership dependency, and a legitimate conversation-opener
with them — or (b) **we run our own executor**. Option (b) is the sovereign one
and fits Eldr's thesis: the user's own `eldr-node`/Huginn already holds a
long-lived relay connection; it becomes the executor for that user's phone. It
needs an APNs pipeline Eldr does not have today (~1–2 weeks, plus an Apple push
key and a small always-on hop). **Plan for (b), ask for (a).**

### 3.2 Eldr's identity/prekey kinds are rejected by a Buzz relay

kinds 10420 (binding), 10421/10422 (prekeys), 10050 (DM relay list) are all
`restricted: unknown event kind` — verified in AC144. So Eldr↔Eldr key discovery
cannot ride a Buzz relay as-is. Two ways out:

1. **Keep an Eldr relay for identity, add the Buzz relay for transport.** Already
   the documented answer (`ELDR-BUZZ-INTEROP.md`), already supported (multi-relay
   lists). Costs one extra relay in setup.
2. **Bootstrap in-band using a kind Buzz already accepts** — *verified feasible*:
   kind:0 requires only `Scope::UsersWrite` (`ingest.rs:200`), and the **only**
   content validation is "must be valid JSON" (`ingest.rs:2234`). The
   side-effect handler reads only `display_name`/`name`/`picture`/`image`/
   `about`/`nip05` (`side_effects.rs:1113-1148`) and ignores everything else,
   while the raw event — content verbatim — is stored and served back on REQ
   (`buzz-db/src/event.rs:270`). **A PQRC prekey bundle carried as a custom
   field in kind:0 survives round-trip on a Buzz relay.**
   **Caveat that must be designed around:** kind:0 is absolute-state replaceable
   ("fields present are set; fields absent are cleared" — `side_effects.rs:1122`).
   If the same user edits their profile from Buzz Desktop/mobile, **our field is
   clobbered.** Mitigation: subscribe to our own kind:0 and re-publish the merged
   profile on clobber. Workable, slightly racy; ship (1) first, (2) as the
   zero-extra-relay upgrade.

### 3.3 Unlinkability cost on a Buzz relay

Buzz's read gate requires every `#p` in a REQ to equal the authenticated pubkey
(`NOSTR.md:141-144`). Eldr's rotating receiving sub-key (SPEC §9.3, kind 10422)
is an X25519 key that **cannot AUTH** — so on a Buzz relay the gift wrap `p` tag
must be the identity Nostr pubkey. Harmless mechanically — `GiftWrap.swift:82`
makes `recipientReceivingKey` optional and defaults to exactly that — but it is a
**real metadata regression** versus Eldr's own relay: the Buzz operator sees
which member pubkeys DM each other, and how often. Content stays sealed.
This belongs in `THREAT_MODEL.md` and `DEVIATIONS.md` before any of it ships.

### 3.4 Text-only collides with the Buzz client role

Buzz channels carry images and video (Blossom BUD-01/02, media sanitization, an
`image_picker` and `video_player` in their mobile deps). Eldr's invariant 4 is
**text-only, no blob store, permanently**. An Eldr "Buzz client" therefore
renders media as a link-out, never uploads, and is a *worse* general-purpose Buzz
client for that reason. This is a ceiling on Mode 1 (§5.1), not a bug — and it is
the strongest argument against "rebrand entirely into a Buzz client" (§4.3).

### 3.5 Smaller ones

- **Rich content**: Buzz's own clients render kind:40002/40003 (rich content /
  edits), flagged in `NOSTR.md:74-75` as "works on the wire but Buzz-only — no
  standard NIP-29 client renders these". We must at minimum *read* 40002 or
  Buzz-authored messages will look empty. Mobile sends kind:9 by default
  (`send_message_provider.dart:62` → `EventKind.streamMessage`), so writing
  kind:9 is correct and sufficient.
- **Size limits**: 512 KiB WS frame / 256 KiB event content / 87,472-byte NIP-44
  plaintext ceiling (`buzz-core/src/observer.rs:23`). Eldr's `RelayFraming`
  already chunks; the Buzz path must re-chunk or reject, never truncate.
- **Per-community addressing**: a destination is `(relay host, channel UUID)`,
  never the UUID alone — the same UUID legitimately exists in two communities
  (`archive/2026-07-24/ELDR-BUZZ-PAIRING.md §7`).
- **Inbound is untrusted**: every inbound Buzz message reaching an agent must go
  through `UntrustedDataEnvelope`. Non-negotiable; it is the whole point of NIP-AD
  (renamed from NIP-C1 on 2026-07-24 — see `../nips-contrib/README.md`).

---

## 4. Strategy — the correction, and the honest acquisition read

### 4.1 Buzz already has a mobile app

`buzz/mobile/` is a **Flutter client, 157 Dart files, 34,094 lines, version
0.4.11**, with channels (72 files), forum, pulse, activity, profile, invites,
pairing, search, settings; Android Play signing configured (`README.md`), and iOS
restricted to iPhone (`CHANGELOG.md`, PR #1735). It is real, shipping, and
maintained by a team.

Therefore **"we built you a mobile client, please acquire it" is not a pitch.**
It proposes replacing a working in-house product with an outside one in a
different language, on fewer platforms, that cannot show images.

### 4.2 What Buzz genuinely does not have

Verified across all 14 of their NIP drafts and their four clients
(desktop/mobile/CLI/SDK):

| Gap | Evidence |
|---|---|
| **E2EE DMs — in any client** | Their DMs are *server-side channels*: kinds 41010/41001/41011/41012 + a `hidden` 39000 (`buzz-core/src/kind.rs:371-377`). The relay *accepts* kind:1059, but no Buzz client sends or reads one — grep for gift-wrap across `desktop/src`, `mobile/lib`, `buzz-sdk`, `buzz-cli` returns only a test-bridge file. The workspace operator reads every DM. |
| **Post-quantum anything** | 0 mentions across 4.7k lines of NIP drafts. |
| **Forward secrecy** | Explicitly disclaimed twice (NIP-AE, NIP-AO). |
| **Untrusted-relay operation** | Their entire agent plane assumes a trusted, authoritative relay (NIP-AA/AO/IA/DV). |
| **Prompt-injection admission control** | NIP-AE §Security names memory poisoning and punts: *"admission control is the implementer's problem."* Eldr has the implementation. |

That list is Eldr's product. It is also, notably, the list of things a
security-conscious enterprise buyer asks Block about Buzz.

### 4.3 The recommendation

**Do not rebrand the app entirely.** Reasons, in order of weight:

1. A pure Buzz client is a *strictly worse* product than Buzz's own (no media, one
   platform family, outside their release train) and abandons the untrusted-relay
   thesis that makes Eldr defensible.
2. The thing worth acquiring is the **secure plane + the specs + the person who
   built them** — a tech-tuck/acquihire shape, not an app purchase. Blocking that
   asset inside a rebranded clone of their own client *reduces* its legibility.
3. Optionality: built as a **mode inside Eldr**, the Buzz surface is a superset.
   If Block engages, it is the demo. If they don't, you still shipped the feature
   that makes Eldr useful to anyone already living in a Buzz workspace.

**Do build the Buzz mode, and lead the conversation with the secure plane.** The
demo that lands is: *two Buzz members, in your workspace, on your relay, DMing
with post-quantum forward-secret encryption you cannot read — and the same phone
runs their agent. Zero changes to Buzz.* That is a capability claim with a
running artifact behind it, which is the only kind Block responds to (they
already ignored the "adopt PQRC" ask — `archive/2026-07-24/INTEROP-LANDSCAPE.md §8.2`).

The three contribution NIPs (`docs/nips-contrib/`, AC144) are the low-friction
relationship opener; this feature is the proof they are not theoretical.

---

## 5. The three modes (they are different products — pick deliberately)

"Relay messages from Eldr into Buzz" resolves to three distinct things.

### 5.1 Mode 1 — Workspace client ("post as me")

Eldr signs with your key and posts kind:9 into `#h` channels. You appear as an
ordinary Buzz member. Read channels, send, reply in threads, react.
*Highest UI cost, lowest novelty, capped by §3.4.* Necessary as the container
for Modes 2 and 3.

### 5.2 Mode 2 — Bridge ("the literal mobile relay")

An Eldr conversation is mirrored into a Buzz channel: what you say in Eldr shows
up in Buzz, and vice-versa. **This terminates E2EE at the phone** — exactly the
disclosure already written for the gateway (`ELDR-BUZZ-INTEROP.md §"E2EE
termination"`). Requires: the disclosure banner, the per-chat egress firewall as
the enforcement point, and `UntrustedDataEnvelope` on everything inbound.
*Cheap once Mode 1 exists; must never be on by default.*

### 5.3 Mode 3 — Secure plane ("the moat")

Two Eldr users who are both Buzz members exchange **PQ-ratcheted kind:1059 gift
wraps over the Buzz relay**. The workspace operator sees two members exchanging
sealed envelopes and nothing else. Buzz's own clients continue to work,
unmodified, unaware. **Zero Buzz changes.**

Transport is nearly free (§2.4). The work is discovery (§3.2) and the UX of
"this person is on Buzz *and* has Eldr → offer an encrypted DM."

**Build 1 + 3. Ship 2 behind an explicit gate.**

---

## 6. Build plan

Workstream prefix `WS-BM` (buzz mobile). Estimates are solo-developer days and
**Do not use `WS-M`** — that prefix is already taken by the Huginn MLX overhaul
(WS-M0…M5, DEVIATIONS AC113–AC121).
assume the AC144 codecs are reused, not rewritten.

### Phase 1 — Join and read (proves the front door) · ~1.5 weeks

> **PHASE 1 IS DONE** — WS-BM1, WS-BM2 and WS-BM3 all landed 2026-07-24, green
> (DEVIATIONS AC147–AC153). Beyond the sketch below: `RelayTransport.subscribeFrames`
> (the NIP-01 EOSE boundary, so a roster/history fetch is a bounded question
> rather than a guessed timeout), `NostrFilter.dTags`/`limit`, `BuzzProfile`'s
> merge-on-write (the prerequisite for WS-BM4's kind:0 bundle carrier), and a
> workspace surface that is deliberately *not* the conversation list.
>
> **Still unproven:** nothing has run against a live Buzz relay, and no screen
> has been looked at on a device. The milestone below ("scan an invite → read
> channels → send") is implemented and unit-tested, **not** demonstrated.
> WS-BM4 (the encrypted plane) is next.

**WS-BM1 · `BuzzWorkspaceClient` in `PQRCNostr`** *(3–4 d)* — **DONE**
Lift the connect→AUTH→subscribe→publish loop out of `EldrBuzzGateway/BuzzGateway.swift`
into a platform-neutral actor usable from iOS. Adds, beyond what AC144 shipped:
NIP-29 discovery parsing (39000/39001/39002), membership notifications
(44100/44101, `#p`-filtered per §3.5), kind:7 reactions, kind:5 deletions,
kind:40002 rich-content *read*, and explicit kind enumeration on every REQ (the
Buzz read gate rejects an omitted `kinds`).
*Test:* extend `BuzzInteropCryptoTests`; drive against `LocalRelaySimulator` +
the in-repo `pqrc-relay`, no network.

**WS-BM2 · NIP-98 + invite claim** *(1–2 d)* — **DONE**
`NIP98.swift` in `PQRCNostr` (kind 27235, base64 `Authorization: Nostr <event>`),
plus an `InviteClaimClient` for `POST /api/invites/claim`, the `/api/join-policy`
fetch, and `accept-policy`. Handle `buzz://` and `https://<host>/invite/<payload>.<mac>`
deep links. *This is the whole onboarding story.*

**WS-BM3 · Workspace surface in the app** *(4–5 d)* — **DONE** (AC152–AC153)
A `Workspaces` section in `MainView`'s `NavigationSplitView` sidebar — a peer of
conversations, not a replacement (preserve the adaptive-layout work per CLAUDE.md).
Channel list → channel view reusing `MessageBubble` / `MessageContent` /
the composer (respecting the `composer-refill-fix` epoch guard). Keys go in
`KeychainStore` per invariant 10 (`buzzws.<workspaceId>`), never UserDefaults.

**Milestone:** scan an invite on the phone, land in the workspace, read channels,
send a message that appears in Buzz Desktop.

### Phase 2 — The moat · ~1.5 weeks

**WS-BM4 · Secure plane over the Buzz relay** *(4–6 d)*
Register the Buzz relay as an additional `RelayTransport` for kind:1059 only.
Discovery via option (1) of §3.2 first (Eldr relay for identity), then the kind:0
bundle carrier (option 2) with clobber-detection re-publish. In-app affordance:
in the Buzz member list, members who advertise an Eldr bundle get an **"Encrypted
DM"** action that opens a normal PQRC conversation.
*Must land with it:* `THREAT_MODEL.md` entry for §3.3's metadata regression and a
`DEVIATIONS.md` AC.

**WS-BM5 · Agent control from the phone** *(3–4 d)*
The AC144 gateway already puts a local model in a Buzz channel; the phone becomes
its console — mention your agent from Eldr, see NIP-AM token/cost and NIP-AO
frames (both already decodable — `BuzzEvents.swift`), approve tool calls through
the existing `ACPPermissionCoordinator`. Reuses the C6 AI-context section rather
than adding chrome (`ui-ux-overload` directive).

**Milestone:** the demo in §4.3.

### Phase 3 — Make it a real mobile client · ~2 weeks

**WS-BM6 · Push** *(5–10 d, the risky one)* — NIP-PL lease minting on the phone +
an executor in `eldr-node` holding the APNs key. Ship §3.1 option (b); open the
conversation with Block for option (a).
**WS-BM7 · Bridge mode (Mode 2)** *(3–4 d)* — mirror + disclosure + egress firewall.
**WS-BM8 · Read state, presence, typing, search** *(3–4 d)* — NIP-RS kind:30078,
20001/20002, NIP-50.

### Cross-cutting (not optional)

- `UntrustedDataEnvelope` on every inbound Buzz byte that can reach an agent.
- The E2EE-termination disclosure wherever plaintext crosses the boundary.
- Full suite green per the `always-run-the-tests` directive: 8 packages + Huginn
  (with the team override) + EldrChat UI.
- `DEVIATIONS.md` AC per workstream; `THREAT_MODEL.md` before Phase 2 ships.

---

## 7. Verification status

### Proven live (2026-07-24, against `wss://auston.communities.buzz.xyz`)

Run with `BUZZ_LIVE_RELAY=… swift test --package-path Packages/PQRCNostr --filter
LiveBuzzWorkspaceProbe`:

- **The relay is Buzz 0.2.0** (`software: github.com/block/buzz`), advertising
  NIPs 1/2/10/11/16/17/23/25/29/33/38/42/50/56/43 plus `nip-er`/`nip-pl`, with
  `auth_required: true` and `restricted_writes: true`.
- **Eldr's NIP-98 credential is ACCEPTED by Block's own verifier.** A fresh
  throwaway key POSTing a deliberately-bogus code to `/api/invites/claim` came
  back `invite_invalid` — i.e. the signature cleared `verify_nip98_event` and
  execution reached the code check. Had the credential been malformed, the
  request would have died at authentication instead. **This is the single fact
  WS-BM2 rests on, and it is now measured rather than inferred.**
- **The live join policy decodes into `BuzzJoinPolicy`** — this workspace has
  `age_attestation_required: true`, so a claim here genuinely needs the
  accept-policy receipt round-trip (the path §6/WS-BM2 built).
- **§3.1's push finding is confirmed, not inferred:** the relay's NIP-11
  advertises exactly two push app profiles — `buzz-ios-production` and
  `buzz-ios-sandbox`. There is no Eldr profile and no way for us to add one, so
  background push needs either Block provisioning us or our own executor.
  Note `push_kinds` **includes 1059**: their executor already wakes clients for
  gift wraps, which is exactly what WS-BM4's encrypted plane would need.

### Still not verified

- **No invite has been claimed and no message sent.** The full loop
  (`live_joinAndRead`) is written and gated behind `BUZZ_LIVE_INVITE=<link>`;
  it needs an invite the owner generates from Buzz Desktop. Until it runs,
  "Eldr can join and post in a Buzz workspace" is implemented and unit-tested,
  **not demonstrated**.
- **No screen has been looked at**, on device or in the simulator.
- **The kind:0 bundle carrier (§3.2 option 2) is inference from three verified
  facts** (scope, JSON-only validation, verbatim storage), not an executed
  round-trip. Verify before building on it.
- **Buzz's push gateway was not inspected** beyond NIP-PL and the presence of
  `crates/buzz-push-gateway`; §3.1 option (a)'s real cost to Block is unknown.
- **Whether Block wants any of this** is unknown and unknowable from the repo.
