# Stage 7: Test execution (form)

> Used as a prompt. Follow this to run tests.

## Input
- **Stage 6 → Stage 7 bridge summary** — index only.
- **Original test plan** (latest revision wins) — **Read** the listed §s (esp. §3–§5 cases, §9 REQ coverage).
- **Impact verdict** — read `normalize_{feature}.md` §6 (Impact Low/Medium/High) and the plan's §4 impact matrix / blast-radius, so the risk_gated trigger below ("Impact = High or blast-radius exceeded") is decidable at this stage.
- Also verify whether original content not carried in the summary — that should have been implemented — was dropped.

> ★ **Original-reference obligation**: test cases / verification SQL are not replaceable by the summary. Mandatory original reads.

## Output
- `${base_dir}/${DATE}/testresult_{feature}.md`
- Fix loop: `${base_dir}/${DATE}/testresult_{feature}_N.md`

> 🌐 **Authoring language (REQ-U-08)**: write this deliverable per SDP.md §"Deliverable authoring language" — English canonical (+ a synced `OUTPUT_LOCALE` copy when `output_locale: auto` and env locale ≠ en). Test-result **evidence** (commands, exit codes, log tails) stays verbatim; keep REQ-IDs, `ALLOW:`/`BLOCK:`, and `TEAM_*` markers ASCII.

## Destructive / prod-DSN guard ★ (before any test that touches data)
- Tests run only against an isolated test DB (`${test.db.isolation}`, default dedicated_test_db). **Never point tests at a production DSN.**
- `${migrate.prod_block}` (default true): no migration/seed/teardown against a prod target.
- When `${test.guards.require_test_marker}` is true, refuse a destructive step (seed/reset/teardown) unless the target carries the test marker.
- The layered run sequence (install → migrate → seed → services-up + health → smoke → integration → teardown) executes only after these guards pass. Record which guards were checked in the result's §2.

## Execution rules

### Automated tests (unit/integration/risk-gated)
- Write the plan's cases with the project test runner and run them.
- Run every `test.layers.mandatory` layer; **when Impact = High (or blast-radius exceeded), also run every `test.layers.risk_gated` layer** (e2e/contract) — skipping a *configured* risk_gated layer on a high-risk change is a FAIL. A layer name with **no matching `test.commands.<layer>`** is recorded as "skipped (not configured)" and does not FAIL (same escape as an empty `build.*` ref).
- On failure: analyze — **is the test wrong or the code wrong?**
  - test error → fix the test, re-run.
  - **code bug → record the bug and continue to the next case (do not edit code).**
- After all cases, write a result summary table (Pass/Fail/Skip + reason).

### Manual verification
- For non-automatable items, list **method + expected result** as a checklist.
- Confirm what can be checked directly (DB data, log output) via query/command.

### Rule verification
- Check the project checklist in `.sdp/project-rules.md` against the code.
- Cross-check for deprecated-API use in external-library code via `mcp__context7__*` (found → FAIL).
- **Bridge-summary omission regression check** ★ required: compare against originals for items present only in the original §s (esp. survey §4 business rules, plan §6 change spec, test-plan §8 edge cases) that should have been implemented/tested but were dropped. Found → FAIL → enter fix loop.

### Parallel run (Agent Team)
Run only build/lint refs that resolve to non-empty; record empty refs as "skipped (not configured)" (same rule as Stage 5).
```
[Bash] ${build.build}      # build / compile — skip if empty
[Bash] ${build.lint}       # lint — skip if empty
[Bash] ${build.typecheck}  # typecheck — skip if empty (re-run as the CI gate, matching Stage 5/6)
[Security agent]           # audit-log / secret review on changed CUD methods
```

### Never
- Do not edit **production code** to make a test pass.
- Do not ignore or silently skip failing cases.

## Test-result document structure
```markdown
# Test result: {feature}
> Run: {YYYY-MM-DD HH:MM}

## 1. Summary
| Kind | Total | Pass | Fail | Skip |
|------|-------|------|------|------|
| CI check | | | | |
| Unit | | | | |
| Integration | | | | |
| Rule check | | | | |

## 2. CI/CD + guard results
- Build: ✅/❌  ·  Lint: ✅/❌  ·  Schema/DB check: ✅/❌
- Destructive/prod-DSN guards checked: {isolation / prod_block / test-marker}

## 3. Per-case results
| ID | Scenario | Result | Failure reason |

## 4. Bug list
| BUG-ID | Severity | Description | Related file | Repro condition |

## 5. Rule-check results
| Rule | Result | Note |

## 6. Manual checklist (user must confirm)
- [ ] {item}

## 7. Overall verdict
- **PASS**: all automated tests pass + no rule violation
- **FAIL**: {N} bugs → enter fix loop
- **CONDITIONAL**: only minor issues → user judgment
```

## Stage 7 → Stage 8 bridge summary (≤500 chars) ★ required
Authored by the Evaluator from the verdict; Stage 8 requires it as its first input. **Only authored on PASS or CONDITIONAL** — a FAIL verdict auto-enters the fix loop (no Stage 8 transition), so the "verdict" line here is PASS or CONDITIONAL.
````markdown
## 📎 Prior-stage summary (Stage 7 → Stage 8)
- **Prior output**: `${base_dir}/${DATE}/testresult_{feature}.md` (**latest wins** — after the fix loop, `testresult_{feature}_N.md`)
- **Key decisions**: 1. verdict {PASS/CONDITIONAL} (FAIL → fix loop, not here) 2. {bugs fixed / residual} 3. gate `ALLOW:` obtained (or `INFRA_ERROR` state)
- **Issues the next stage must address**: - {manual verification items} - {screen/API/data checks needed}
- **Required original sections** ★ (Read directly): `testresult_{feature}.md` §3 (per-case results) · §4 (bug list) · §6 (manual checklist — the source of Stage-8 items)
- **Constraints/assumptions**: - {DSN/destructive guards that constrain manual verification}
- **Summary limits ⚠️**: - {non-summarizable areas}
````

## Fix-loop trigger
- **PASS**: do not enter the loop; run the test-result gate. `ALLOW:` → Stage 8; `BLOCK:` → reinforce/re-review.
- **FAIL**: auto-enter the fix loop. The "bug list" becomes the fix-plan input; fix-plan needs a review gate `ALLOW:`.
- **CONDITIONAL**: do not enter the loop; run the test-result gate. codex `ALLOW:` → Stage 8; `BLOCK:` → reinforce missing verification or convert to FAIL.
- Loop details: SDP.md "Automatic fix loop".

## review-gate test-result review (mandatory on completion)

When the result is **PASS or CONDITIONAL**, do not ask the user — review it with the gate. (A **FAIL** verdict auto-enters the fix loop instead — the fix-plan's own gate covers it — so the test-result gate is not run on FAIL.) **Do not embed gate logic — call the script.**

### Summary block (print before running)
```markdown
---
## 🔒 review-gate test-result review request
- **Verdict**: {PASS/CONDITIONAL}  (FAIL is not gated — it auto-enters the fix loop, so the gate only reviews PASS/CONDITIONAL)
- **CI**: build {result} / lint {result}
- **Unit·integration**: {P}/{total}
- **Rule check**: {Critical pass/fail + Major pass/fail}
- **Manual items**: {N — needs user confirmation?}
- **Main residual risks**: {summary}
On ALLOW, proceed to Stage 8.
---
```

### Run
arg1 is the review PROMPT, arg2 is the artifact path. Do NOT pass `@<artifact>` as arg1 (`@file` loads the prompt FROM the file, so the result would become the instruction and the dimensions never reach codex).
```bash
RESULT="$BASE_DIR/$DATE/testresult_{feature}.md"   # values read from anchor metadata, never sourced; fix loop: testresult_{feature}_N.md
python3 scripts/review_gate.py --cwd "$PWD" --reviewer codex "Review the test result at $RESULT against the SDP Stage-7 review dimensions (all test-plan cases + REQ reflected, except Must REQs formally waived in Stage 6 §9; CI results stated; unit+integration results; risk_gated (e2e/contract) results present when Impact=High or blast-radius exceeded; security regression, permission, project repeated-mistake, invariants per .sdp/project-rules.md; bridge-omission regression; verdict matches Evaluator criteria; ready for Stage 8). First line must be 'ALLOW: <summary>' or 'BLOCK: <reason>', no preamble. Every finding MUST comply with the 'BLOCK output contract' subsection of this stage document: all six fields (WHERE, WHY, FIX, VERIFY, SEVERITY, SCOPE), SCOPE being exactly one of closeable-in-this-dispatch or must-be-recorded-instead, any field you cannot supply labelled exactly 'INCOMPLETE - <field> not supplied because <reason>', and the verdict closing with CHECKED-AND-CLEAN and IF-ONLY-ADVISORY." "$RESULT"
```
The gate enforces a single **550s** wall budget (`GATE_WALL_BUDGET`, ADR-008) across the Claude review + agy fallback; per-provider caps default to 300s and are read from `gates.yaml` (`claude_timeout` / `agy_timeout`), never the environment. The MCP `tool_timeout_sec` (660s) is the outer host ceiling (550 < 660 < the Bash-tool `600000ms` hard max).

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

### Review dimensions (the gate's prompt — de-domained)
1. All test-plan cases and REQ-xxx reflected in the result (except any `Must` REQ formally waived in Stage 6 §9 — attended only; a waived REQ is documented `INCOMPLETE`, not a coverage gap).
2. CI results (`${build.build}`, `${build.lint}`) stated.
3. Unit + integration (API + permission) results stated; **risk_gated (e2e/contract) results present when Impact = High (or blast-radius exceeded)**.
4. **Security regression**: audit-log / transaction-log / no secret exposure / no PII in logs / PII-read audit / data-scope filter — checks recorded (per `.sdp/project-rules.md`).
5. **Permission verification**: new-page permission registration completeness and guard-component behavior (per `.sdp/project-rules.md`).
6. Project "repeated-mistake" list violations = 0, recorded (per `.sdp/project-rules.md`).
7. Bridge-summary omission regression check result — original-only items reflected in implementation/tests.
8. PASS/CONDITIONAL verdict matches the Evaluator's criteria (a FAIL result is not gated here — it auto-enters the fix loop).
9. Ready for Stage 8 (manual items + DB-verify SQL clear in the result).
10. Invariant/rule non-compliance = 0, recorded (per `.sdp/project-rules.md`).

> Dimensions 1–3, 7–9 are generic. 4–6, 10 lean on `.sdp/project-rules.md` for project specifics.

### Verdict handling
Same as Stage 4: `ALLOW:` → Stage 8; `BLOCK:` → reinforce/re-review; escalation via team markers is automatic in the gate (do not substitute planner-solo to save cost — the cost/continue call is the user's); `.halt` → stop and report. `INFRA_ERROR` (tooling down/timeout/empty/invalid) → **attended**: stage may advance but MERGE/PUSH refused until a clean `ALLOW:` clears the infra flag; **unattended**: pause + notify (matches the gate + `.sdp/gates.yaml infra_error_policy`).

## Source-citation rule
Inline-cite every judgment:
```
> 📎 basis: `{doc path}` — {section/rule summary}
> 📎 basis: `.sdp/project-rules.md` — audit/transaction-log requirement
```
