# SIGNING-AND-DISTRIBUTION.md — shipping the Eldr ACP Configurator

How to sign, notarize, and package the **Eldr ACP Configurator** macOS app
(`Apps/Huginn/`) as a DMG others can run.

This is the **distribution** story only. The app builds and runs from Xcode with no
certificates at all — see
[`Apps/Huginn/README.md`](../Apps/Huginn/README.md) for
build/run. You need the steps below only when you want to hand the DMG to someone
else's Mac (DEVIATIONS AC12).

---

## Why two certificate types, and which you need

macOS code-signing certificates come in different flavors. For a Mac app distributed
*outside* the App Store, only two matter:

| | **Apple Development** | **Developer ID Application** |
|---|---|---|
| Purpose | Local development signing | Distribution outside the App Store |
| Where it runs | The developer's own Mac(s) | **Any** Mac, once notarized |
| Gatekeeper on *other* Macs | **Rejected** ("can't be opened / unidentified developer") | **Accepted** (after notarization + stapling) |
| Notarization | N/A | **Required** for clean Gatekeeper |
| Apple Developer Program ($99/yr) | Not strictly required (a free account can make one) | **Required** |

**Rule of thumb:**

- Just trying the app on *your* machine? Build from Xcode. The **Apple Development**
  signature Xcode applies automatically is enough. It will **not** open on anyone
  else's Mac — that's expected.
- Sending the DMG to a teammate or beta tester? You need a **Developer ID
  Application** certificate **and** notarization. That is exactly what
  `Apps/Huginn/build-dmg.sh` automates.

> The Mac App Store path (a *Mac App Store* distribution certificate + App Store
> Connect submission) is **not** used here: the Configurator ships unsandboxed
> (DEVIATIONS AC6), and an unsandboxed app cannot go through the Mac App Store.
> Developer ID + notarization is the correct and only fit.

---

## Step 1 — Get a Developer ID Application certificate

You need an **Apple Developer Program** membership ($99/yr) — a free Apple ID account
cannot create Developer ID certificates. Then, either of these:

### Option A — via Xcode (simplest)

1. **Xcode ▸ Settings ▸ Accounts**, sign in with your Apple ID, and select your team.
2. Click **Manage Certificates…**.
3. Click the **+** button and choose **"Developer ID Application"**.
4. Xcode generates the certificate and installs it (with its private key) into your
   **login keychain**. Done — `build-dmg.sh` will find it by name.

### Option B — via the developer portal (manual CSR)

1. In **Keychain Access ▸ Certificate Assistant ▸ Request a Certificate From a
   Certificate Authority…**, enter your email, choose **Saved to disk**, and save the
   `.certSigningRequest` (CSR) file.
2. Go to **developer.apple.com ▸ Certificates, Identifiers & Profiles ▸
   Certificates ▸ +**, choose **Developer ID Application**, upload the CSR, and
   download the resulting `.cer`.
3. Double-click the downloaded `.cer` to import it into your login keychain (it pairs
   with the private key the CSR created).

**Verify** it landed:

```bash
security find-identity -v -p codesigning
# Look for a line like:
#   1) ABC123…  "Developer ID Application: Your Name (TEAMID1234)"
```

That quoted string is your signing identity. `build-dmg.sh` defaults to matching
`"Developer ID Application"`; override with `DEVELOPER_ID="…"` if you have several.

---

## Step 2 — Create an app-specific password (for notarization)

Notarization uploads the app to Apple, which authenticates with your Apple ID plus an
**app-specific password** (not your real Apple ID password):

1. Sign in at **appleid.apple.com**.
2. **Sign-In and Security ▸ App-Specific Passwords ▸ +** (Generate).
3. Name it (e.g. *eldr-acp notarytool*) and copy the generated password — it looks
   like `abcd-efgh-ijkl-mnop`. You can't view it again later; regenerate if lost.

This becomes `APP_PASSWORD` for the build script.

---

## Step 3 — Find your Team ID

Your 10-character **Team ID** is on **developer.apple.com ▸ Membership** (the
"Team ID" field), or in the certificate name from Step 1 — the parenthesized
`(TEAMID1234)`. You can also read it back from the keychain:

```bash
security find-identity -v -p codesigning   # the (XXXXXXXXXX) in the identity name
```

This becomes `TEAM_ID`.

---

## Step 4 — Build the DMG

`Apps/Huginn/build-dmg.sh` does the whole pipeline:
**archive → export the `.app` → notarize (submit + wait) → staple → build a
compressed DMG → sign the DMG.** It needs the three values from above (plus the
optional signing-identity override):

```bash
cd Apps/Huginn

export APPLE_ID="you@example.com"          # your Apple ID email
export APP_PASSWORD="abcd-efgh-ijkl-mnop"  # the app-specific password from Step 2
export TEAM_ID="TEAMID1234"                # the 10-char Team ID from Step 3
# Optional — only if the default match is ambiguous:
# export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID1234)"

./build-dmg.sh
```

Output: **`dist/EldrACP-<version>.dmg`** (signed, notarized, stapled). The version is
read from the project's `MARKETING_VERSION` (currently `0.1.0`).

Notes:

- The script archives **Release** with manual signing against your Developer ID, so a
  certificate from Step 1 must be in your login keychain or it fails immediately.
- `notarytool submit --wait` blocks until Apple returns a verdict (usually a few
  minutes). On success it staples the ticket so the app validates **offline** on the
  recipient's Mac.
- This step is intentionally **not** part of CI and requires a paid account
  (DEVIATIONS AC12).

---

## The current DMG: signed, not notarized

`Apps/Huginn/dist/EldrACP-0.1.0.dmg` exists today but is **signed only,
not notarized** — so it opens on the machine that built it and **Gatekeeper will
block it on any other Mac**. To produce a distributable build, run `build-dmg.sh`
with the credentials above. The `dist/` directory is git-ignored; DMGs are build
artifacts and are not committed.
