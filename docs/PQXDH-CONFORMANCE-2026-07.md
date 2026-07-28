# PQXDH conformance and identity binding — July 2026

Three fixes to the handshake, found while preparing `swift-pqxdh` (the
standalone extraction of `PQRCCore/Handshake`) for public release. The
extraction copied `PQXDH.swift` faithfully, so everything below originated
here, not in the split.

The wire format and the derived `SK` both change. `PQRCConstants.handshakeSuite`
is bumped `hybrid-v1` → `hybrid-v2` so a peer on an old build gets a legible
`handshakeSuiteUnsupported` instead of a handshake that "succeeds" and then
silently fails to decrypt anything. **All peers must update together.** No
migration path is provided and none is intended: there is no deployed
population to migrate.

---

## 1. The missing fourth DH leg (correctness)

`PQXDH.swift` computed three Diffie-Hellman legs:

```
DH(ik_dh_A, spk_B)      DH(ek_A, spk_B)      DH(ek_A, otp_B)
```

Those are the specification's DH1, **DH3** and **DH4**. Spec DH2 =
`DH(EK_A, IK_B)` was absent — and it is the only leg that requires the
*responder's* identity private key. The signature made that visible:
`respond(myIdentityPub: Data, …)` took only the public half and never touched a
responder secret, and `ConsumedPrekeys` did not carry `ikDH` at all.

**Consequence.** Everything on the responder's side hung off the medium-lived
`spk`, which inverts the reason for separating a long-term identity key from
rotating prekeys: whoever obtained that one private half could impersonate the
responder to every initiator working from their published bundle, without ever
touching the identity key. In practice the two sit in the same `PrekeyState`
blob in the same encrypted store, so the defence-in-depth loss is smaller than
it sounds.

**The larger cost was the claim.** `PQXDH.swift` cited "PQXDH (SPEC §4.2)" and
NIP-XX §5 documented it as PQXDH. With three legs it was not the protocol
Bhargavan et al. formally verified (USENIX Security '24) nor the one Fiedler &
Günther analysed (ePrint 2024/702), so none of that analysis transferred.

**Fixed.** All four legs are computed in spec order; `ConsumedPrekeys` carries
`ikDH`. Pinned by `sharedSecret_dependsOnResponderIdentityKey`, which holds one
message and one set of prekeys fixed and moves only `ik_dh`.

## 2. The `ik` → `ik_dh` binding (security)

`respond` read `message.ik` straight into the KDF `info` and `message.ik_dh`
straight into `dh1`, with nothing tying the two together. The handshake carried
no signature, so `ik` was effectively a free-text name field.

**The attack**, entirely from public information: run an ordinary handshake
against the target's published bundle with your own keys; rewrite the single
`ik` field to name someone else; recompute `SK` — every input is yours, so this
is arithmetic, not cryptanalysis — and send it. Every DH leg verifies, because
the `ik_dh` really is a key you hold. The responder derives a secret you know in
full and attributes the session to the named victim.

**Why it was not exploitable in this app.** `GiftWrap.unseal` verifies
`hasValidID()` and the seal's BIP-340 signature, so the whole rumor is
authenticated under the sender's Nostr key; `processUnwrapped` resolves the
contact by that key; and `processHandshake` already required
`handshake.ik == contact.binding.identityPubkey`. An attacker must therefore
sign with their own Nostr key, which resolves to their own contact record, which
forces `ik` to be their own. The attack died at the transport.

Two things were wrong with relying on that. First, the mechanism was not what
the extraction notes claimed: `IdentityBinding` binds nostr ↔ identity ↔ agent
keys and **never mentions `ik_dh`**. What actually saved us was the seal
signature plus that one equality check. Second, `PQXDH.respond` was unsafe
standalone, its safety enforced two layers away in a different package — so the
next unwrap path written would have inherited the full vulnerability silently.
That is exactly what happened to the extraction.

**Fixed.** `HandshakeMessage` carries `ik_dh_sig`, the initiator's signature
over its own `ik_dh` in the same `pqrc-prekey-v1` domain the prekey bundle uses.
`respond` refuses `initiatorIdentityUnverified` unless it verifies against the
claimed `ik`, and returns `initiatorIdentityPub` — an identity it has *proven*
owns the agreement key. `PQRCMessenger.processHandshake` now agrees that value
against the contact's binding as well, as defence in depth.

**Residual, and it is the same one X3DH has.** An attacker can replay a genuine,
public `(ik, ik_dh, ik_dh_sig)` triple with their own ephemeral and ciphertext.
The responder accepts and attributes a session — but cannot be matched, because
the attacker cannot compute `dh1` without the victim's private key, so the
session is dead on arrival and nothing they send decrypts. Authentication here
is *implicit*: it is confirmed at first successful decryption, not at `respond`.

Not fixed by signing the whole handshake, deliberately. Signing `ek` and
`kem_ct` would close the dead-session nuisance at the cost of a transferable,
non-repudiable proof that a given person started a conversation. X3DH and PQXDH
both decline that trade; so do we.

## 3. Prekey pool integrity (availability, and a live bug)

**Drain.** `consume` removed the `otp_used` private half and marked it consumed,
and only *then* looked up `otp_pq_used`. A message pairing a real published
one-time prekey with a garbage PQ reference therefore threw, returned nothing,
and still burned the prekey — free for the sender, permanent for us. Reachable
by any known contact with no established session. `consume` now resolves
everything before mutating anything, and the new `consume(_:)` overload
validates the message first, so the ordering cannot be got wrong by a caller who
never thought about it. `PQRCMessenger` uses that overload.

**Collision (user-visible).** `initiate` took `bundle.otp.first`. A kind-10421
bundle publishes the whole pool, so any two people who fetched it before either
handshake landed picked the *same* prekey; the second `consume` threw, the
`catch` yielded `quarantined("handshake failed")`, and that person's message
silently never arrived with no error shown to either side. Selection is now a
random draw from the injected `RandomSource`.

**Contradictory claims.** `lrp_used: true` alongside a non-nil `otp_used` was
silently resolved to last-resort. `dh4` has exactly one source; both now yield
`handshakeMalformed`.

---

## Test vectors

`TestVectors/pqxdh_handshake.json` is regenerated: new suite string, new `SK`
for all three cases, `ikDHSig` added to the frozen wire. That file is *supposed*
to break on a protocol change — that is what freezing is for.

The other six vectors (`agent_derivation`, `binding_10420`, `giftwrap`,
`padding`, `pq_rekey`, `ratchet_chain`) are byte-identical, verified by
checksum. That is the evidence the blast radius is the handshake and nothing
else.

## Verification

- `PQRCCore`: 104 tests in 16 suites, green. Eight new adversarial tests cover
  rewritten identity, tampered binding signature, the dh2 dependency,
  validate-before-consume, the drain, contradictory claims, and selection spread.
- `PQRCNostr`: 179 tests in 32 suites, green.

`StandingGrantWireTests.swift:280` also needed a one-line fix — an
`#expect` comparing `[Int64]` against an untyped integer literal mapped through
arithmetic exceeded the type-checker's budget. This was **pre-existing**,
confirmed by building the test target at unmodified `HEAD` in a clean worktree;
the whole `PQRCCore` test target did not compile without it, so it is included
here rather than left blocking the suite.

## Still outstanding

**Bind the KEM public key into the derivation.** PQXDH §4.12 requires the KEM
public key to enter the key derivation, or one compromised PQ prekey can be
re-encapsulated onto every initiator. ML-KEM binds it internally (FIPS 203
hashes the encapsulation key into the shared secret), so this is defence in
depth rather than a live hole — which is why it was left out of this change set.
It is the natural fourth item and costs nothing extra to fold into a future
`hybrid-v3`, since the `"suite"` field already exists to negotiate exactly this.

**A `DEVIATIONS.md` entry is owed** for the `hybrid-v2` bump and the `ik_dh_sig`
field (D2 currently records `hybrid-v1`). It is not in this commit because that
file has unrelated uncommitted work in the tree; adding it here would have
dragged that in.
