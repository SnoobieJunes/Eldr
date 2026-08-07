# `site/` — what GitHub Pages publishes

`index.html` is the Eldr promotional page: one self-contained file, fonts and styles
inlined, no external assets. It was `docs/pitch/eldr-promo.html` until it became the
published site.

It is deployed by [`.github/workflows/pages.yml`](../.github/workflows/pages.yml) on
every push to `main` that touches this folder.

**Why it is not in `docs/`.** Pages' branch-source picker offers exactly two folders,
`/` and `/docs`. Serving from `/docs` would publish the entire documentation tree —
SPEC, DEVIATIONS, `plan/`, `done/` — as a website. The Actions workflow publishes
this folder and nothing else.

**One-time setup:** Settings → Pages → Source: **GitHub Actions**. Nothing deploys
until that is set.
