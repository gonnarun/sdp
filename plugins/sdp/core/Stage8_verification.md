# Stage 8: Verification — manual verification checklist (form)

> Used as a prompt. Enter after the Stage 7 test-result gate returns `ALLOW:` (or, in attended mode, an `INFRA_ERROR` — see pre-entry checks). Present a manual verification checklist (screen + API + data) the user runs by hand.

## Input
- **Stage 7 → Stage 8 bridge summary** — index only (read first).
- **Original** `${base_dir}/${DATE}/testresult_{feature}.md` (**latest wins** — after the fix loop it is `testresult_{feature}_N.md`, highest `N`) — Read §3 (per-case results), §4 (bug list), §6 (manual checklist) to source the verification items.

## Pre-entry checks
Check the Stage 7 **verdict FIRST, then the gate result** (verdict before gate, so a `FAIL` can never be masked by a stale `ALLOW:`). Read the gate's stdout first line + exit code; **test for `INFRA_ERROR` BEFORE treating a `BLOCK:` line as a content block** (the gate exits 1 for both).
1. **Verdict `FAIL`** → not a Stage 8 target; return to the fix loop. (Stage 7 does not even gate a FAIL — it auto-enters the loop — so a FAIL here means don't proceed, regardless of any gate line.)
2. **Verdict `CONDITIONAL`** → treat as PASS-eligible **only if** the gate result below is `ALLOW:` (or the INFRA-attended case in #3); otherwise return to Stage 7.
3. Gate **`INFRA_ERROR`** in the line (tooling down/timeout/empty/invalid): **attended** — Stage 8 may proceed for local verification, but MERGE/PUSH stays refused until a clean `ALLOW:` clears the per-artifact `.infra_flag` **and `review_gate.py doctor` exits zero** (this INFRA rule overrides the CONDITIONAL rule; the `doctor` check is the backstop for a root-unresolvable INFRA_ERROR, which cannot set a per-artifact flag); **unattended** — pause + notify, do not enter.
4. Gate **`ALLOW:` (exit 0)** → proceed. (Authoritative signal is stdout+exit, not a log line; the log's last non-PIVOT `RESET` may read `ALLOW`, `ALLOW(agy)`, or `OVERRIDE`, all valid ALLOWs. Do not require a literal `RESET … ALLOW`.)
5. Gate **`BLOCK:` without `INFRA_ERROR`** (a real content block) → do not enter; reinforce Stage 7 or return to the fix loop.

## Scope
- Any work that **affects the screen** (feature dev, bug fix).
- Backend-only changes (migration, API edits) still get API-call verification items.
- No-screen-impact work (config change, refactor) may skip.

> 🌐 **Authoring language (REQ-U-08)**: the screen-test checklist is a runtime deliverable — write it per SDP.md §"Deliverable authoring language" (English canonical + synced `OUTPUT_LOCALE` copy under `output_locale: auto` when env locale ≠ en). Keep REQ-IDs and machine markers ASCII.

## Output
- `${base_dir}/${DATE}/verification_checklist_{feature}.md` (generic core default; screen/API/data sections as the project needs).

## Checklist format
```markdown
## Verification checklist

> Server restart needed: ✅ {project restart command from `.sdp/project-rules.md`} (if applicable)

### {feature area 1}
- [ ] {action} → {expected result}
- [ ] {action} → {expected result}

### {feature area 2}
- [ ] {action} → {expected result}

### DB check (if needed)
- [ ] verify SQL: `SELECT … FROM … WHERE …`
```

## Authoring principles
- Use checkboxes (`- [ ]`) so the user ticks each item.
- Each item is concrete: **"action → expected result"**.
- Group by feature area (save, read, UI, error handling, …).
- Include **only changed/added features** this task; exclude unrelated ones.
- Provide a verification SQL query where a DB check is needed.
