# Publishing the extracted repos

Eight repos are built, tested, and committed locally in
`/Users/auston/Development Projects/eldr-oss/`. **None has a remote. Nothing is
pushed.** This is the checklist to change that.

Companion: [`OSS-EXTRACTION-AUDIT.md`](OSS-EXTRACTION-AUDIT.md) (what shipped and
why), and the original survey it superseded,
[`archive/2026-07-24/OPEN-SOURCE-EXTRACTION-CATALOG.md`](../done/2026-07-24/OPEN-SOURCE-EXTRACTION-CATALOG.md).

---

## Before you push anything: four decisions

**1. Is the Eldr repo going public?**
Not strictly a blocker — every extracted repo carries its own Apache-2.0 grant and
none imports app code, so they can go public while Eldr stays private. But every
README links to `github.com/SnoobieJunes/Eldr` for provenance. If Eldr stays
private those are 404s for everyone else. Either publish Eldr, or strip the links.

**2. Public or private repos to start?**
`gh repo create --private` costs nothing and can be flipped later. Flipping the
other way does not un-publish anything. Recommend starting private, checking the
rendered READMEs and the CI runs, then flipping to public.

**3. Are you ready to be a maintainer of eight repos?**
Each has a `SECURITY.md` promising **acknowledgement within 72 hours** and
**coordinated disclosure within 90 days**. That is a real commitment on eight
surfaces. If that is more than you want, edit the SECURITY.md files *before*
pushing — a promise you quietly stop keeping is worse than a narrower one made
honestly.

**4. Order matters for exactly one pair.**
`eldr-acp` depends on `swift-a2a` by **published URL**, so `swift-a2a` must be
pushed and tagged `0.1.0` before `eldr-acp` will resolve for anyone. See step 4.

---

## Step 0 — Log in

You are not currently authenticated:

```bash
gh auth login          # GitHub.com → HTTPS → Yes → browser
gh auth status         # expect: Logged in to github.com as SnoobieJunes
```

---

## Step 1 — Sanity check what you are about to publish

```bash
cd ~/Development\ Projects/eldr-oss
for r in */; do
  echo "=== $r"
  git -C "$r" log --oneline
  git -C "$r" ls-files | head -20
done
```

Two things to confirm with your own eyes:

- **No `private/`, no `.env`, no keys.** These repos were built from clean copies,
  but check.
- **The test-key warnings are intact.** `NIP-AD.md` in `untrusted-data-envelope`
  carries a "TEST NONCE — DO NOT USE IN PRODUCTION" callout. Keep it.

Re-run the suites if you want the assurance fresh:

```bash
for r in */; do (cd "$r" && echo "--- $r" && swift test 2>&1 | grep "Test run with"); done
```

Expected on macOS: 10, 13, 19, 32, 18, 30, 89 (4 targets), 278 (2 targets) —
**489 total**.

To re-run the Linux verification (needs `colima start` first):

```bash
docker run --rm -v "$PWD":/src swift:6.2 bash -lc '
  REPOS="swift-message-padding swift-credential-redactor swift-reasoning-trace
         untrusted-data-envelope swift-pqxdh swift-double-ratchet swift-a2a eldr-acp"
  for r in $REPOS; do
    mkdir -p /tmp/w/$r
    tar -C /src/$r --exclude=.build --exclude=.swiftpm -cf - . | tar -C /tmp/w/$r -xf -
  done
  echo "### $(swift --version 2>&1 | head -1)"
  for r in $REPOS; do
    cd /tmp/w/$r
    out=$(swift test 2>&1) || true
    n=$(echo "$out" | grep -oE "Test run with [0-9]+ tests?" | grep -oE "[0-9]+" \
        | awk "{s+=\$1} END {print s+0}")
    echo "$out" | grep -qE "error:|✘" && st=FAIL || st=GREEN
    printf "%-28s %4s tests  %s\n" "$r" "$n" "$st"
  done'
```

Expected on Linux: 10, 13, 19, 32, 18, 30, 80, 270 — **472 total**. The
`--exclude=.build` matters: mounting the host tree directly lets a macOS `.build`
leak into the container and the eldr-acp end-to-end test then execs an arm64-macOS
binary ("Exec format error").

---

## Step 2 — Create the remotes

```bash
cd ~/Development\ Projects/eldr-oss

create() { gh repo create "SnoobieJunes/$1" --private --source "$1" --remote origin --description "$2"; }

create swift-message-padding     "Fixed-size bucket padding for encrypted messages — hide plaintext length from ciphertext length. Zero dependencies."
create swift-credential-redactor "Replaces secret-shaped text with opaque markers before it reaches someone who shouldn't see it. Zero dependencies."
create swift-reasoning-trace     "Strips a reasoning model's chain-of-thought scratchpad out of a completion. Zero dependencies."
create untrusted-data-envelope   "Structural prompt-injection containment for text handed to an LLM. Reference implementation of NIP-AD. Zero dependencies."
create swift-pqxdh               "Post-quantum asynchronous key agreement: hybrid X25519 + ML-KEM-768 X3DH."
create swift-double-ratchet      "The Signal Double Ratchet with a periodic ML-KEM-768 post-quantum rekey."
create swift-a2a                 "A clean-room Swift SDK for the Agent2Agent (A2A) protocol v1.0. Zero dependencies."
create eldr-acp                  "A hardened Swift Agent Client Protocol agent: path jail, permission gating, encrypted audit log."
```

`--source` wires the remote without pushing. Nothing is live yet.

---

## Step 3 — Push the independent repos

Six of the eight have no cross-repo dependency. Push them in any order:

```bash
cd ~/Development\ Projects/eldr-oss
for r in swift-message-padding swift-credential-redactor swift-reasoning-trace \
         untrusted-data-envelope swift-pqxdh swift-double-ratchet; do
  git -C "$r" push -u origin main
done
```

Watch CI:

```bash
for r in swift-message-padding swift-credential-redactor swift-reasoning-trace \
         untrusted-data-envelope swift-pqxdh swift-double-ratchet; do
  echo "=== $r"; gh run list --repo "SnoobieJunes/$r" --limit 1
done
```

> **Both jobs have been verified locally.** Linux was run under colima with the
> `swift:6.2` container on aarch64 — all eight repos build and test green (472
> tests; the 17-test gap versus macOS is platform-gated suites, itemised in the
> audit §5.1). CI runs the same image, so a red Linux job means an environment
> difference — most likely **x86-64**, which was not tested locally, since GitHub's
> standard runners are x86-64 and this Mac is arm64.

---

## Step 4 — The `swift-a2a` → `eldr-acp` pair

> **Corrected 2026-07-24.** An earlier revision of this step said
> `eldr-acp/Package.swift` still carried `.package(path: "../a2a-swift")` and gave a
> `perl -pi -e` one-liner to rewrite it. Both were wrong, and wrong in a way that
> fails silently: the manifest **already** declares the URL form
> (`eldr-acp/Package.swift:49`), so the substitution would have matched nothing and
> reported success. The repo is also named **`swift-a2a`**, not `a2a-swift` — that
> rename is recorded in the audit (§5.3, "the name `a2a-swift` was already taken by
> a package on the Swift Package Index") but had not been carried into this file.

`eldr-acp/Package.swift:49` already reads:

```swift
.package(url: "https://github.com/SnoobieJunes/swift-a2a.git", from: "0.1.0"),
```

So there is **nothing to edit**. What remains is purely an ordering constraint:
that URL must resolve before anyone (including CI) builds `eldr-acp`, which means
`swift-a2a` must be pushed **and tagged `0.1.0`** first.

```bash
cd ~/Development\ Projects/eldr-oss

# 4a. Push swift-a2a and tag it. This must complete before 4b.
git -C swift-a2a push -u origin main
git -C swift-a2a tag -a 0.1.0 -m "0.1.0 — initial extraction"
git -C swift-a2a push origin 0.1.0

# 4b. Confirm eldr-acp resolves against the PUBLISHED package, not a local copy.
#     Wipe the resolved state first, or SwiftPM may reuse a cached checkout and
#     you will not learn whether the URL actually works for anyone else.
cd eldr-acp
rm -rf .build .swiftpm/xcode/package.xcworkspace/xcshareddata/swiftpm/Package.resolved
swift package resolve            # must fetch from github.com, not ../swift-a2a
swift build && swift test        # must still be 278 tests green
git push -u origin main
```

If `swift-a2a` is a **private** repo, the URL dependency needs SSH auth
(`git@github.com:...`) or a token. Simplest path: make `swift-a2a` public at this
point, or keep both private and use the SSH URL.

---

## Step 5 — Tag the rest

Only after CI is green:

```bash
cd ~/Development\ Projects/eldr-oss
for r in swift-message-padding swift-credential-redactor swift-reasoning-trace \
         untrusted-data-envelope swift-pqxdh swift-double-ratchet eldr-acp; do
  git -C "$r" tag -a 0.1.0 -m "0.1.0 — initial extraction"
  git -C "$r" push origin 0.1.0
done
```

**0.1.0, not 1.0.0, deliberately.** Pre-1.0 signals that the API may move, which
is true — these have one consumer so far. SwiftPM's `from: "0.1.0"` treats 0.x
minor bumps as breaking, which is the correct semantics here.

Every README's install snippet already says `from: "0.1.0"`, so the tags match
the docs on day one.

---

## Step 6 — Repo settings (per repo, once)

Worth doing, quickly:

```bash
for r in swift-message-padding swift-credential-redactor swift-reasoning-trace \
         untrusted-data-envelope swift-pqxdh swift-double-ratchet swift-a2a eldr-acp; do
  gh repo edit "SnoobieJunes/$r" \
    --enable-issues --enable-wiki=false --enable-projects=false \
    --delete-branch-on-merge
done
```

Then, in the GitHub UI or via `gh api`:

- **Enable private vulnerability reporting** (Settings → Security). Every
  `SECURITY.md` tells people to use it; it is off by default.
- **Topics**, so the repos are findable: `swift`, `cryptography`,
  `post-quantum`, `nostr`, `prompt-injection`, `ai-agents`, `acp`, `a2a` as
  appropriate.
- **Branch protection on `main`** if you want CI to gate merges.

---

## Step 7 — Announce (optional, and only when ready)

The two with an actual audience beyond you:

- **`untrusted-data-envelope`** — the strongest. It pairs with the NIP-AD PR to
  `block/buzz` (see [`nips-contrib/`](../nips-contrib/)). Landing the PR first and
  then pointing at a working reference implementation is a much better story than
  either alone. **Sequence: PR first, repo link in the PR discussion.**
- **`swift-a2a`** — genuinely fills a gap *if* the a2aproject org still has no
  Swift SDK. **Verify that before saying it out loud** — the README hedges
  correctly, but a launch post that asserts it and is wrong is embarrassing in a
  way the README is not.

The rest are useful but not announcement-worthy on their own. They are there so
that when someone needs bucket padding or a credential scrubber, it exists.

---

## Rollback

Nothing here is hard to undo before it gets attention:

```bash
gh repo delete SnoobieJunes/<name>       # asks for confirmation
```

Local repos are untouched by that. After anyone has starred, forked, or depended
on a repo, deleting it breaks their builds — so the real point of no return is
*attention*, not the push.

---

## Not covered here

- **Publishing to the Swift Package Index** — it picks up public repos with a
  `Package.swift` automatically once you submit them; do that after 0.1.0 tags.
- **The remaining eleven extraction candidates** — see §6 of the audit. The
  pattern is established; each is a repeat of it.
- **Eldr's own public release** — a separate decision with its own trade-offs
  (`LICENSING.md`, `TRADEMARKS.md`).
