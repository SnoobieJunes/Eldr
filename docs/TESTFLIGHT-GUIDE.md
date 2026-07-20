# TESTFLIGHT-GUIDE.md — Getting EldrChat onto TestFlight

A phased checklist. Items marked **YOU** need a human (account access, money, or a judgment call); items marked **CLAUDE** can be delegated to Claude Code once you've supplied the inputs in §H. Compliance notes below are practical orientation, not legal advice — an E2EE app touches export-control rules where a quick call with counsel is money well spent.

## A. Accounts & identity

1. **YOU** — Enroll in the Apple Developer Program ($99/yr) with an account that has Certificates/App Manager rights. Two-factor on.
2. **YOU** — Pick the public **app name** and **bundle ID** (e.g. `chat.eldr.app`). Note: the protocol's original internal codename was a trademarked name; it has been retired repo-wide and must not appear in any public listing. Decide the real name now; renaming later churns App Store Connect records.
3. **CLAUDE** — Set bundle ID, team, display name, version `0.1.0`, build `1` in the project once you provide Team ID.

## B. Project configuration for distribution

4. **CLAUDE** — App icon set (Claude can generate a placeholder; **YOU** approve or supply final art, 1024×1024 master).
5. **CLAUDE** — `PrivacyInfo.xcprivacy`: no tracking, no collected data types, required-reason API entries only for APIs the code actually uses. Audit against the final source.
6. **CLAUDE** — Usage strings: `NSCameraUsageDescription` ("Scan a contact's QR code to start an encrypted conversation"). PhotosPicker needs no photo-library string (out-of-process). Local-network/Bonjour strings only if the Debug WebSocket relay or Multipeer stretch goal ever ships in a beta build — by default both are compiled out of Release/TestFlight builds.
7. **CLAUDE** — Confirm Release config excludes Local Universe persona switching, chaos sliders, and the localhost relay — except the reviewer-facing demo entry point in §F.
8. **YOU** — Signing: in Xcode, select your team, Automatically Manage Signing; verify an Archive build succeeds locally (Product → Archive).

## C. Encryption & export compliance (the E2EE-specific part)

9. **CLAUDE** — `ITSAppUsesNonExemptEncryption = YES` in Info.plist. EldrChat composes standard, published primitives into a custom E2EE protocol (`pqrc-v1`) — no invented primitives, but a custom composition — and this is *not* exempt the way HTTPS-only apps are.
10. **YOU** — In App Store Connect's encryption questions for the build, expect to answer: uses encryption → **Yes**; only exempt encryption (standard iOS TLS etc.) → **No**. Typical path for mass-market E2EE messengers under US EAR: self-classification as 5D992.c under License Exception ENC §740.17(b), which entails an **annual self-classification report** emailed to BIS and the NSA ENC contact (due each February for the prior year). Read BIS's encryption FAQ, decide, and calendar the report — or have counsel confirm in an hour.
11. **YOU** — **France:** distributing cryptography in France involves a declaration to ANSSI. Pragmatic options: file the declaration (one-time form per product), or initially exclude France from availability in App Store Connect → Pricing and Availability. Decide before external testing, since TestFlight external builds respect storefront availability.

## D. App Store Connect record

12. **YOU** — Create the app in App Store Connect (name, bundle ID, SKU, primary language).
13. **YOU** — Supply a **privacy policy URL** (required). Claude can draft the policy — for this app it's genuinely short: no accounts, no analytics, no data collected by the developer; relays store ciphertext envelopes and see connection IPs; full THREAT_MODEL linked.
14. **YOU** — App Privacy questionnaire. With v1 (local simulator / public third-party relays, no analytics): **"Data Not Collected"** is the defensible answer. Revisit honestly the day you stand up your own anchor relay (decide and document its IP/retention policy first — keep it at "no logs retained" and the answer likely survives, but that's your call to make knowingly).
15. **YOU** — Age rating questionnaire (answer honestly; an unmoderated-comms app typically lands 12+ or 17+ depending on your answers) and category (Social Networking).
16. **CLAUDE** — Beta App Description, What to Test notes, and marketing/support URL stubs once you provide a domain.

## E. Build & upload

17. **YOU/CLAUDE** — Bump build number → Product → Archive → Distribute App → App Store Connect → Upload (or `xcodebuild -exportArchive` + Transporter for CI later). Wait for processing; answer the per-build export-compliance prompt per §C.

## F. TestFlight

18. **YOU** — **Internal testing first** (up to 100 testers on your team, no review, available within minutes of processing). This is where the team lives until the real Nostr transport exists.
19. **YOU** — **External testing** (up to 10,000 testers via link/email) triggers **Beta App Review** on the first build and after significant changes. Critical for EldrChat: reviewers must be able to exercise messaging without your network being live. The reviewer-facing **Demo Mode** ships in Release/beta builds — reachable from the lock screen's **"See the live demo"** and from Settings → "Try the demo" (seeded Local Universe conversation). Spell out the steps in the review notes: *"This build runs against a built-in local demo network. On the lock screen tap See the live demo (or create an account, then Settings → Try the demo) → converse as Alice with Bob; tap the ✳︎ AI Thread to see AI participation; all AI messages are labeled."* Mention the block & report features exist (Guideline 1.2 — user-generated content apps need them; they're in APP-SPEC §6.5).
20. **YOU** — Builds expire after 90 days; plan a refresh cadence. TestFlight's built-in feedback/screenshots is your only telemetry — by design, there is no analytics SDK.

## G. After TestFlight (so it's on the roadmap, not a surprise)

Real relay transport swap (TEST-PLAN §7 conformance suite is the gate) → stand up the anchor relay (AUTH-gated strfry/khatru, kind-1059-only per SPEC §9.1) and a Blossom server with ≥1 mirror → revisit §C/§D answers → OTF Security Lab audit + publish THREAT_MODEL and reproducible-build docs per SPEC §15.

## H. Inputs Claude needs from you — the short list

| # | Input | Needed by |
|---|---|---|
| 1 | Apple Developer Program account + **Team ID** | §A/§B |
| 2 | Final **app name** + **bundle ID** (post-rename decision) | §A |
| 3 | App icon final art, or approval of generated placeholder | §B |
| 4 | **Privacy policy URL** + support/marketing domain (Claude drafts content) | §D |
| 5 | Export-compliance decisions: BIS self-classification yes/no, **France in or out** | §C |
| 6 | App Privacy questionnaire answers confirmed (esp. once an anchor relay exists) | §D |
| 7 | Age-rating questionnaire answers | §D |
| 8 | Anthropic API key **only if** you want the remote agent provider enabled in beta (default is off; on-device/mock otherwise) | optional |
| 9 | Anchor relay + Blossom URLs **when they exist** (not needed for TestFlight demo builds) | §G |
| 10 | Reviewer contact email + demo account note (n/a — demo mode covers it) | §F |
