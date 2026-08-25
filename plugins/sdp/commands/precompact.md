---
description: Create a pre-compact work snapshot and resume prompt
argument-hint: [TOPIC]
---

Create a gitignored snapshot of current in-progress work before manual compact, then print a resume prompt for the next context: $ARGUMENTS

> Use when auto-compact is near or before manual compact. Unlike a full session handover, this is for the same session after compaction: no SSOT entry, no work log, no commit, no push.

## Arguments

- If a topic is provided, use it.
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
   - If the request came from the automation, it names a session tag and asks for
     `precompact_{topic}_{tag}.md`. Use that exact name. Two sessions working in
     the same directory both write here, and the tag is what tells them apart --
     without it the wrong snapshot can be resumed after compaction.
3. Print the resume prompt.
   - Print to chat only.
   - Do not save it to any file.
4. Finish with one clickable Markdown link to the snapshot path.
   - If the hooks are armed, say that the resume happens automatically after compaction and that the printed prompt is only a fallback.
   - If they are not, tell the user to paste the printed prompt as the first message after manual compact.


## Automation

The plugin ships three hooks (`hooks/hooks.json`) that close the loop between
compaction and the next prompt, so no snapshot is lost and no resume prompt has
to be pasted by hand. They are host-native: no terminal driver and no
`statusLine` is involved, so they work in any terminal.

| Hook | When | What it does |
| --- | --- | --- |
| `Stop` | every time the turn ends | Reads context usage from the session transcript. Past the threshold it answers `decision: block` with an instruction to write the snapshot, which gives the model one more tool-capable turn. |
| `PreCompact` | just before compaction | Binds the snapshot this session wrote to this `session_id`, so a second session in the same directory cannot resume the wrong work. |
| `SessionStart` (`compact`) | just after compaction | Injects the snapshot path and resume instructions as `additionalContext`, then clears the marker so the cycle can re-arm. |

After an automatic compaction the host continues the turn on its own, so the
injected context is acted on with no user input. After a manual `/compact` the
host returns to the prompt and the same context is used on the next message.

Automation is off until it is turned on, per user, in `~/.sdp/precompact.json`.
An unset mode is not `auto`.

```bash
# path shown by /sdp:precompact; under an installed plugin it is
# "$(ls -d ~/.claude/plugins/cache/sdp-marketplace/sdp/*/ | sort -V | tail -1)scripts/precompact_hook.py"
python3 <plugin>/scripts/precompact_hook.py config set auto     # or manual
python3 <plugin>/scripts/precompact_hook.py doctor              # loud health report
```

- Threshold defaults to 78 percent of the context window, below the host's own
  auto-compact point so the snapshot wins the race. Override with
  `SDP_PRECOMPACT_THRESHOLD` or the `threshold` key in the config file.
- `SDP_PRECOMPACT_MODE` overrides the config file for one session.
- Running the command by hand works in either mode and needs no hooks.

## Snapshot Structure

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

## Resume Prompt Template

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
