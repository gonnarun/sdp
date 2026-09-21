# Measurements behind the gate/artifact rules

Dated evidence, kept OUT of the stage documents on purpose: a number embedded in an
instruction is re-read on every dispatch, costs tokens forever, and goes stale silently.
Stage documents carry the rule; this file carries the reason and the date.

## 2026-09-18 — artifact size tracks BLOCK count; the difficulty proxy does not explain it

**Cohort.** One repository, 2026-07-09 → 2026-09-18: 9,172 tracked files (~88,400 on disk),
1,206 commits, 782 gate verdicts (BLOCK 545 / ALLOW 178 / INFRA_ERROR 34 / MARKER 23 / SPLIT 2),
461 stage artifacts over ~66 dispatches. n=130 artifacts matched to ledger rows.

**Method.** Artifact size = file size on disk. Difficulty proxy = production LOC changed
(artifacts excluded) in a ±2-day window around the artifact's first verdict. Stratified by
difficulty tertile. SDP/non-SDP attribution is DAY-LEVEL (a day with any gate verdict), which
is the weakest link in the design.

**Results.**
- corr(BLOCK count, final size) = 0.577 overall; 0.744 early half, 0.658 recent half
- corr(difficulty, size) = 0.038 · corr(difficulty, BLOCK) = -0.019
- within difficulty tertiles: 0.672 / 0.609 / 0.694
- median size: 8.5KB at BLOCK=0 vs 61.6KB at BLOCK≥3 (7.2x)
- by kind: testresult 0.844, design 0.464, plan 0.391
- artifact kinds, first half → last half: design 76→173KB, plan 21→58KB, testplan 7→29KB,
  testresult 10→33KB; survey citations of prior artifacts 1.8 → 5.2

**Strength of the difficulty control.** Difficulty is proxied by production LOC changed in a
±2-day window. That is a coarse stand-in: it does not capture conceptual difficulty, and a low
correlation with it does not prove difficulty is irrelevant — only that this proxy does not
explain the size.

**What this supports.** The rule that an author answers a BLOCK by replacing, not appending
(the "BLOCK response contract" in Stage 4 and Stage 7).

**What it does NOT support.** Direction of causation. No revision history of an artifact
survives (the artifact directory is gitignored) and the ledger carried no size or digest, so
whether bytes arrived before or after a given BLOCK is unknowable retrospectively. That gap is
why `artifact_bytes` / `artifact_sha256` were added to the ledger; the question becomes
answerable only for verdicts recorded after that change.

## 2026-09-18 — the three reported pains, against what the proxies can actually say

- **"every dispatch amplifies files"** — no increase observed IN A DAY-LEVEL PROXY. Day-level
  attribution cannot decide a per-dispatch claim at all; it can only say the days that carried
  gate activity did not show the higher growth. Production churn, artifacts excluded:
  SDP days add:delete 22.6 (9.5 with ≥10-file commits removed) vs non-SDP days 58.6 (26.8).
  Largest commits average 21 added files on SDP days vs 38 off them.
- **"testing stays shallow"** — NOT MEASURED. Nothing here measures test depth; what is measured
  is whether tests are touched at all, which is a different question. On that proxy:
  existing tests are modified 1.5x more often
  than new ones are added (testM 1152 vs testA 745); 82.3% of production commits carry a test
  change and 69.0% modify an existing test; 87.3% of fix commits carry a test change.
  Weak residual signal: test files over 400 LOC have assertion density 7.64/100 LOC against a
  8.47 baseline.
- **"the next dispatch costs more"** — indirect signals CONSISTENT with it: artifacts grew
  2.3-3.9x by kind and survey citations of prior artifacts went 1.8 -> 5.2. No token or cost
  measurement was taken, so the cost itself is inferred, not observed.

**Caveats that bound all three.** Day-level attribution mixes unrelated commits; "fix" is
detected from commit subjects, so a workflow that labels fixes more diligently will look worse;
the 30-day recurrence window lets one fix attach to several prior changes. Defect recurrence
specifically was inconclusive: between-file comparison showed SDP +3.8 to +4.3pt (windows
7/14/30, stratified on PRE-exposure churn), while within-file comparison across the 437 files
that saw both paths showed −0.2pt (higher on 64 files, lower on 62). Not settled either way.

**"Not observed" is not "no effect", and "not measured" is not "fine".** Two of these three
lines rest on proxies that cannot carry the claim they are answering. Settling any of it needs
run→commit attribution and a token/cost measurement, neither of which exists today.
