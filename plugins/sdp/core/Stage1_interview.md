# Stage 1: Interview (form)

> This file is used as a prompt. On receiving a change request, run an interview per this form to scope the survey.

## Purpose
Clearly define the "survey target". Stage 1 output hands to **Stage 2**, which folds the survey scope into `normalize_{feature}.md`; Stage 3 then surveys against that normalized spec (Stage 1 is not read directly by Stage 3).

## Interview rules
- Listen to the request; pin down the scope and context the survey needs.
- **≤7 questions at once** — do not ask the obvious.
- **≤3 rounds** total. Do not over-question.
- **Ask via the interactive question tool** (`AskUserQuestion` in Claude Code; the host's equivalent otherwise) — no plain numbered lists.
  - Multiple-choice-natural questions provide `options` (e.g. "Which screen does this go on?" + [List / Detail / New menu / Other]).
  - Free-response questions still use `AskUserQuestion`, with an "Other (type your own)" option.
  - Bundle several items into one `AskUserQuestion` call's `questions` array.
  - **Why**: the user answers instantly via the options UI → faster, more accurate interview.

## Question lenses
Ask only what is needed, selected from:

| Lens | Example |
|------|---------|
| Change scope | which screen / feature / table is targeted |
| Edge cases | duplicates, missing required values, concurrent edits |
| Security | PII presence, encryption grade, permission granularity |
| UX | draft-save, validation timing, error display |
| Existing-system integration | shared codes, existing table relations, similar features |

## Output

> 🌐 **Authoring language (REQ-U-08)**: `AskUserQuestion` prompts follow the user's environment locale naturally; the written "survey target" note follows SDP.md §"Deliverable authoring language" (English canonical + synced `OUTPUT_LOCALE` copy under `output_locale: auto` when env locale ≠ en). Keep REQ-IDs and machine markers ASCII.

From the answers, assemble the "survey target" to hand to Stage 2 (which folds it into `normalize_{feature}.md`; Stage 3 then surveys against that):

```markdown
## Survey target (Stage 1 interview result)
- **Target feature**: {description}
- **Change scope**: {screen / API / DB scope}
- **Key considerations**: {edge cases, security, UX, …}
- **Similar features to reference**: {if any}
```

## Skip conditions
If the user rejects the interview ("just build it" / "start now"), go straight to Stage 2 (normalization).
May also skip when the user has already given a concrete spec — **but only if Impact High is not suspected** (PII/security/DB/RBAC/crypto). When Impact High is plausible, run at least a minimal interview even with a clear spec (consistent with Stage 2's "cannot skip normalization when Impact High").
