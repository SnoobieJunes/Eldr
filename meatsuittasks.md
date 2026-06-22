# Meatsuit Tasks — things only a human can do

The list of work that **can't be automated** — your decisions, anything needing a real
device/account, and physical configuration. Code work (the toggles, the rename, the ACP
upgrades) is tracked separately in the implementation plan and git history; this file is
only the human-in-the-loop items. Check things off as you go.

Last updated: 2026-06-21.

---

## Decisions (made — recorded so they don't get re-litigated)
- [x] **Huginn rename:** FULL rename (new bundle id `chat.eldr.huginn`), accepting a one-time re-pair.
- [x] **Tool approval model:** add an interactive **"Ask each time"** prompt (Allow once / Allow always / Deny).
- [x] **ACP upgrades:** build all four — Plan/TODO visibility, node-side image input, MCP passthrough, interactive PTY terminal.
- [x] **swift-secp256k1:** keep it. Apple's CryptoKit has no secp256**k1** (only NIST P-256); this package wraps Bitcoin Core's audited `libsecp256k1`, which is exactly what CLAUDE.md mandates over invented crypto.

## Configure / run (one-time setup on your machines)
- [ ] **After Huginn ships:** re-pair the Mac node with your phone (it gets a fresh identity) and re-enter the LLM token in Huginn's settings. The bundle-id change orphans the old Keychain items, so the old identity/token are not readable by the renamed app. *(Optional cleanup: delete the old `chat.eldr.acp.configurator` items in Keychain Access.app.)*
- [ ] Don't commit IDE-flipped entitlements. The new `Huginn.entitlements` ships with `app-sandbox = false` on purpose (the app spawns the agent process); if Xcode re-flips it to `true`, revert before building/committing.
- [ ] Provide the LLM endpoint + token on **each machine that runs a node** — in Huginn's settings, or via `ELDR_LLM_URL` / `ELDR_LLM_TOKEN` (+ optional `ELDR_LLM_MODEL`) for the headless `eldr-node`.
- [ ] To run a **headless node** (server/second Mac): `swift build -c release --package-path Packages/EldrNode`, then `eldr-node --owner <your phone's PQRC identity hex>`. (Find your phone's identity hex in EldrChat settings.)

## Test on real devices (cannot be done headlessly — needs 2 devices + the real relay)
- [ ] Pair phone + Mac over the real relay (`relay.lerants.com`); verify the binding both directions.
- [ ] Turn ON **"Remote dev-control"** for the node (the new toggle), send a prompt, confirm the Mac agent runs and its reply comes back on the phone.
- [ ] **"Ask each time":** with autonomous-changes OFF, trigger a write/shell action; confirm the phone prompts Allow once / Allow always / Deny; confirm **Deny** blocks it; confirm that **ignoring** the prompt for ~120s makes the node deny on its own (fail-closed).
- [ ] Per-chat **egress firewall** with a cloud AI: confirm ON redacts names/bounds context, OFF sends raw (for your own private agents).
- [ ] Run the standalone `eldr-node` on a **second Mac/server** and drive it from the phone.

## Distribute (needs your Apple Developer account)
- [ ] Sign **Huginn** with Developer ID + notarize for the DMG (see `docs/SIGNING-AND-DISTRIBUTION.md`).
- [ ] **EldrChat App Store prep:** review notes framing it as "remote control of YOUR own Mac on your network" (guideline 4.2.7, cf. Termius/Moshi); set `NSLocalNetworkUsageDescription`; `ITSAppUsesNonExemptEncryption = YES` + export classification (License Exception ENC 5D992.c); privacy nutrition labels; a content report/block path.
- [ ] **BIS annual self-classification report** (due Feb 1). French **ANSSI** declaration only if shipping in France.

## Optional / later
- [ ] Self-host a relay via the `hughin` provisioning wizard — only if you'd rather not use `relay.lerants.com`.
- [ ] Decide the fate of the legacy standalone MCP-server path once ACP MCP-passthrough lands (the passthrough lets the Mac agent *use* your chat tools; the standalone MCP server for external clients is a separate thing).
