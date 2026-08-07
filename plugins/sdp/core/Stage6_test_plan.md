# Stage 6: Test plan (form)

> Used as a prompt. Follow this structure to write the test plan.
> **Shape**: Step 1 (parallel analysis agents) → Step 2 (Planner REQ-coverage check — every REQ-xxx in normalize is a test target).

## Input
- **Stage 5 → Stage 6 bridge summary** — index only (read first).
- **Original artifacts** — **Read** the §s the summary lists:
  - Survey (esp. §3 files, §8 REQ matrix)
  - Plan (or fix_plan_N) (esp. §6 per-file change spec)
  - **normalize_{feature}.md** (REQ coverage is mandatory)
  - **actual implemented code** — plan and reality may differ; Read directly
- Latest revision wins.

> ★ **Original-reference obligation**: test cases cannot be derived from the summary alone. The real code and REQ list are mandatory reads.

## Output
- `${base_dir}/${DATE}/testplan_{feature}.md`
- Fix loop: `${base_dir}/${DATE}/testplan_{feature}_N.md`

> 🌐 **Authoring language (REQ-U-08)**: write this deliverable per SDP.md §"Deliverable authoring language" — English canonical (+ a synced `OUTPUT_LOCALE` copy when `output_locale: auto` and env locale ≠ en). Keep REQ-IDs, `ALLOW:`/`BLOCK:`, and `TEAM_*` markers ASCII.

## Method
**Two-step pipeline**: parallel analysis → Planner REQ-coverage check.

### Step 1: analysis agents (parallel)
1. **Code analysis** (Explore / sonnet): read changed files; derive branches, exceptions, boundary values.
2. **Plan diff** (general-purpose / opus): differences between plan and actual implementation.
3. **Rule check** (general-purpose / sonnet): compliance with the project checklist in `.sdp/project-rules.md`.
4. **CI/CD impact** (Explore / haiku): from the changed-file list, decide the CI/CD verification scope.

### Step 2: Planner REQ-coverage check
Planner takes Step 1 + normalize and:
1. Builds a **REQ → test-case matrix**.
2. Confirms each REQ-xxx maps to ≥1 test case.
3. On an unmapped REQ: **propose** an added test case (right layer) and record the reason.
4. Final verdict on whether the plan **verifies all requirements** — PASS / INCOMPLETE.
5. If INCOMPLETE: record which REQ is hard to verify and why. **INCOMPLETE does not silently advance** — a `Must`-priority REQ left uncovered blocks progression to Stage 7: add a case, or (**attended only**) record an explicit user waiver in §9. **Unattended: no waiver is possible — an uncovered `Must` REQ is a hard stop** (pause + notify). Only `Should`/`Hold` REQs may proceed as INCOMPLETE with the gap documented. This keeps REQ coverage satisfiable downstream.

### Planner input prompt (template)
```
You are the Stage 6 test-plan scope-verification owner of the SDP workflow.

[Input 1: normalize] {REQ list}
[Input 2: analysis] code (branches/boundaries) / plan-diff / rule-check / CI-CD impact
[Input 3: test-plan draft] {draft from Step 1}

[Requirements]
1. Build REQ → test-case matrix (test-plan §9).
2. Propose added cases for unmapped REQs (unit/integration/screen layer).
3. Final verdict: PASS / INCOMPLETE.
4. If INCOMPLETE, record reason + workaround.
```

## Test-plan document structure
````markdown
# Test plan: {feature}
> Date: {YYYY-MM-DD} | based on plan + actual code | Planner scope-check included

## 0. Stage 5 → Stage 6 bridge summary (≤500 chars)
{summary block}

## 1. CI pre-check (every time, mandatory) — run only non-empty refs; record empty ones as "skipped (not configured)"
- Build/compile: `${build.build}` (skip if empty)
- Lint: `${build.lint}` (+ `${build.typecheck}` if set; skip if empty)
- DB/schema consistency: {project schema check from `.sdp/project-rules.md`, if any}
- **On CI failure, do not proceed.**

## 2. CD pre-check (only when related changes exist)
- Determine via diff which of these changed; verify only changed items (details in `.sdp/project-rules.md`):
  - container build/compose → build & boot
  - reverse-proxy config → syntax check
  - app config / profiles → per-profile boot
  - migration added → order & syntax
  - env vars / secret-store paths → missing-reference check
- If none changed, record "no CD-related change — skip".

## 3. Unit test cases — a `supporting` layer under `test.layers` (object: `mandatory`/`risk_gated`/`supporting`)
| ID | Target method | Scenario | Input | Expected | Type | REQ |
|----|---------------|----------|-------|----------|------|-----|
| UT-001 | | normal | | | normal | REQ-001 |
| UT-002 | | exception | | | exception | REQ-001 |
| UT-003 | | boundary | | | boundary | REQ-002 |

## 4. Integration & mandatory-layer cases — run every layer in `test.layers.mandatory` (e.g. `${test.commands.smoke}`, `${test.commands.integration}`), not just integration
> **Risk-gated layers**: when normalize §6 Impact = High (or blast-radius exceeded), also schedule every layer in `test.layers.risk_gated` (e.g. e2e/contract) — these exist specifically to cover high-risk changes and are otherwise skipped. Record them in §9 coverage; Stage 7 must execute and the gate must see their results.
> **Unmapped layer = not configured**: a layer name with **no matching `test.commands.<layer>`** is recorded as "skipped (not configured)" (same escape as an empty `build.*` ref) — it does not force a FAIL. A project that wants a risk_gated layer enforced must define both the layer name **and** its `test.commands` entry.
| ID | API | Scenario | Permission | Expected | REQ |
|----|-----|----------|-----------|----------|-----|
| IT-001 | | | | | |

## 5. Screen test scenarios
| ID | Screen | Action | Expected | REQ |
|----|--------|--------|----------|-----|
| ST-001 | | | | |

## 6. Data verification (only if the project has a datastore)
- Persisted-state confirmation via the project's data-verification method (SQL query, API read-back, file check — per `.sdp/project-rules.md`); audit/transaction-log entries where the project has them (isolation: `${test.db.isolation}`)

## 7. Regression
- affected existing features

## 8. Edge cases
- concurrency, bulk data, permission boundaries

## 9. REQ coverage matrix ★ required
| REQ-ID | Requirement | Mapped test cases | Coverage |
|--------|-------------|-------------------|----------|
| REQ-001 | audit-log on save | UT-001, UT-002, IT-001, ST-001 | ✅ sufficient |
| REQ-002 | response ≤3s | PERF-001 (proposed) | ⚠️ needs added test |
| REQ-003 | except admins | IT-002, ST-003 | ✅ sufficient |

**Planner verdict**: PASS / INCOMPLETE
- INCOMPLETE reason: {per REQ}
- Recommended added cases: {list}

## 10. Stage 6 → Stage 7 bridge summary (≤500 chars) ★ required
```markdown
## 📎 Prior-stage summary (Stage 6 → Stage 7)
- **Prior output**: latest test plan — `${base_dir}/${DATE}/testplan_{feature}.md` (or `testplan_{feature}_N.md` in the fix loop)
- **Key decisions**: 1. unit {U} / integration {I} / screen {S} / edge {E} 2. REQ coverage: {PASS/INCOMPLETE} 3. CI failure → full stop
- **Issues the next stage must address**: - manual verification for INCOMPLETE REQ - regression scope
- **Required original sections** ★ (Read directly): latest test plan §3–§5 (cases to run) · §6 (data verification — SQL or project-defined check) · §7 (regression — no dropped prior passes) · §8 (edge) · §9 (recheck INCOMPLETE REQ)
- **Constraints/assumptions**: - {assumptions}
- **Summary limits ⚠️**: - {non-summarizable areas}
```
````

## Execution-order constraint
CI → CD (if applicable) → unit → integration → screen → data → regression → edge
- CI failure = **full stop**
- otherwise = record failure and continue

## Fix-loop extra rules
- Include prior-iteration passing cases as regression.
- Add new cases for the fixed parts.
- Add an "iteration N targets" section at the top.
- **Re-verify the REQ coverage matrix** — did the fix break or add a REQ?
