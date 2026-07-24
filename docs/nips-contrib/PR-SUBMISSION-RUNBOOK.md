# Submitting the NIP PRs to `block/buzz` — step by step

Written for someone who has **never opened a pull request**. Every command is
copy-pasteable. Nothing here touches the Eldr repo; you are contributing three
documents to somebody else's project.

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

We are splitting three specs across **two** PRs. Reasoning:

| PR | Contains | Why grouped this way |
|---|---|---|
| **PR 1** | `NIP-AD` — Untrusted Data Admission | Standalone, uncontested, fills a hole Buzz's own NIP-AE explicitly punts on ("Admission control is the implementer's problem"). Highest chance of a clean merge. Nothing else depends on it. |
| **PR 2** | `NIP-AS` — Sealed Attestation<br>`NIP-AC` — Consent Windows | These two cross-reference each other and argue one story (authorization under an *untrusted* relay). Splitting them leaves dangling links and makes each look weaker than it is. |

Keeping PR 1 separate matters: it is the strongest of the three and shouldn't
share a fate with the two that push on Buzz's trusted-relay assumption.

> If you'd rather do one PR with all three, or three PRs, the mechanics below
> are identical — just change which files you copy and which body you use.

### Naming note (already handled, but know why)

The drafts were `NIP-C1/C2/C3`. Buzz uses **two-letter** codes and already has a
**`NIP-CW`** (Channel Window), which collided with "Consent Windows". They are
now:

- `NIP-AD` — Untrusted Data Admission
- `NIP-AS` — Sealed Attestation
- `NIP-AC` — Agent Consent Windows

All three are free in their tree and fit their `A*` agent-plane family
(`NIP-AA`, `AE`, `AM`, `AO`, `AP`). Each file says maintainers are free to
reassign the code.

---

## Step 0 — One-time setup

### 0a. Log in to GitHub from the terminal

You are **not currently logged in** (`gh auth status` says so). Run:

```bash
gh auth login
```

Answer the prompts: **GitHub.com** → **HTTPS** → **Yes** (authenticate Git) →
**Login with a web browser**. It shows a one-time code, you paste it in the
browser, done.

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

### 2c. Fix the internal cross-links

The draft links to `NIP-AS-sealed-attestation.md` and
`NIP-AC-consent-windows.md`, which won't exist in their tree under those names.
Point them at the names PR 2 will use (a link to a not-yet-merged file is fine —
it's a plain markdown link, nothing breaks):

```bash
cd ~/Development\ Projects/buzz
sed -i '' 's/NIP-AS-sealed-attestation\.md/NIP-AS.md/g; s/NIP-AC-consent-windows\.md/NIP-AC.md/g' docs/nips/NIP-AD.md
grep -n 'NIP-A[SC]' docs/nips/NIP-AD.md    # sanity check
```

*(This exact `sed` was tested against a copy of the file — it rewrites all three
long-form cross-references and leaves nothing behind.)*

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

## Step 3 — PR 2: NIP-AS + NIP-AC

Same shape. Note `git checkout main` first — you want this branch off `main`,
**not** off your NIP-AD branch, so the two PRs stay independent.

```bash
cd ~/Development\ Projects/buzz
git checkout main
git checkout -b nip-as-ac-sealed-attestation-consent-windows

cp ~/Development\ Projects/Eldr/docs/nips-contrib/NIP-AS-sealed-attestation.md docs/nips/NIP-AS.md
cp ~/Development\ Projects/Eldr/docs/nips-contrib/NIP-AC-consent-windows.md    docs/nips/NIP-AC.md

# Same link rewrite, both files.
sed -i '' 's/NIP-AS-sealed-attestation\.md/NIP-AS.md/g; s/NIP-AC-consent-windows\.md/NIP-AC.md/g; s/NIP-AD-untrusted-data-admission\.md/NIP-AD.md/g' docs/nips/NIP-AS.md docs/nips/NIP-AC.md

git add docs/nips/NIP-AS.md docs/nips/NIP-AC.md
git status      # expect exactly two new files
```

```bash
git commit -m "docs(nips): NIP-AS sealed attestation + NIP-AC agent consent windows

NIP-AS carries a NIP-OA-equivalent owner attestation inside a NIP-59 gift wrap,
so a recipient can verify agent provenance without the owner-agent linkage
becoming public. Identical credential math to NIP-OA; only the tag position
moves.

NIP-AC adds a bounded, human-signed, owner-revocable authorization window.
NIP-AA Revocation Semantics notes an owner cannot unilaterally revoke a NIP-OA
credential; this supplies the missing instrument for deployments with no
trusted relay to drop membership.

Both include BIP-340 test vectors using NIP-OA's pinned test keys."
```

```bash
git push -u fork nip-as-ac-sealed-attestation-consent-windows

gh pr create \
  --repo block/buzz \
  --base main \
  --head SnoobieJunes:nip-as-ac-sealed-attestation-consent-windows \
  --title "docs(nips): NIP-AS sealed attestation + NIP-AC agent consent windows" \
  --body-file ~/Development\ Projects/Eldr/docs/nips-contrib/pr-body-2-nip-as-ac.md
```

---

## Step 4 — After you click submit

### What happens automatically

CI will run. Buzz's `just ci` covers Rust fmt/clippy, unit tests, and mobile —
**none of which a docs-only change can break.** If something goes red, it is
almost certainly unrelated to you; say so politely and ask.

Their PR checklist mentions `just ci` passing locally. For a documentation-only
PR that is not meaningful, and the PR body says so explicitly. Do not try to run
`just ci` — it wants Docker, Postgres, Redis, Flutter, and a Rust toolchain, and
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
  offer this. Just say "happy to move it" and close the PR — nothing is lost,
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
| "My fork is now a permanent obligation." | No. Delete it whenever: `gh repo delete SnoobieJunes/buzz`. |
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
- **NIP-AS** — moderate. Clean and cheap (NIP-OA's math, moved), but it only
  matters if you care about metadata privacy, which is more Eldr's axiom than
  Buzz's. Explicitly marked as *not* a NIP-AA replacement, which should defuse
  the obvious objection.
- **NIP-AC** — hardest. It argues their revocation story is incomplete, which is
  true *under an untrusted relay* and false under theirs. The framing throughout
  is "counterpart, not correction." Expect discussion. Discussion is a win; this
  is the one where being in the conversation matters more than merging.

None of the three requires them to change existing code. That is the single
biggest thing working in your favor.
