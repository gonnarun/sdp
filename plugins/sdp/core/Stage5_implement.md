# Stage 5: Implementation (form)

> Used as a prompt. Follow this to implement.

## Input
- **Stage 4 → Stage 5 bridge summary** — index only.
- **Original plan** (`plan_{feature}.md`, or `fix_plan_{feature}_N.md` in the fix loop — **latest wins**). **Read** the implementation order (§5) and per-file change spec (§6); **also §7 (DB changes) when the order includes a DB-migration step** (so the migration is substantiated by the plan).
- **Promoted design** `design_{feature}.md` — when the plan promoted its §2 design to a separate file (implement against its decisions).
- Survey — only the §s the summary lists as required.

> ★ **Original-reference obligation**: the plan's per-file change spec is never replaceable by the summary. Follow the original spec exactly.

## Output
- Code changes (per the plan's / fix-plan's per-file change spec).

> 🌐 **Authoring language (REQ-U-08)**: source code, identifiers, and commit messages are **not** localized (SDP.md §"Deliverable authoring language" applies only to document deliverables). Only human-readable notes you write follow that rule; keep `ALLOW:`/`BLOCK:` and `TEAM_*` markers ASCII.

## Rules

### Docs govern code
- Follow the plan's order and spec **exactly**.
- Make no change absent from the plan.
- If extra change is needed: **stop, edit the plan (or fix-plan) first, re-run the review gate (`claude_review_gate` on the codex side — its CLI fallback there is `--reviewer claude`; `scripts/review_gate.py` with no `--reviewer` on the Claude Code side), and resume only after a fresh `ALLOW:`** (SDP.md "Inter-stage rules"). User approval alone does not authorize an off-plan change — the plan is re-gated. (If that re-gate returns `INFRA_ERROR` rather than a content BLOCK, apply the 3-state policy per SDP.md — attended may resume but MERGE/PUSH stays blocked until a clean `ALLOW:`.)

### Library-API check
- Before a new import / new API call / major-version-migration code, confirm the current signature via `mcp__context7__*` (see SDP.md "context7 MCP rule").
- Not needed when following an existing project pattern.

### Implementation order
1. DB migration (per `.sdp/project-rules.md` migration convention; user approval required).
2. Backend (model → data-access → service → entry → DTO).
3. Frontend (API call → state → component → page).
4. Permissions (per the project's permission convention in `.sdp/project-rules.md` — e.g. a client permission map and/or a permission migration; omit if the project has neither).

> Order is generic; a project without a DB/frontend/permissions collapses the irrelevant steps. Stack specifics live in `.sdp/project-rules.md`.

### Agent team
- Run per the plan's Agent Team composition.
- Backend → Frontend is dependency-ordered (sequential); independent parts (separate page/domain) run in parallel.

### Build verification after implementation (required)
Run each configured build command; **skip refs that resolve to empty** (a project with no compile step leaves `build.build` empty) and record them as "skipped (not configured)".
```bash
# parallel where independent; run only non-empty refs
[Bash] ${build.build}      # build / compile — skip if empty
[Bash] ${build.lint}       # lint — skip if empty
[Bash] ${build.typecheck}  # typecheck — skip if empty (catches type errors early; Stage 6 CI re-runs it as the gate)
```
- On failure: fix and rebuild (in-plan scope only). If the cause is out of plan scope, report to the user.

### Fix-loop extra rules
- Change only what the fix_plan_N "change history" lists.
- Do not introduce changes that would break a prior-iteration passing test — the actual regression run happens in Stage 6–7, but keep in-scope so it stays green there.
- Always run build verification after fixing.

### Project self-check (on each implementation)
- Run the project's implementation checklist from `.sdp/project-rules.md` (the project defines the items).
- If `.sdp/project-rules.md` defines no checklist, apply generic hygiene: no hardcoded secrets, no sensitive data in logs, follow existing patterns.

## Stage 5 → Stage 6 bridge summary (≤500 chars) ★ required
Authored by main context from the implementation result; Stage 6 requires it as first input.
````markdown
## 📎 Prior-stage summary (Stage 5 → Stage 6)
- **Prior output**: code changes (list changed files + one-line purpose each)
- **Key decisions**: 1. {what was built vs the plan} 2. {deviations, if any — and their re-gate ALLOW} 3. {build/lint result}
- **Issues the next stage must address**: - {areas needing focused tests} - {edge cases surfaced during implementation}
- **Required original sections** ★ (Read directly): the latest plan/fix-plan §6 (per-file change spec — source of truth for what changed) · `survey_{feature}.md` §3 (files) + §8 (REQ matrix) · `normalize_{feature}.md` §2 (REQ list)
- **Constraints/assumptions**: - {anything that constrains test design}
- **Summary limits ⚠️**: - {non-summarizable areas — e.g. complex state transitions}
````
> The "≤500 chars" limit applies to the summary body; the **Required original sections** list is excluded (anti-omission wins), per SDP.md stage-bridge rule.
