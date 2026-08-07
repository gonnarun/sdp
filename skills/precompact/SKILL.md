---
name: precompact
description: Use before manual context compaction when the user says precompact, /precompact, $precompact, asks to snapshot current work, or asks for a resume prompt before compacting.
---

# Precompact

Create a gitignored snapshot of current in-progress work before manual compact, then print a resume prompt for the next context.

## Trigger

- `precompact`
- `/precompact`
- `$precompact`
- Request to save current progress before compact.
- Request to create a resume prompt after compact.

## Input

- If the user provides a topic, use it.
- If no topic is provided and one in-progress task is clear, infer the topic and state it in one line before continuing.
- If two or more topics are plausible, do not guess. List candidates one per line, ask the user to choose, then wait.
- Use the topic only as a filename slug. Keep it short, for example `B`, `mtls`, or `f30`. Restrict it to `[A-Za-z0-9._-]` (no slashes, spaces, or non-ASCII) so the snapshot path stays portable.

## Workflow

1. Gather measured context. Do not rely on memory.
   - In-progress work.
   - Completed work in this session: `git log --oneline origin/<branch>..HEAD`, changed files, current diff.
   - Remaining steps.
   - Open or edited files with line references.
   - Pitfalls already hit.
   - Open questions.
   - If data is unavailable, write `unknown`. Leave no blank sections.
2. Save the in-progress snapshot to `.private/precompact/{YYYYMMDD}/precompact_{topic}.md`.
   - `{YYYYMMDD}` is today's absolute date. Do not use relative dates.
   - Create the directory if missing.
   - `.private/` is gitignored by project standard. No separate backup or commit needed.
   - If the same topic file already exists, ask before overwriting.
3. Print the resume prompt.
   - Print to chat only.
   - Do not save it to any file.
4. Finish with one clickable Markdown link to the snapshot path and tell the user to paste the printed prompt as the first message after manual compact.

## Snapshot

```markdown
# Precompact Snapshot: {topic}
> Created {YYYYMMDD HH:MM} / in-progress state before compact / target: same-session resume

## 0. Current Work
One-line goal and exact current stage.

## 1. Completed
Items finished in this session. Include commit hashes, changed files, and confirmed decisions.

## 2. Remaining
Next steps in order. Use 1. 2. 3.

## 3. Open Files / Locations
Edited files with line references and reference document paths.

## 4. Pitfalls / Rules
Problems already hit, things not to do, gate rules, backup rules.

## 5. Open Questions
User-confirmation items or unresolved decisions.
```

- Use only real code, paths, and commit hashes. Invent nothing.

## Resume Prompt

Chat output only. Fill `{...}` with the actual snapshot content before printing.

```markdown
Continue after compact. Resume {topic}.

First read {absolute snapshot path}. Restore pre-compact state.
Then read {additional key files:line / reference docs}.

Current stage: {snapshot section 0}
Remaining steps: {snapshot section 2}
Important cautions: {snapshot section 4, 1-2 lines}
Do not commit or push unless explicitly approved.

{If open questions exist: First ask "{question}" before continuing.}
```

## Rules

- Do not save the resume prompt. Print it only in chat.
- Save only the snapshot file.
- Do not commit, push, or open a PR.
- Use absolute dates. Do not use relative dates.
