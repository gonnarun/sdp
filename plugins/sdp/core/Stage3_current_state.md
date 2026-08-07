# Stage 3: Current-state survey (form)

> Used as a prompt. Follow this structure to write the survey.
> **Shape**: Step 1 (parallel Explore) → Step 2 (Planner integration — gap judgment + REQ coverage cross-check).

## Input
- **Stage 2 → Stage 3 bridge summary** — index only (read first).
- **Original artifact** `${base_dir}/${DATE}/normalize_{feature}.md` — **Read** the §s the summary lists, **including §6 (impact self-diagnosis)** since the survey scope depends on the impact verdict.
- Stage 2 always writes at least a minimal `normalize_{feature}.md` (even when the interview was skipped); Stage 3 works from that, **never the raw prompt directly** (normalize is the single source of truth).

> ★ **Original-reference obligation**: do not start from the summary alone. The listed original §s are mandatory reads; read more as needed.

## Output
- `${base_dir}/${DATE}/survey_{feature}.md`

> 🌐 **Authoring language (REQ-U-08)**: write this deliverable per SDP.md §"Deliverable authoring language" — English canonical (+ a synced `OUTPUT_LOCALE` copy when `output_locale: auto` and env locale ≠ en). Keep REQ-IDs, `ALLOW:`/`BLOCK:`, and `TEAM_*` markers ASCII.

## Method
**Two-step pipeline**: parallel exploration → Planner integration.

### Step 1: parallel Explore agents (independent survey)
Spawn only the lanes the project actually has — **a surface the project lacks (no frontend / no DB) collapses**; the §3 template sections and the `BE/FE/DB` bridge counts drop with it. Stack shape per `.sdp/project-rules.md`. For a non-web project, phrase lanes generically (entry → logic → data).
1. **Backend / entry-logic** (Explore / sonnet): trace the relevant entry → service → data-access → model layers; identify dependent services/utils/config.
2. **Frontend** (Explore / sonnet) — *if the project has a UI*: trace relevant page → component → API call → state; identify shared components/hooks.
3. **DB/infra** (Explore / sonnet) — *if the project has a datastore*: relevant table schema, indexes, foreign keys, migration history, shared-code & permission data.
4. **(optional) external precedent** (researcher / opus): when Impact High or introducing a new library/framework — collect guides and prior art.

### Step 2: Planner integration
Planner takes the parallel results and:
1. **Drafts the survey** — integrate Explore results into the template.
2. **Judges survey gaps** — any REQ whose current state is unconfirmed? Are Impact-High items (PII/security/DB) checked against current rules? On a gap: **re-call Explore** or ask the user.
3. **REQ coverage cross-check** — map each REQ-xxx to "where it connects in existing code/DB".
4. **Identify current problems** — hardcoding, missing validation, non-standard patterns, tech debt.
5. **Compile Stage 4 constraints** — issues the plan must address.

### Planner input prompt (template)
```
You are the Stage 3 current-state-survey integration owner of the SDP workflow.

[Input 1: normalize] {REQ list + impact verdict + ASM (assumptions) list + unmapped items}
[Input 2: parallel survey] backend / frontend / DB-infra / external (if any) summaries

[Requirements]
1. Integrate into the "survey document structure" template.
2. Build a REQ coverage matrix (REQ-xxx → existing file/table/function).
3. Note any survey gap in "§8.1 survey limits"; judge if re-survey is needed.
4. Compile Stage 4 must-consider issues in "§9".
5. Append the Stage 3 → Stage 4 bridge summary.
```

## Survey criteria
- Each file: **path + core role + relevant excerpt (≤10 lines)**.
- Diagram the call flow in order (API entry → service → query → response).
- Extract and state the currently-working business rules from code.
- Flag hardcoded values, missing validation, non-standard patterns as **improvement points**.

## Cross-checks
Run only the ones the project's surfaces make applicable (a project with no UI/datastore/permission model skips them):
- *(if UI + backend)* Frontend-called API vs actual backend endpoint.
- *(if datastore)* Model fields vs DB columns.
- *(if a permission model)* Permission wiring: client permission map ↔ permission table ↔ guard component consistency.
- **★ REQ coverage** *(always)*: each REQ-xxx connects to a current-state finding.

## Survey document structure
````markdown
# Current-state survey: {feature}
> Date: {YYYY-MM-DD} | based on Stage 2 normalize | Planner integration

## 0. Stage 2 → Stage 3 bridge summary (≤500 chars)
{summary block}

## 1. Survey scope
- target feature, related modules, excluded scope
- Impact verdict: {Low/Medium/High} (basis: normalize §6)

## 2. Architecture
- call-flow diagram (front → API → service → DB)

## 3. Files and roles
### 3.1 Backend
| Path | Role | Key methods |
### 3.2 Frontend
| Path | Role | Key components/hooks |
### 3.3 DB
| Table | #Columns | Related index/FK |

## 4. Business rules
| Rule | Source (file:line) | Note |

## 5. Data state (only what the project has)
- relevant reference/lookup data, permissions/roles, registration state — per `.sdp/project-rules.md`; omit categories the project lacks

## 6. Dependency map
- modules this feature references / that reference it

## 7. Current problems & improvement points
- non-standard patterns, gaps, tech debt

## 8. REQ coverage matrix ★ required
| REQ-ID | Requirement | Existing file/table/function | State (met/partial/unmet) | Note |
|--------|-------------|------------------------------|---------------------------|------|
| REQ-001 | {requirement} | {existing symbol}:{line} | partial — {gap} | fix needed |
| REQ-002 | response ≤3s | (none) | unmet — no perf metric | measure |

### 8.1 Survey limits
| Unsurveyed item | Reason | Re-survey? |

## 9. Implementation constraints + Stage 4 handoff
### 9.1 `.sdp/project-rules.md` items relevant to this work
- {rule list from `.sdp/project-rules.md`}
### 9.2 issues the Stage 4 plan must address
- {issue — basis}

## 10. Stage 3 → Stage 4 bridge summary (≤500-char body; the Required-original-sections list is excluded) ★ required
```markdown
## 📎 Prior-stage summary (Stage 3 → Stage 4)
- **Prior output**: `${base_dir}/${DATE}/survey_{feature}.md`
- **Key decisions**: 1. {N} target files (BE X / FE Y / DB Z) 2. REQ coverage: met {A}, partial {B}, unmet {C} 3. Impact {Low/Medium/High} — main risk {summary}
- **Issues the next stage must address**: - {list the plan must solve}
- **Required original sections** ★ (Read directly): `survey_{feature}.md` §3 (files → target set) · §4 (rules the plan must not break) · §7 (anti-patterns to avoid) · §8 (REQ mapping — basis for change spec) · §8.1 (gaps to close first) · §9 (mandatory constraints)
- **Constraints/assumptions**: - {ASM, survey limits}
- **Summary limits ⚠️**: - {non-summarizable areas}
```
````

## Source-citation rule
Inline-cite every judgment/finding:
```
> 📎 basis: `{doc path}` — {section/rule summary}
> 📎 basis: normalize_{feature}.md — REQ-003 (maps raw "auto-send")
```
