# Stage 2: Requirement normalization (form)

> Used as a prompt. Follow this structure and instruction to normalize requirements.

## Purpose
Convert the user's raw prompt + Stage 1 interview answers into a **structured requirement spec**.
- Prevent the long raw prompt from flowing verbatim through Stages 3–7.
- Assign requirement IDs so every later stage can trace them.
- Guarantee — via an **anti-omission mapping table** — that no expression from the raw prompt is dropped.

## Input
- The user's **original request prompt** (quoted verbatim, no edits).
- Stage 1 interview Q&A (if any).

## Output
- `${base_dir}/${DATE}/normalize_{feature}.md`

> 🌐 **Authoring language (REQ-U-08)**: write this deliverable per SDP.md §"Deliverable authoring language" — English canonical (+ a synced `OUTPUT_LOCALE` copy when `output_locale: auto` and env locale ≠ en). Keep REQ-IDs, `ALLOW:`/`BLOCK:`, and `TEAM_*` markers ASCII.

## Method
**Planner-led.** Main context hands the Planner the input and receives the artifact.

### Planner input prompt (template)
```
You are the Stage 2 requirement-normalization owner of the SDP workflow.

[Original prompt]
{full user raw text}

[Stage 1 interview Q&A]
{answer summary, or "interview skipped"}

[Requirements]
1. Extract every requirement candidate from the raw text; assign IDs REQ-001, REQ-002, …
2. Classify each as functional / non-functional / constraint.
3. Build a mapping table so every meaning unit (keyword, verb phrase, number, prohibition) maps to ≥1 REQ.
4. Record any unmapped keyword in the "unmapped" section with a reason.
5. Write normalize_{feature}.md and return the unmapped count to main context.
```

### Output document structure
````markdown
# Requirement normalization: {feature}
> Date: {YYYY-MM-DD} | Stage 2 | Planner

## 0. Raw prompt (do not alter)
> The user's original request, verbatim — not one character changed.
```
{user raw text}
```

## 1. Stage 1 interview summary
- Q1: {question} → A1: {answer}
- (if skipped: "Stage 1 interview skipped")

## 2. Normalized requirements
| ID | Requirement | Class (func/non-func/constraint) | Source keyword | Priority |
|----|-------------|----------------------------------|----------------|----------|
| REQ-001 | {one-sentence requirement} | functional | "…" (raw quote) | Must |
| REQ-002 | … | non-functional (perf) | "…" | Must |
| REQ-003 | … | constraint (policy) | "…" | Must |

### Class guide
- **functional**: specific output/behavior for a specific input.
- **non-functional**: perf, security, UX quality (e.g. "response ≤3s").
- **constraint**: tech/policy limits (e.g. "mask PII before decrypt", "one specific DB engine only").

### Priority
- **Must**: implement now. **Should**: if feasible. **Hold**: defer.

## 3. Anti-omission mapping table ★ required
> Every keyword/verb-phrase/number extracted from the raw text must map to ≥1 REQ.
> If even one is unmapped, record it in "4. Unmapped" and return a warning to main context.

| Raw keyword/phrase | Mapped REQ-ID | Mapping type |
|--------------------|---------------|--------------|
| "auto-save" | REQ-001 | direct |
| "within 3s" | REQ-002 | direct |
| "except admins" | REQ-001, REQ-003 | constraint narrows REQ-001 + reflected in REQ-003 |
| "same as the existing form" | REQ-004 | indirect (implies a reference implementation) |

Types: **direct** (in the requirement text) · **indirect** (implicit, e.g. "same as" → name the reference) · **constraint** (reflected as a condition/exception).

## 4. Unmapped items ⚠️ (record if any)
| Raw expression | Reason | Action needed |
|----------------|--------|---------------|
| e.g. "make it look nice" | subjective/vague | confirm with user |
| e.g. "later…" | out of scope (future) | confirm (defer?) |

**If 0 unmapped, write "none" here.**

## 5. Assumptions & interpretation
Record everything the Planner inferred where the raw text was silent.

| ASM ID | Assumption | Affected REQ | Risk |
|--------|-----------|--------------|------|
| ASM-001 | {inferred behavior — e.g. "save" implies a persisted side effect} | REQ-001 | Low |
| ASM-002 | {inferred dependency — e.g. reuse an existing project convention} | REQ-003 | Medium |

**Risk ≥ Medium assumptions: recommend user confirmation.**

## 6. Impact self-diagnosis (size-classification aid)
If any box is checked → **Impact High** → treat later work as size L.
- [ ] PII (email/phone/national-ID/account) store/read/decrypt path change
- [ ] DB schema change (add/drop/type column, index, FK)
- [ ] RBAC or data-scope rule change
- [ ] crypto grade / key management / secret-store path change
- [ ] audit-log / transaction-log rule change
- [ ] auth/session/CSRF security middleware change

Verdict: **Impact Low / Medium / High** (Planner decides).

## 7. Handoff to next stage
- Stage 3 (current-state survey) receives: the REQ list, the impact verdict, the ASM list.
- The Stage 1 raw prompt is no longer referenced directly by later stages.

## 8. Stage 2 → Stage 3 bridge summary (≤500-char body; Required-original-sections list excluded) ★ required
```markdown
## 📎 Prior-stage summary (Stage 2 → Stage 3)
- **Prior output**: `${base_dir}/${DATE}/normalize_{feature}.md`
- **Key decisions**: 1. {N} requirements normalized (Must {M}, Should {P}) 2. Impact: {Low/Medium/High} 3. Unmapped {X} (with handling)
- **Issues the next stage must address**: - survey existing code for REQ-001, REQ-003 - Impact-High items need security/DB/RBAC survey
- **Required original sections** ★ (Read directly): `normalize_{feature}.md` §2 (full REQ list) · §6 (impact verdict — Stage 3 survey scope depends on it) · **if present (full normalize only)** §4 (unmapped — consider for survey scope) · §5 (verify Risk≥Medium assumptions). §2/§6 always exist; the minimal skip-path normalize omits §4/§5 (nothing to read).
- **Constraints/assumptions**: - ASM-002 (secret-store reuse) unconfirmed → design may shift
- **Summary limits ⚠️**: - complex state-transition / transaction rules not summarizable
```
````

## Anti-omission constraints (★ no approval, but no omission)
1. **Verbatim quote**: "0. Raw prompt" contains the user text unchanged.
2. **Mapping obligation**: every keyword/verb-phrase/number **either maps to a REQ-ID or is recorded in §4 (Unmapped) with a disposition** — nothing is silently dropped.
3. **Unmapped warning**: any §4 item → print a warning + ask the user once ("how should I handle this expression?"). **Unattended fallback**: if no user is present, default the item to "deferred (out of scope this iteration)", record it in §4, and continue — never stall.
4. **No approval request**: Stage 2 is not a review-gate; user confirmation is for omission-checking only.
5. **REQ-ID permanence**: once assigned, a REQ-ID never changes in later stages (additions allowed).

## Completion output
```
━━━ Progress ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Stage 1  Interview
✅ Stage 2  Requirement normalize
🔄 Stage 3  Current-state survey    ◀ next
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📄 normalize_{feature}.md written
- Requirements: {N} (Must {M} / Should {P} / Hold {Q})
- Impact: {Low/Medium/High}
- Unmapped: {0 | N ⚠️ needs check}
- Assumptions (ASM): {N}, {M} at Risk≥Medium

{if unmapped ↓}
⚠️ These raw expressions were not mapped:
  - "{expression}" — reason: {reason}
  → Include this in scope too? (Y/N/Other)
```

## Skip conditions
- Before any skip, run a **quick suspected-impact scan** on the raw prompt (does it plausibly touch PII / security / DB schema / RBAC / crypto?). This scan is cheap and needs no full normalization.
- If the user rejects both interview and normalization ("start now") **and** the scan finds no suspected-High signal: still write a **minimal** `normalize_{feature}.md` — it must contain **§2** (≥1–2 REQs implied by the raw prompt), **§6** (impact verdict, defaulted to Low from the scan), the verbatim raw quote, and a **minimal §8 bridge summary** (prior-output path + the §2 REQs + impact=Low — Stage 3 reads the bridge as its first input; §4/§5 are omitted, matching the "if present" bridge rule). Then go to Stage 3.
- **Cannot skip when suspected Impact High** — run full normalization even with a clear spec ("security/PII/DB changes start from Stage 1"). The full §6 self-diagnosis then confirms or clears it.

## Source-citation rule
Inline-cite documents/code the Planner referenced when interpreting requirements.
```
> 📎 basis: `{project rule doc from .sdp/project-rules.md}` — {relevant rule}
> 📎 basis: normalize_{feature}.md — REQ-003 (maps raw "auto-send")
```
