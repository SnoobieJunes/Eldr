# docs/plan — work that is not finished

**If this folder is empty, nothing is in flight.** That is the point of it.

A plan lives here while its work is unfinished, and **leaves the moment that work
lands in `DEVIATIONS.md`**. It leaves by moving to `../done/<YYYY-MM-DD>/` with
a header saying what superseded it — it is never edited into a status report and
left in place. The reason is specific: a finished plan that stays here becomes a
third thing competing with the ledger, and the facts inside it start drifting
against the docs that replaced it.

## Rules for a document in this folder

1. **One owner and one exit condition, stated in the first ten lines.** A plan
   with neither is not a plan; it is a note, and notes go in `private/`.
2. **Status markers are per-claim, not per-document.** A banner saying "BUILT" at
   the top of a 250-line plan is how a reader ends up trusting the 200 lines
   underneath that are no longer true.
3. **Reference facts, do not copy them.** If a constraint is already stated in a
   guide or in the SPEC, link it. The single most common failure in this repo's
   history was the same fact copied into five plans and then corrected in one.
4. **Pick a workstream prefix that is not already taken.** Currently in use:
   `WS-G` (gooseworld), `WS-L` (Linux port), `WS-M` (Huginn MLX overhaul),
   `WS-MLX`, `WS-I` (Buzz interop), `WS-BM` (Buzz mobile), `WS-B`/`WS-C`/`WS-D`
   (tech-week), `WS-P` (two-app pair proof). Grep `DEVIATIONS.md` before minting a
   new one — `WS-M` was very nearly reused for two unrelated efforts.

## Currently in flight

| Plan | Owner | Exit condition |
|---|---|---|
| [`ELDR-BUZZ-MOBILE-RELAY.md`](ELDR-BUZZ-MOBILE-RELAY.md) | — | Phase 1 (WS-BM1–BM3) is **done and green** (AC147–AC153) but has never been run against a live Buzz relay or looked at on a device. The plan exits when Phase 2 (WS-BM4 secure plane, WS-BM5 agent control) lands in DEVIATIONS, or when the owner decides Phase 2/3 are not happening. |
| [`TWO-APP-PAIR-PROOF.md`](TWO-APP-PAIR-PROOF.md) (`WS-P`) | Auston | Nothing built. Every phone↔Mac proof today has a **simulated phone**. Exits when WS-P1 (real-socket `RelayACPHost` test) and WS-P2 (macOS XCUITest driving both real binaries over a live `pqrc-relay`) land in DEVIATIONS. WS-P3 is optional — declining it in the DEVIATIONS entry also exits the plan. |
