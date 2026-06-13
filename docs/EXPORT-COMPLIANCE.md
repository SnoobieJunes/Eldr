# EXPORT-COMPLIANCE.md — US encryption export declaration for EldrChat (PQRC)

EldrChat is end-to-end encrypted. Under US export law that means it is **not**
one of the narrow "exempt" cases (HTTPS-only, authentication-only, DRM-only),
so the honest declaration is `ITSAppUsesNonExemptEncryption = YES`. This file
records that decision and the exact steps to clear export compliance at
submission. It is operational guidance, **not legal advice** — verify the
current rules with BIS (bis.doc.gov) and your own counsel before you file.

## What's already set in the project

`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES` is set as a build setting
on the app target in **both** Debug and Release
(`App/EldrChat.xcodeproj/project.pbxproj`). It is intentionally **not** also in
the custom `App/Info.plist` — declaring it in both places makes the archive
validator reject the duplicate (that was the original validation error; commit
`a723557`). The build setting is the single source.

Having this key present (with any value) is what stops App Store Connect from
re-asking "Does your app use encryption?" on every upload.

## Why `YES`, and why we still qualify to ship

PQRC composes only **standard, published** primitives — AES-256-GCM,
ChaCha20-Poly1305, SHA-2, HKDF, X25519, Ed25519, secp256k1, ML-KEM-768
(FIPS 203) — via Apple CryptoKit / swift-crypto and libsecp256k1. No
proprietary or custom cryptography (SPEC §2; THREAT_MODEL §5). That makes it
**mass-market software** under EAR Category 5, Part 2, eligible for the
self-classification exemption at **§740.17(b)(1)**. `YES` + claiming this
exemption is the correct, honest path. Do **not** flip the flag to `NO` to skip
the questionnaire — for an E2EE app that is a false declaration.

## At submission — the exact App Store Connect answers

When you upload the build and open the version's **Export Compliance** section:

1. "Does your app use encryption?" — **Yes** (it's already declared in the
   plist, so you may not even be re-asked).
2. "Does your app qualify for any of the exemptions provided in Category 5,
   Part 2?" — **Yes**.
3. "Does your app implement any standard encryption algorithms instead of, or
   in addition to, using or accessing the encryption within Apple's operating
   system?" — **Yes** (we use ML-KEM-768 and the AEAD/ratchet schedule, not
   only OS TLS).
4. It will then ask whether you've shipped/exported French-localized versions
   (a France-specific question) — answer per your actual distribution.
5. You'll be asked to confirm you'll file (or have filed) the annual
   **self-classification report**. See below.

If Apple shows you a **compliance code** after processing the first version,
add it to the build settings as
`INFOPLIST_KEY_ITSEncryptionExportComplianceCode = <code>` to skip the
questionnaire on every future upload. **Do not invent or placeholder this
value** — only add it once Apple has issued it.

## The annual filing you owe (don't skip this)

Self-classification under §740.17(b)(1) requires emailing a
**self-classification report** to BIS and the NSA ENC coordinator
(historically `crypt@bis.doc.gov` and `enc@nsa.gov`) listing the product. It is
due **annually (by Feb 1, covering the prior calendar year)** and again
whenever a new encryption item first ships. Keep a copy with your records.
Confirm the current addresses, format, and deadline against BIS guidance before
sending — these specifics change.

## Where the relay fits

This declaration covers the **iOS client only**. The `pqrc-relay` server moves
ciphertext and holds no keys, but if you operate it across borders, assess its
own export posture separately (THREAT_MODEL §2.7 / the relay operator's
IP-and-retention policy decision).
