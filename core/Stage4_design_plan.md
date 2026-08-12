# Stage 4: Design & plan (form)

> Used as a prompt. Follow this structure to write the plan.
> **On fix-loop re-entry**: this form also applies to `fix_plan_{feature}_N.md`.

## Input
- **Stage 3 → Stage 4 bridge summary** — index only (read first).
- **Original survey** (latest revision wins) — **Read** the §s the summary lists.
- Fix-loop re-entry: the test result's **bug list** + Evaluator root-cause (same summary + original rule).

> ★ **Original-reference obligation**: do not plan from the summary alone. The listed original §s are mandatory reads.

## Output
- `${base_dir}/${DATE}/plan_{feature}.md`
- When promoted: `${base_dir}/${DATE}/design_{feature}.md` (see "Design section")
- Fix loop: `${base_dir}/${DATE}/fix_plan_{feature}_N.md`

> 🌐 **Authoring language (REQ-U-08)**: write these deliverables per SDP.md §"Deliverable authoring language" — English canonical (+ a synced `OUTPUT_LOCALE` copy when `output_locale: auto` and env locale ≠ en). Keep REQ-IDs, `ALLOW:`/`BLOCK:`, and `TEAM_*` markers ASCII.

## Method
Use parallel agents to analyze the survey by role, then synthesize the plan.

### Analysis agents
1. **Structure** (Explore / sonnet): target files/tables/APIs; dependency graph.
2. **Impact** (general-purpose / opus): blast radius over existing features/screens/batch/integrations.
3. **Risk** (general-purpose / opus): data migration, backward-compat, performance, security risks.

### Analysis criteria
- Cover every survey section.
- Per change item: [blast radius / difficulty (H/M/L) / risk (H/M/L)].
- ≥3 scenarios: normal + edge + rollback.

### Pre-checks (mandatory before implementation)
- DB consistency: added/changed columns vs existing data.
- Dependencies: is the target referenced by other modules?
- Conflict: is another in-progress task editing the same table/file?
- Library currency: for new external libs / major upgrades, confirm current API via `mcp__context7__*`.

### Cross-check
- Contrast agent results; find omissions, contradictions, underestimates.
- On disagreement, decide conservatively (safe direction) with a stated basis.

### Large-work extra verification
Size class comes from the SDP work-size matrix (files × impact — see SDP.md); this table only sets the **general-purpose verifier** count (a subset of the total agents in SDP.md's composition table, not the total).
| Size | Files (Impact Low; higher impact promotes a class) | general-purpose verifiers |
|------|-----|-----------|
| S | 1–3 | 0 |
| M | 4–10 | 0 |
| L | 10+ | 0 (verification folded into Evaluator + Bash) |
| XL | 10+ files **AND** Impact High | 4–6 |

For XL only, run the `general-purpose` verifiers in parallel over: feasibility, architecture, existing-code consistency, implementation completeness, security/compliance, performance/scalability. (Per SDP.md's composition: L folds verification into Evaluator 1 + Bash 2; M into the Evaluator; S is main-direct with an optional Evaluator.)

## Design section (REQ-D-01/02/03)
The plan carries a **design section, inline by default**. **Promote** it to a standalone `design_{feature}.md` + **one early design gate** when impact = High **or** blast-radius exceeded — where "blast-radius exceeded" means any of: a new module/service, a cross-cut touching **> 10 files** (SDP work-size class L), or a large brownfield delta. When trivial, write a one-line `design trivial: {reason}` (logged) — no promotion.

**Early design gate (only when promoted)**: run the gate on `design_{feature}.md` before writing the full plan, so a wrong design is caught early:
```bash
# $BASE_DIR and $DATE are recorded by sdp-anchor.sh in .sdp_runtime.env metadata; never source that file as shell code.
DESIGN="$BASE_DIR/$DATE/design_{feature}.md"
python3 scripts/review_gate.py --cwd "$PWD" --reviewer codex "Review the design at $DESIGN for architectural soundness, alternatives considered (ADRs), and high-impact/blast-radius risks. First line 'ALLOW: <summary>' or 'BLOCK: <reason>', no preamble. Every finding MUST comply with the 'BLOCK output contract' subsection of this stage document: all six fields (WHERE, WHY, FIX, VERIFY, SEVERITY, SCOPE), SCOPE being exactly one of closeable-in-this-dispatch or must-be-recorded-instead, any field you cannot supply labelled exactly 'INCOMPLETE - <field> not supplied because <reason>', and the verdict closing with CHECKED-AND-CLEAN and IF-ONLY-ADVISORY." "$DESIGN"
```
Verdict handling mirrors the plan gate below, except `BLOCK:` → revise **`design_{feature}.md`** (the full plan isn't written yet) and re-review. On `ALLOW:`, proceed to author the full plan (which still gets its own plan gate).

Record meaningful decisions as compact **ADRs** (REQ-D-03): decision + alternatives + rationale + status (proposed/accepted/superseded). Standalone ADR only when promoted.

## Plan document structure
```markdown
# Plan: {feature}
> Date: {YYYY-MM-DD} | based on survey

## 1. Change overview
- purpose, scope, preconditions

## 2. Design  ← inline by default; `design trivial: {reason}` or → design_{feature}.md when promoted
- key decisions + ADRs (decision / alternatives / rationale / status)
- **REQ→design matrix** (REQ-D-04): | REQ-ID | design decision / component addressing it |

## 3. Agent Team
| Stage | Agent | Type | Model | Role | Parallel/seq |

## 4. Impact matrix
| Target | Change | Blast radius | Difficulty | Risk |

## 5. Implementation order (dependency-based)
### Step 1: {name} — preconditions: none — files: …
### Step 2: {name} — preconditions: Step 1 done — files: …

## 6. Per-file change spec  ← REQ→file traceability (REQ-D-04): every changed file cites the REQ(s) it serves
| Path | Change type | Core change | REQ(s) |

## 7. DB changes
- tables/columns/migration (per `.sdp/project-rules.md` DB conventions)

## 8. Pre-check results
- DB consistency ✅/⚠️ · dependency conflict ✅/⚠️ · concurrent-work conflict ✅/⚠️

## 9. Test direction
- unit: service layer; integration: API + permission; manual: screen scenario

## 10. Rollback plan

## 11. Checklist (from `.sdp/project-rules.md` + normalize REQ coverage)
- [ ] all REQ-xxx from normalize reflected in §6 change spec?
- [ ] project-rules checklist items satisfied?
```

## Fix-plan extra sections (fix loop)
Prepend the mandatory SDP fix-plan header (matches SDP.md "Fix-plan header"):
````markdown
# Fix-plan: {feature} — iteration {N}
## Change history
| Iter | Defect | Fix direction | Blast radius |
## Prior test summary
- Previous result: {file}   ·   Bugs found: {count}
- This iteration targets: {list}   ·   Excluded (reason): {list}
````

## Stage 4 → Stage 5 bridge summary (≤500 chars) ★ required
Authored by the Planner; Stage 5 requires it as first input.
In the fix loop, "the plan" below is the **latest fix-plan** (`fix_plan_{feature}_N.md`), not the initial `plan_{feature}.md` — Stage 5 reimplements against the newest artifact ("latest wins").
````markdown
## 📎 Prior-stage summary (Stage 4 → Stage 5)
- **Prior output**: latest plan — `${base_dir}/${DATE}/plan_{feature}.md` (or `fix_plan_{feature}_N.md` in the fix loop; design promoted → also `design_{feature}.md`)
- **Key decisions**: 1. {N} change items across {files} 2. impact {Low/Medium/High} 3. gate `ALLOW:` obtained
- **Issues the next stage must address**: - {implementation-order dependencies} - {high-risk change items}
- **Required original sections** ★ (Read directly): the latest plan/fix-plan §5 (implementation order) · §6 (per-file change spec) · §7 (DB changes — when the order has a migration step) · §10 (rollback) · **fix loop: the Change-history header** (so Stage 5 changes only what it lists) · **promoted design: `design_{feature}.md`** (the architectural decisions to implement against)
- **Constraints/assumptions**: - {ADR decisions still open} - {off-plan changes require re-gate}
- **Summary limits ⚠️**: - {non-summarizable areas}
````

## review gate (mandatory on plan / fix-plan completion)

When the plan (or fix-plan) is done, print the summary block, then run the gate. **Do not embed gate logic — call the script.** All escalation/halt/resume/3-state logic lives in `scripts/review_gate.py` (see SDP.md "review gate").

### Summary block (print before running)
```markdown
---
## 🔒 review gate request
Reviewing the {plan/fix-plan} with review gate.
- **Changed files**: {N} (by area, where the project has them — absent surfaces drop, per Stage 3's lane-collapse)
- **Difficulty**: {H/M/L}   **Impact**: {Low/Medium/High}
- **Main risks**: {only those that apply — e.g. PII / DB schema / RBAC / crypto / audit-log / auth-session}
- **Migration**: {yes/no — file count} *(only if the project has a datastore)*
On ALLOW, start {implementation/reimplementation}.
---
```

### Run
The gate's **arg1 is the review PROMPT** (the instruction codex acts on); **arg2 is the artifact path** (its content is read size-capped, wrapped as untrusted data for the reviewer, and its path keys the gate state/log). Do NOT pass `@<artifact>` as arg1 — `@file` makes the gate load the prompt FROM that file, so the plan would become the instruction and the review dimensions would never reach codex. Replace placeholders, then:
```bash
PLAN="$BASE_DIR/$DATE/plan_{feature}.md"   # values read from anchor metadata, never sourced; fix loop: fix_plan_{feature}_N.md
python3 scripts/review_gate.py --cwd "$PWD" --reviewer codex "Review the plan at $PLAN against the SDP Stage-4 review dimensions (REQ coverage; high-impact omissions; survey reflected; security/compliance & invariants per .sdp/project-rules.md; scope appropriateness; project DB/domain consistency; project anti-patterns; excess agent permissions; unapproved external transmission; trust/untrust mixing). First line must be 'ALLOW: <summary>' or 'BLOCK: <reason>', no preamble. Every finding MUST comply with the 'BLOCK output contract' subsection of this stage document: all six fields (WHERE, WHY, FIX, VERIFY, SEVERITY, SCOPE), SCOPE being exactly one of closeable-in-this-dispatch or must-be-recorded-instead, any field you cannot supply labelled exactly 'INCOMPLETE - <field> not supplied because <reason>', and the verdict closing with CHECKED-AND-CLEAN and IF-ONLY-ADVISORY." "$PLAN"
```
The gate enforces a single wall budget of **550s** (`GATE_WALL_BUDGET`, ADR-008) across the Claude review + agy fallback — one monotonic deadline, not two independent caps. Per-provider caps default to 300s and are read from `gates.yaml` (`claude_timeout` / `agy_timeout`), never the environment; each provider receives `min(configured, remaining_budget − drain)`. The MCP `tool_timeout_sec` (660s) is the outer host ceiling (550 + drain < 660 < the Bash-tool `600000ms` hard max). A genuinely slow gate hits the wall budget and surfaces as `INFRA_ERROR` (3-state: attended may advance, MERGE/PUSH blocked; agy fallback / fail-close underneath).

### Review dimensions (the gate's prompt — de-domained)
The gate reviews the artifact for:
1. **REQ coverage** — every REQ-xxx from normalize maps to a §6 change-spec entry.
2. **High-impact omissions** — PII store/read/decrypt · DB schema · RBAC/data-scope · crypto grade/key/secret-store · audit/transaction log · auth/session/CSRF · regulatory rules.
3. **Survey not reflected** — Stage 3 findings ignored.
4. **Security/compliance risk** — per `.sdp/project-rules.md` invariants and any project rule docs.
5. **Scope appropriateness** — change absent from the plan, or a co-edit region the plan missed.
6. **Project DB/domain consistency** — per `.sdp/project-rules.md` (DB syntax, key columns, migration naming, permission inserts).
7. **Project anti-patterns** — the "repeated-mistake" list in `.sdp/project-rules.md`.
8. **Excess agent permissions** — plan §6 explicitly grants a feature/agent more access/execution than needed (BLOCK only when clearly designed in).
9. **Unapproved external transmission** — plan §6 sends/exfiltrates data to an external system/network with no human-approval step (BLOCK only when clearly designed in).
10. **Trust/untrust mixing** — plan §6 treats external untrusted input with the same authority as system instructions/trusted data (BLOCK only when clearly designed in).
11. **Invariant/rule non-compliance** — plan violates `.sdp/project-rules.md` invariants or project rule docs.

> Dimensions 8–10 are generic security invariants (keep for every project). 1–7 and 11 lean on `.sdp/project-rules.md` for project specifics.

### BLOCK output contract

**Every finding a `BLOCK:` verdict reports MUST carry all six fields:**
- **WHERE** — section / ADR / `file:line`, **plus the offending text quoted verbatim**.
- **WHY** — the defect, **naming and quoting any contradicted site**.
- **FIX** — **actual replacement text**, or the function and line for code. *"Clarify X" is not a fix.*
- **VERIFY** — a runnable `grep`/command, or the exact sentence that must now read differently.
- **SEVERITY** — `blocking` | `advisory`.
- **SCOPE** — `closeable-in-this-dispatch` | `must-be-recorded-instead`.

**A finding missing any field MUST be labelled exactly `INCOMPLETE - <field> not supplied because <reason>`; no field may be omitted silently.**

The verdict MUST also close with:
- **`CHECKED-AND-CLEAN`** — what was examined and found sound, so the next round does not re-litigate it.
- **`IF-ONLY-ADVISORY`** — what the verdict would be if every `blocking` finding were resolved and only the `advisory` ones remained.

**`SEVERITY` and `SCOPE` are fixed-value enums, not free text.** `closeable-in-this-dispatch` means the finding must be fixed in this dispatch; `must-be-recorded-instead` means it belongs in the non-conformance register rather than in a new mechanism. Free-form coverage prose does not satisfy this contract — unranked findings are how one mechanism per finding gets built, and each such mechanism becomes the next round's defect. The `INCOMPLETE` form is likewise exact: a bare `INCOMPLETE` loses both which field is missing and why.

### Verdict handling
- `ALLOW:` → next stage.
- **Before re-submitting, sweep the artifact for the claim you just retracted.** Accepting a
  finding and editing one place leaves the same claim standing in that section's heading, in a
  summary table, or in a downstream reference — and the next round blocks on the copy. In the
  one convergence run measured, 4 of 31 objections (13%) were exactly this, and they recurred
  even after the pattern was known. `grep` the retracted phrase across the whole artifact and
  fix every hit before re-running the gate. This costs seconds and needs no model.
- `BLOCK:` → reflect findings, revise the plan, re-review. **First test the line for the `INFRA_ERROR` token** — the gate emits infra failures as `BLOCK: INFRA_ERROR (…)` (exit 1, same as a content block), so treat those via the `INFRA_ERROR` rule below, not as a content revision (else you revise the plan forever).
- Escalation is automatic in the gate: from cumulative BLOCK `cadence.escalate_from` onward, a valid marker must be recorded in the gate log (roster ≥2 distinct, `TEAM_REVIEW` cites fresh `outputs=`). One marker covers `cadence.marker_span` consecutive rounds (default 1); the **window anchor's** parity — not the live round's — selects `TEAM_REVIEW` (even) / `TEAM_CARRY` (odd) under `review_on: even`. **Do not skip the team step or substitute planner-solo to save cost — the cost/continue call is the user's, not the model's.** Record the marker with `review_gate.py prepare-marker <artifact>` and hand the request file to the human; `record-marker` is the only command that writes it and it refuses without a terminal and a token. `.halt` (repeated BLOCK / max_block / repeated escalation stalls) → stop and report; no retry until the user clears it.
- `INFRA_ERROR` (tooling down/timeout/empty/invalid) → **attended**: the stage MAY advance, but MERGE/PUSH is refused until a clean `ALLOW:` clears the infra flag; **unattended**: pause + notify. (Matches `scripts/review_gate.py` + `.sdp/gates.yaml infra_error_policy`; see SDP.md 3-state rules.) Do not treat it as a plain "cannot proceed".

## Source-citation rule
Inline-cite every design judgment:
```
> 📎 basis: `{doc path}` — {section/rule summary}
> 📎 basis: normalize_{feature}.md — REQ-003 (maps raw "auto-send")
> 📎 basis: `.sdp/project-rules.md` — audit/transaction-log requirement
> 📎 basis: context7 — {library}@{version}
```
