# SDP — Stage 4: Design & Implementation Plan

| Field | Value |
|---|---|
| Date | 2026-07-03 |
| Inputs | Requirements `…requirements_definition_EN.md` (v1.0), feasibility review, §14 decisions (all settled) |
| Scope | Build the `sdp` plugin: shared SDP core + `codex-gate.sh` + 3 commands + config schema |
| Detail level | Developer-readable (REQ-D-05) — decisions + structure + file map + order. Not exhaustive. |
| Gate | Gate A (codex plan review) to run on this doc before implementation |

> **Redaction note (open-source release)**: the six private source repositories SDP was extracted from are redacted as **Project-A … Project-F**. Nothing else is altered.

---

## 1. Architecture at a glance

```
Marketplace plugin  sdp/
  .claude-plugin/plugin.json            manifest
  commands/  sdp.md · batch-sdp.md · worktree-dispatch.md    ← thin dispatch adapters
  core/      SDP.md + Stage1..8.md      ← de-domained SDP core (read-only)
  scripts/   codex-gate.sh · agy-gate-fallback.sh · run_segment_tmux.sh · sdp-anchor.sh
  skills/    shared skill (bundled — not optional; within-plugin ref)

Project (thin, injected):
  .sdp/defaults.yaml   base_dir, build.*, test.*, output_locale, sdp_version, forced_ext
  .sdp/gates.yaml      roster names, cadence, halt thresholds, review_checklist_include
  .sdp/project-rules.md    domain sentences pulled out of the old core (REQUIRED before a project deletes its old core — else gate weakens)
  .gitignore               .private/  (auto-registered)
```

> **Naming**: plugin core dir = `core/` with master file `SDP.md`; project config = `.sdp/defaults.yaml` + `.sdp/gates.yaml`. Legacy `scripts/sop/`, `/sop`, `/batch-sop` below name the *existing* systems being replaced — kept factual (not renamed).

**Flow**: a command runs `sdp-anchor.sh` → resolves `SDP_ROOT`, `base_dir`, `output_locale` → writes `${base_dir}/.sdp_runtime.env`. Every Stage template and `codex-gate.sh` reads that file. No reliance on `${CLAUDE_PLUGIN_ROOT}` propagating into body bash.

---

## 2. Design decisions (settled)

| # | Decision | Why |
|---|---|---|
| A1 | One SDP core, 3 command adapters call it | Single source; no 6-copy drift |
| A2 | Config-key references only in core (`${build.*}`, `${base_dir}`, `${test.*}`) | Language-agnostic (REQ-U-01) |
| A3 | Anchoring file `.sdp_runtime.env` | `${CLAUDE_PLUGIN_ROOT}` not reliable in body bash (4.9) |
| A4 | `codex-gate.sh` = single script, plugin only calls it | Works with/without plugin (REQ-G-01) |
| A5 | Gate tiers: companion → raw `codex exec` → agy → Fail-Close | Raw tier is the new work (REQ-G-02); companion kept optional (D-13) |
| A6 | Escalation markers even=`TEAM_REVIEW` / odd=`TEAM_CARRY`, planner-solo blocked 6+ | User req #6, D-08 |
| A7 | Deliverables English-canonical + locale sync copy | D-16 / REQ-U-08 |
| A8 | base_dir default `.private/sdp-artifacts`, auto-create + gitignore | D-04 / REQ-U-06/07 |
| A9 | worktree-dispatch `dispatch_mode: manual\|auto`; auto = tmux headless auto-launch (no manual paste) with classifier fallback + runtime-isolation guard | User req / REQ-C-07 |

---

## 3. Components

### 3.1 Manifests
`plugin.json`: `name: sdp`, `version`, `description`, `commands: ["./commands/*.md"]`, `scripts` dir. `marketplace.json`: `plugins[].source: ./sdp`. Everything vendored inside the plugin (REQ-P-04) — no cross-plugin symlinks.

### 3.2 Anchoring — `sdp-anchor.sh`
Resolves and writes one env file, sourced by everything downstream:
```
# ${base_dir}/.sdp_runtime.env
SDP_ROOT=/abs/path/to/plugin
SDP_CORE=$SDP_ROOT/core
SDP_SCRIPTS=$SDP_ROOT/scripts
BASE_DIR=/abs/project/.private/sdp-artifacts
DATE=2026-07-03
OUTPUT_LOCALE=ko            # resolved: config → LC_ALL/LANG → en
```
Also: `mkdir -p` base_dir; if `.private` absent → create + append `.private/` to `.gitignore` (idempotent, REQ-U-07).

### 3.3 Config schema (3 files, key list)
`defaults.yaml` — 2-layer merge (base safety keys common; `forced_ext` project-added, never weakens base):
```yaml
base_dir: .private/sdp-artifacts
output_locale: auto
sdp_version: "1.0"
build:   { install, build, lint, typecheck }     # opaque strings
test:    { commands:{...}, layers:{...}, runtime:{...}, db:{...}, guards:{...}, worktree:{...}, risk_globs:{...} }
migrate: { create, apply_local, prod_block: true }
forced_ext: { ... }                               # domain rules (extend only)
```
`gates.yaml` — gate/escalation externalized (code checks only cardinality/parity):
```yaml
model: ""                        # CODEX_GATE_MODEL; empty = codex default
roster_pool: [planner, evaluator, researcher, architect]
cadence: { escalate_from: 6, review_on: even, carry_on: odd }
halt: { max_block: 13, pivot_cap: 2 }             # 12th review executes, halt on 13th (D-07)
require_checklist: false         # migrated-off-old-core projects set true → absent/empty include BLOCKs
# review_checklist_include: .sdp/project-rules.md   # OPTIONAL — set only if the file exists (else gate BLOCKs)
infra_error_policy: { attended: warn_flag_continue, unattended: pause_notify }
```

### 3.4 `codex-gate.sh` — the gate
Port the existing Project-A gate bash; **keep** the proven machinery, **change** three things.

Keep: GATE_LOG `BLOCK_COUNT` (RESET/BLOCK_ATTEMPT awk), halt/override, 4-tuple thread stash + `flock` + 24h TTL, resume-failure-by-stderr, first-line `ALLOW:`/`BLOCK:` awk parse.

Change:
1. **Remove** the node companion version-scan (lines 168–186) → tiered verdict engine `run_codex()`:
   ```
   run_codex(prompt, resume_id?):
     [resume_id]  → codex exec resume "$resume_id" "$prompt" -o OUT   (never --last)
     [fresh]      tier1 companion  (if command present, optional accelerator)
                  tier2 raw:  codex exec --json --skip-git-repo-check -s read-only \
                              [-m $CODEX_GATE_MODEL] -o OUT "$prompt"
                              → capture thread_id from --json {"type":"thread.started"}
                              → verdict from OUT only (awk); --json JSONL never the verdict basis
                  tier3 agy_or_block ; tier4 Fail-Close
     verdict path = POSIX awk/grep only (node lives only in optional companion)
   ```
2. **De-domain the PROMPT**: core keeps universal items (REQ coverage · current-state reflection · scope match · over-permission · unauthorized external send · trust-boundary · secret/PII baseline). Domain items (MariaDB/lombok/@DataScopeFilter/INVARIANTS) come from `review_checklist_include`.
3. **Paths** the legacy dated deliverable directory → `${BASE_DIR}/${DATE}/gate/` from `.sdp_runtime.env`; thread-file name includes a `pwd` hash (REQ-G-04, worktree git-dir sharing).

**Verdict states (REQ-G-06)** — three outcomes drive the exit + escalation:
```
ALLOW        → log RESET+ALLOW, clear thread stash, exit 0
BLOCK        → log BLOCK_ATTEMPT, update stash, exit 1  (counts toward escalation)
INFRA_ERROR  → codex+agy both unavailable | timeout | empty | invalid schema
             → does NOT increment BLOCK_COUNT (separate from genuine BLOCK)
             → policy from gates.yaml.infra_error_policy. Two levels, kept distinct:
                 attended  = warn + write infra_flag, exit 0 → the CURRENT STAGE may advance,
                             but MERGE/PUSH is refused while the flag exists
                 unattended= exit 1 + pause/notify (never auto-advance)
             → the infra_flag gates INTEGRATION only (not stage progress); a clean ALLOW re-run clears it
```
**read-only inheritance**: `resume` has no `-s`; fix read-only in the fresh call and inherit, or `-c sandbox_mode=read-only` on resume. Gate never writes the repo.

**Structured verdict + schema (REQ-G-05)**: the raw tier may pass `--output-schema $SDP_SCRIPTS/gate.schema.json`; the verdict object `{verdict, reason, findings[]}` is read from OUT and the first `ALLOW:`/`BLOCK:` line is echoed for humans. **OUT not valid JSON / schema mismatch → INFRA_ERROR** — this is precisely how schema violations are classified (not a false BLOCK).

**Fail-closed inputs**: if `review_checklist_include` is **set**, it must point to a non-empty existing file — missing/empty → the gate **BLOCKs**. If the key is **absent**, the core minimal security baseline (REQ-U-03) applies; a project migrated off an old domain core sets `gate.require_checklist: true`, which turns an absent/empty include into a **BLOCK** — this closes the "silent skip" gap (AC-12) without breaking simple/serviceless projects that legitimately have no domain checklist.

**INFRA_ERROR enforcement point**: on INFRA_ERROR write `${BASE_DIR}/gate/<artifact>.infra_flag`; a command's advance/merge step refuses to proceed while the flag exists; a clean `ALLOW` re-run clears it. This is the concrete "merge refused until real ALLOW" hook.

Ship `codex-gate.sh doctor` + companion on/off parity smoke (REQ-G-08).

### 3.5 Escalation state machine
Replace the `CONSENSUS_REACHED` block with parity logic (reads `gates.yaml`). **Order matters** — checks run top-to-bottom on entry, BLOCK_COUNT = cumulative BLOCKs so far:
```
1. same BLOCK first-line twice in a row      → .halt (stuck)
2. BLOCK_COUNT >= max_block(13)              → .halt   # 12 still enters → the 12th (even) TEAM_REVIEW executes; 13th entry halts
3. BLOCK_COUNT >= escalate_from(6):
     need   = (BLOCK_COUNT even) ? TEAM_REVIEW : TEAM_CARRY   # 6,8,10,12=review ; 7,9,11=carry
     marker = last team marker after the last BLOCK_ATTEMPT
     guard(awk):  marker.kind == need
              AND count(split(roster, ",")) >= 2
              AND roster has no duplicates AND not planner-solo   # forgery: reject dup/fake roster
              AND for each path in the marker's outputs= field: file exists, mtime > last BLOCK_ATTEMPT, paths distinct (REQ-E-05)
     fail → BLOCK "planner-solo forbidden / team review not performed / marker invalid"
4. pivot: a TEAM_REVIEW with decision=pivot may RESET the counter, max pivot_cap(2) resets total
```
Forgery note: this is honor+verification (the shell can't see real agent runs); the output-path checks raise the bar but cannot fully prevent a fabricated marker — stated, not claimed solved.
Marker grammar:
```
TEAM_REVIEW <ISO> round=<n> roster=<a,b,..> outputs=<p1,p2,..> added=.. removed=.. rootcause=.. decision=<continue|pivot|halt> summary=..
TEAM_CARRY  <ISO> round=<n> roster=<a,b,..>
```
Per-artifact GATE_LOG keying → parallel batch/worktree counters stay independent (REQ-C-06); a global concurrency cap lives in the dispatch adapters (REQ-E-08).

### 3.6 Stage renumber + de-domaining map
Rename + de-domain in one pass. "De-domain" = replace stack/DB literals with `${config}` refs or move domain sentences to `.sdp/project-rules.md`.

| New file | From | Domain hits | Action |
|---|---|---|---|
| Stage1_interview.md | Phase0_0 | 0 | rename only |
| Stage2_normalize.md | Phase0_5 | 6 | `${build}`/base_dir refs |
| Stage3_current_state.md | Phase1 | 5 | refs |
| Stage4_design_plan.md | Phase2 | 16 | + design section (REQ-D-01); PROMPT de-domained; gate refs |
| Stage5_implement.md | Phase3 | 5 | refs |
| Stage6_test_plan.md | Phase4 | 7 | `${test.*}` refs |
| Stage7_test_exec.md | Phase5 | 19 | `${test.*}`/DB-guard refs; heaviest |
| Stage8_verification.md | Phase6 | 2 | generic name; screen-test = T2/T3 sub-tier |
| SDP.md | Project-A SOP.md | 16 | strip the project-specific domain literals → project-rules.md; renumber |

**Stage 4 authoring rules** (emitted by `Stage4_design_plan.md` at runtime): design section is inline by default; **promote** to a standalone `design_{feature}.md` + **one early design gate** when impact=High OR blast-radius exceeded (new module/service, cross-cut beyond N files, large brownfield delta) — REQ-D-02; when trivial, a one-line `design trivial: {reason}` (logged). Meaningful decisions are recorded as compact **ADRs** (decision + alternatives + rationale + status: proposed/accepted/superseded), standalone only when promoted — REQ-D-03.

### 3.7 i18n — output_locale
Anchoring resolves `OUTPUT_LOCALE`. Authoring rule (in Stage templates, prompt-level not code): write the **English canonical** deliverable first; if `OUTPUT_LOCALE != en` and mode `auto`, also emit a synced copy `name.<locale>.md`, kept in sync. Machine tokens (`ALLOW:`/markers/REQ-IDs/keys) stay ASCII. Detection failure → English, never blocks (NFR-08).

### 3.8 Command adapters (skeletons)
- `sdp.md` — anchor → run Stage 1–8 inline; small-task fast-path (skip design doc, collapse stages).
- `batch-sdp.md` — anchor → split scope → per-segment full SDP-flow via engine adapter (`agent_tool` default / `tmux_long_lived` opt-in); unattended 4-charter; global concurrency cap.
- `worktree-dispatch.md` — anchor → Stage 1 only with user → per-task handover; sessions run full SDP-flow in worktrees, produce checklists only (no screen test); main merges + screen-tests serially. Port the existing Project-F command's invariants verbatim.
  - **Shared-surface contract (REQ-C-05)**: before dispatch, main writes once a design skeleton / data-model contract covering only shared surfaces (schema · shared modules · trust boundaries) into each handover; each session designs task-local beneath it → parallel worktrees can't diverge on shared schema/modules.
  - **`dispatch_mode: manual | auto` (REQ-C-07, default `manual` per D-17)**: `manual` = print handover, user opens+pastes (today). `auto` = main auto-launches each task via `run_segment_tmux.sh` (`git worktree add` → tmux `claude --permission-mode bypassPermissions` in the worktree → inject handover → §0-A unattended full SDP-flow → completion record to main `base_dir` → incremental integration trigger). **Guards**: (a) if the project's codex auto-mode classifier blocks headless/tmux/bypass loops (§4.6), fall back to `manual`/`agent_tool`; (b) runtime-touching stages need `ephemeral_per_worktree` else stay checklist-only + main serial; (c) one-time `bypassPermissions` grant + K-cap + hard deadline + kill switch (reuse the watcher safety pattern). Gate strength identical to manual.

### 3.9 Cross-cutting safety (NFR)
- **No-weakening base keys** (REQ-U-04): the config loader rejects a `forced_ext` that turns a base safety key off; base keys may only strengthen.
- **Audit log** (NFR-04): `codex-gate.sh` appends NDJSON `{ts, artifact, tier, verdict, provider, version, round}` to `${BASE_DIR}/gate-audit.ndjson` — replay + provider-drift detection.
- **Resource caps** (NFR-05): per-task token/time hard cap in the dispatch adapters + escalation halt (12th review executes, 13th entry halts) + global concurrency cap → no runaway unattended burn.
- **Session retention** (NFR-06): resume rollouts stay non-ephemeral; document cleanup policy for accumulated sessions.

---

## 4. Implementation plan (order)

| Step | Work | Verifies |
|---|---|---|
| 1 | Plugin skeleton + `plugin.json`/`marketplace.json` + `sdp-anchor.sh` (+ .private/gitignore) | AC-13 |
| 2 | **Config: 3 files + 2-layer merge + discovery order + no-weakening loader** (must precede gate — gate reads `gates.yaml`) | AC-02 |
| 3 | `codex-gate.sh`: port + remove version-scan + raw fresh tier + INFRA_ERROR branch + read-only inheritance + doctor | AC-03·04 |
| 4 | De-domain PROMPT + `review_checklist_include` wiring | AC-02 |
| 5 | Escalation parity (halt-first order, even/odd, planner-solo + forgery checks, halt=13, pivot cap) | AC-05·06 |
| 6 | Stage renumber + de-domain SDP.md/Stage1–8 (file map §3.6) | AC-02·12 |
| 7 | i18n canonical+sync authoring rule | AC-14 |
| 8 | 3 command adapters (incl. worktree `dispatch_mode: auto`) | AC-01·10 |
| 9 | Test config (`test.*`) + real-world exec + DB guard + teardown | AC-08·09 |
| 10 | Cross-cutting safety (audit log, caps, retention) + 6-project regression harness | AC-12 |

Concurrency: step 2 (config) first — gate depends on it; then steps 3–5 (gate/escalation) as one tight unit (dogfoods itself); 6 (de-domain) after.

---

## 5. Test plan seed

- **Gate**: contract smoke (`ALLOW:`/`BLOCK:` + exit); companion-off parity; concurrent same-cwd UUID isolation; escalation rounds 6/7/8/12/13; planner-solo refusal.
- **De-domain**: grep core for stack literals = 0; 6-project regression (install plugin, `scripts/sop/` deleted, run each command, confirm no gate-strength loss).
- **i18n**: `LANG=ko` → EN canonical + `.ko.md` sync; markers ASCII.
- **Real-world**: smoke+integration against a live local DB per `test.*`; prod-DSN abort; `down -v` refused in `dedicated_test_db`.
- Layer: mandatory floor = smoke + integration on a real backing service (not mock), run against **local DB/server** or a designated test DB/server (REQ-T-01).
- **Tier scoping**: T1 (i18n/color/copy/label) exempt from the floor (REQ-T-02); serviceless projects satisfy "real-world" via real FS/subprocess/self-hosted local HTTP (REQ-T-03).
- **Flake + evidence**: infra-flake vs real-fail split, retry+quarantine, only real FAIL BLOCKs (REQ-T-09); results carry the evidence appendix — command + exit code + service log tail + DB connection/query count (REQ-T-10).

---

## 6. Traceability (REQ → component)

> §6 is a **component→REQ** map. The 4-hop **REQ→design element→file→test** matrix (REQ-D-04) is not this meta-doc — it is an artifact the **Stage 4 template produces at runtime** for each feature; here we only require the template to emit it.

| Component | REQ |
|---|---|
| Manifest/anchoring | REQ-P-01~05, U-05~07 |
| Config schema + no-weakening loader | REQ-U-04, P-05 |
| codex-gate.sh (INFRA_ERROR, read-only, output-schema, fail-closed include) | REQ-G-01~09, U-03 |
| Escalation (forgery via outputs=, halt order) | REQ-E-01~08 |
| Stage 4 design section (design-led; emits the REQ-D-04 4-hop matrix at runtime) | REQ-D-01~05 |
| Stage renumber/de-domain | REQ-S, U-01~02, D-01 |
| i18n | REQ-U-08, NFR-08 |
| Commands (+ worktree auto) | REQ-C-01~07 |
| Test config | REQ-T-01~11 |
| POSIX-only verdict path / portability / safe defaults / regression | NFR-01, NFR-02, NFR-03, NFR-07 |
| Cross-cutting safety (audit log, caps, retention) | NFR-04~06 |

> R-01~02 (prior-art citations, enhancement roadmap) are supporting documentation, not a build component — carried in the requirements doc §13.

---

## 7. Risks

- **Gate port fidelity** — the trap/stash discipline is subtle; a dropped `trap - EXIT` loses threads. Port line-by-line, keep the parity smoke.
- **Companion parity** — raw and companion verdicts must match format; regression test both (D-13).
- **De-domaining regression** — moving domain checks out could weaken a project's gate; each project must fill `review_checklist_include` before its old core is deleted (AC-12).
- **i18n is prompt-level** — sync drift possible; treat the English copy as source of truth.

---

### Status
**Gate A: ALLOW** (codex, round 4 — the raw `codex exec` path itself, dogfooding REQ-G-02/AC-03; BLOCK→revise loop 12→5→4→ALLOW). Ready to implement in the §4 order. Detail kept at the REQ-D-05 ceiling; deeper specifics live in code + inline comments, not here.
