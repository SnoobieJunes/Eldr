# Submitting the NIP PRs to `block/buzz` — step by step

Written for someone who has **never opened a pull request**. Every command is
copy-pasteable. Nothing here touches the Eldr repo; you are contributing three
documents to someone else's project.

**Time:** ~20 minutes, most of it waiting for GitHub.

---

## What you are doing, in one paragraph

Block's Buzz project keeps its protocol drafts in `docs/nips/` in the
[`block/buzz`](https://github.com/block/buzz) repository. You cannot write to
that repository. So you make your own copy of it on GitHub (a **fork**), add
your files to a **branch** in your copy, push it, and then ask Block to pull
your branch into theirs (a **pull request**, or PR). They review, comment, and
either merge it or don't. Opening a PR is not presumptuous — it is the normal,
expected way to propose anything, and it costs the maintainers nothing to close.

---

## The two PRs

We are splitting two new drafts and one amendment across **three** PRs. Reasoning:

| PR | Contains | Why separate |
|---|---|---|
| **PR 1** | `NIP-AD` — Untrusted Data Admission | Standalone, uncontested, fills a hole Buzz's own NIP-AE explicitly punts on ("Admission control is the implementer's problem"). Highest chance of a clean merge. Nothing else depends on it. |
| **PR 2** | `NIP-AC` — Agent Consent Windows | The one that pushes on Buzz's trusted-relay assumption. Kept apart so it can't drag the other two down. |
| **PR 3** | amendment to `NIP-OA` — unsigned carriers | A few lines added to a NIP they already own. Small, self-contained, and arguably the likeliest of the three to land. |

> If you'd rather do one PR with everything, the mechanics below are identical —
> just change which files you copy and which body you use.

### Naming note (already handled, but worth knowing why)

The drafts were `NIP-C1/C2/C3`. Buzz uses **two-letter** codes and already has a
**`NIP-CW`** (Channel Window), which collided with "Consent Windows". They are
now:

- `NIP-AD` — Untrusted Data Admission
- `NIP-AC` — Agent Consent Windows

Both are free in their tree and fit their `A*` agent-plane family (`NIP-AA`,
`AE`, `AM`, `AO`, `AP`). Each file says maintainers are free to reassign the code.

### NIP-AS was withdrawn

`NIP-C2` / `NIP-AS` (Sealed Attestation) is **not** being submitted as a NIP. A
cross-reference against NIP-OA, NIP-17 and NIP-59 showed it was almost entirely a
second name for something NIP-OA already permits — the tag, preimage, grammar and
signature were all NIP-OA's unchanged. The one genuine obstacle is NIP-OA's
requirement that `id` and `sig` be valid before an `auth` tag counts as
provenance, which a NIP-59 rumor structurally cannot satisfy. That is a
verification rule, so it is PR 3 above. The old draft remains in Eldr's git
history.

---

## Step 0 — One-time setup

### 0a. Log in to GitHub from the terminal

You are **not currently logged in** (`gh auth status` says so). Run:

```bash
gh auth login
```

Answer the prompts: **GitHub.com** → **HTTPS** → **Yes** (authenticate Git) →
**Login with a web browser**. It shows a one-time code; paste it in the
browser and you're done.

Verify:

```bash
gh auth status
```

You should see `Logged in to github.com as SnoobieJunes`.

### 0b. Set your commit identity (if you haven't)

```bash
git config --global user.name "Auston"
git config --global user.email "leroy@auston.org"
```

Use whatever name/email you want publicly attached to the commit — it will be
visible forever in Block's git history.

---

## Step 1 — Fork and prepare your clone

You already have Buzz cloned at `~/Development Projects/buzz`, on a clean `main`
tracking `origin/main`. We'll keep `origin` pointing at Block's repo and add
your fork as a second remote called `fork`.

```bash
cd ~/Development\ Projects/buzz

# Make sure you're starting from Block's latest main.
git checkout main
git pull origin main

# Create your fork on GitHub and wire it up as the `fork` remote.
gh repo fork --remote=false --clone=false
git remote add fork "https://github.com/SnoobieJunes/buzz.git"
git remote -v      # should list origin (block/buzz) and fork (SnoobieJunes/buzz)
```

If `git remote add fork` says the remote already exists, you've done this
before — carry on.

> **Why not just `gh repo fork --remote`?** That renames your remotes and can
> leave `origin` pointing at your fork, which is a common source of "why did my
> PR go to the wrong place". Explicit is better here.

---

## Step 2 — PR 1: NIP-AD (Untrusted Data Admission)

### 2a. Branch

```bash
cd ~/Development\ Projects/buzz
git checkout main
git pull origin main
git checkout -b nip-ad-untrusted-data-admission
```

### 2b. Copy the file in

```bash
cp ~/Development\ Projects/Eldr/docs/nips-contrib/NIP-AD-untrusted-data-admission.md \
   docs/nips/NIP-AD.md
```

Note the rename: their tree uses bare `NIP-XX.md` filenames.

### 2c. Check the internal cross-links

No rewrite is needed. NIP-AD links only to `NIP-AE.md`, `NIP-AM.md`, `NIP-AO.md`,
`NIP-AP.md` and `NIP-OA.md`, all of which already exist in their tree under
exactly those names. Confirm before committing:

```bash
cd ~/Development\ Projects/buzz
grep -oE '\[NIP-[A-Z0-9]+\]\([^)]+\)' docs/nips/NIP-AD.md | sort -u
# expect only NIP-AE / NIP-AM / NIP-AO / NIP-AP / NIP-OA
```

> **On `[NIP-59](59.md)` and similar links to numbered NIPs:** these point at
> files that don't exist in `docs/nips/` either. That's correct — it is Buzz's
> own house convention; their NIP-CW links `[NIP-44](44.md)`, `[NIP-01](01.md)`,
> `[NIP-42](42.md)` the same way. Leave them alone.

### 2d. Review it yourself before committing

```bash
git diff --stat
git add docs/nips/NIP-AD.md
git status
```

You should see exactly **one new file**. If you see anything else, stop and
investigate — you do not want to include unrelated changes.

### 2e. Commit

Buzz uses [conventional commits](https://www.conventionalcommits.org/)
(`feat(nips): …`). Match their style:

```bash
git commit -m "docs(nips): NIP-AD untrusted data admission for agent contexts

Specifies a structural envelope for handing attacker-influenceable text to a
model: per-read 128-bit nonce markers, quoting after splitting on every Unicode
line break, and C0/C1 + bidi escaping. Closes the admission-control gap NIP-AE
Security leaves to the implementer.

Relay-independent and adds no event kind. Includes test vectors generated from
a shipping implementation."
```

> **CLA / DCO:** Buzz requires neither a CLA bot nor a `Signed-off-by` trailer.
> Their CONTRIBUTING says: "By submitting a pull request, you agree that your
> contribution is licensed under the Apache 2.0 license and that you have the
> right to submit it." Eldr's protocol docs are CC0 (public domain), so
> contributing them under Apache-2.0 is unambiguous — you can license public
> domain material any way you like. You own the copyright and there's no
> employer to clear.

### 2f. Push to your fork

```bash
git push -u fork nip-ad-untrusted-data-admission
```

### 2g. Open the PR

```bash
gh pr create \
  --repo block/buzz \
  --base main \
  --head SnoobieJunes:nip-ad-untrusted-data-admission \
  --title "docs(nips): NIP-AD — untrusted data admission for agent contexts" \
  --body-file ~/Development\ Projects/Eldr/docs/nips-contrib/pr-body-1-nip-ad.md
```

It prints a URL. Open it and read the rendered result — this is the last cheap
moment to catch a typo.

---

## Step 3 — PR 2: NIP-AC

Same shape. Note `git checkout main` first — you want this branch off `main`,
**not** off your NIP-AD branch, so the PRs stay independent.

```bash
cd ~/Development\ Projects/buzz
git checkout main
git checkout -b nip-ac-agent-consent-windows

cp ~/Development\ Projects/Eldr/docs/nips-contrib/NIP-AC-consent-windows.md docs/nips/NIP-AC.md

# NIP-AC links to NIP-AD by its long filename; point it at the name PR 1 uses.
sed -i '' 's/NIP-AD-untrusted-data-admission\.md/NIP-AD.md/g' docs/nips/NIP-AC.md
grep -oE '\[NIP-[A-Z0-9]+\]\([^)]+\)' docs/nips/NIP-AC.md | sort -u   # sanity check

git add docs/nips/NIP-AC.md
git status      # expect exactly one new file
```

```bash
git commit -m "docs(nips): NIP-AC agent consent windows

Adds a bounded, human-signed, owner-revocable authorization window. NIP-AA
Revocation Semantics notes an owner cannot unilaterally revoke a NIP-OA
credential; this supplies the missing instrument for deployments with no
trusted relay to drop membership.

Composes with NIP-OA rather than replacing it. Includes BIP-340 test vectors
using NIP-OA's pinned test keys, including a negative agent-signed vector."
```

```bash
git push -u fork nip-ac-agent-consent-windows

gh pr create \
  --repo block/buzz \
  --base main \
  --head SnoobieJunes:nip-ac-agent-consent-windows \
  --title "docs(nips): NIP-AC agent consent windows" \
  --body-file ~/Development\ Projects/Eldr/docs/nips-contrib/pr-body-2-nip-ac.md
```

---

## Step 3b — PR 3: the NIP-OA amendment

This one edits an existing file instead of adding a new one. Open
`NIP-OA-amendment-unsigned-carriers.md`, copy the fenced `## Unsigned Carriers`
block, and paste it into `docs/nips/NIP-OA.md` immediately after the
`## Client Behavior` section.

```bash
cd ~/Development\ Projects/buzz
git checkout main
git checkout -b nip-oa-unsigned-carriers

# edit docs/nips/NIP-OA.md by hand — paste the block after ## Client Behavior
git diff                     # expect one added section, nothing else touched
git add docs/nips/NIP-OA.md
```

```bash
git commit -m "docs(nips): NIP-OA verification inside unsigned carriers

NIP-OA permits an auth tag on any event but requires id and sig to be valid
before treating it as provenance. A NIP-59 rumor has an id and no sig, so an
auth tag inside a gift wrap is currently unverifiable even though everything
the preimage needs is present and NIP-17 already binds the seal's pubkey to the
rumor's.

Specifies that an enclosing signed layer may satisfy the authenticity
precondition. No new tag, kind, cryptography, or condition grammar."
```

```bash
git push -u fork nip-oa-unsigned-carriers

gh pr create \
  --repo block/buzz \
  --base main \
  --head SnoobieJunes:nip-oa-unsigned-carriers \
  --title "docs(nips): NIP-OA verification inside unsigned carriers"
```

Write the body from the amendment file's "The gap" and "The change" sections —
it is short enough to paste directly into the PR description.

---

## Step 4 — After you click submit

### What happens automatically

CI will run. Buzz's `just ci` covers Rust fmt/clippy, unit tests, and mobile —
**none of which a docs-only change can break.** If something goes red, it is
almost certainly unrelated to you; say so politely and ask.

Their PR checklist mentions `just ci` passing locally. For a documentation-only
PR, that is not meaningful, and the PR body says so explicitly. Do not try to run
`just ci` — it requires Docker, Postgres, Redis, Flutter, and a Rust toolchain, and
proves nothing about a markdown file.

### Watching for a response

```bash
gh pr status                        # your open PRs at a glance
gh pr view <number> --repo block/buzz --comments
```

You'll also get email. CONTRIBUTING says "a maintainer will review your PR
within a few business days."

### When they leave comments

- **Push new commits; do not force-push.** Their CONTRIBUTING says so
  explicitly: "Address review comments by pushing new commits (don't force-push
  during review; it makes it hard to see what changed)."

  ```bash
  cd ~/Development\ Projects/buzz
  git checkout nip-ad-untrusted-data-admission
  # edit docs/nips/NIP-AD.md
  git add docs/nips/NIP-AD.md
  git commit -m "docs(nips): address review — clarify nonce lifetime"
  git push fork nip-ad-untrusted-data-admission
  ```

  The PR updates itself. You don't re-open anything.

- **A maintainer will squash-merge when approved.** Your pile of review commits
  collapses to one — so don't fuss over intermediate commit messages.

- **If they want changes you disagree with:** say why, once, plainly, and then
  defer. It's their spec tree. A merged 80%-version beats a perfect rejected one.

- **If they want it as a discussion instead of a PR:** both PR bodies already
  offer this. Just say "happy to move it" and close the PR — nothing is lost;
  the branch still exists.

- **If they don't respond for two weeks:** one polite bump comment. Then leave
  it. These are drafts in someone else's staging area; there is no deadline.

### If you need to withdraw

```bash
gh pr close <number> --repo block/buzz --comment "Withdrawing to rework; thanks for the look."
```

Nothing is destroyed. You can reopen or re-submit later.

---

## Things that will not go wrong, but that you'll worry about

| Worry | Reality |
|---|---|
| "I'll break their repo." | You cannot. You have no write access. A PR is a *request*. |
| "My fork is now a permanent obligation." | No. You can delete it whenever you like: `gh repo delete SnoobieJunes/buzz`. |
| "I committed to the wrong branch." | `git log --oneline -3` to see, then `git checkout -b right-branch` and re-commit; or `git reset --soft HEAD~1` to undo the commit and keep the changes. |
| "I pushed something embarrassing." | Push a fix commit. Everyone does this. Nobody remembers. |
| "They'll think I'm competing with them." | Both PR bodies disclose Eldr up front, by name, with what it is and what it isn't. Disclosure is what makes this normal rather than awkward. |
| "Am I giving away something valuable?" | The specs are already CC0 public domain in Eldr's tree — that was a deliberate decision (see `LICENSING.md`). Adoption *is* the value here. |

---

## The honest read on odds

- **NIP-AD** — good odds. It names a hole they wrote down themselves, needs no
  relay changes, adds no event kind, contradicts nothing, and arrives with
  vectors from working code. The worst realistic outcome is "interesting, we'd
  want it shaped differently."
- **NIP-OA amendment** — best odds of the three, now that it is an amendment
  rather than the NIP-AS draft. It fixes an interaction between two of their own
  specs, adds nothing, and is a few lines. The likely objection is "we don't care
  about gift-wrapped agent traffic," which is a scoping answer rather than a
  correctness one.
- **NIP-AC** — hardest. It argues their revocation story is incomplete, which is
  true *under an untrusted relay* and false under theirs. The framing throughout
  is "counterpart, not correction." Expect discussion. Discussion is a win; this
  is the one where being in the conversation matters more than merging.

None of the three requires them to change existing code. That is the single
biggest thing working in your favor.
