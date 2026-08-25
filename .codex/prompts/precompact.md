Create a gitignored snapshot of current in-progress work before manual compact, then print a resume prompt for the next context: $ARGUMENTS

> Use when auto-compact is near or before manual compact. Unlike a full session handover, this is for the same session after compaction: no SSOT entry, no work log, no commit, no push.

## Arguments (`$ARGUMENTS`)

- If a topic is provided, use it.
- If no topic is provided and one in-progress task is clear, infer the topic and state it in one line before continuing.
- If two or more topics are plausible, do not guess. List candidates one per line, ask the user to choose, then wait.
- Use the topic only as a filename slug. Keep it short, for example `B`, `mtls`, or `f30`. Restrict it to `[A-Za-z0-9._-]` (no slashes, spaces, or non-ASCII) so the snapshot path stays portable.

## Workflow

1. Gather measured context. Do not rely on memory: in-progress work, completed work in this session (`git log --oneline origin/<branch>..HEAD` plus changed files), current diff, remaining steps, open or edited files with line references, pitfalls already hit, and open questions. If data is unavailable, write `unknown`. Leave no blank sections.
2. Save the in-progress snapshot to `.private/precompact/{YYYYMMDD}/precompact_{topic}.md`. If the request came from the Claude-host automation it names a session tag and asks for `precompact_{topic}_{tag}.md`; use that exact name, since it is what tells two sessions writing into the same directory apart.
   - `{YYYYMMDD}` is today's absolute date. Do not use relative dates.
   - Create the directory if missing.
   - `.private/` is gitignored by project standard. No separate backup or commit needed.
   - Use the structure below. If the same topic file already exists, ask before overwriting.
3. Print the resume prompt to chat only. Do not save it to any file.
4. Finish with one clickable Markdown link to the snapshot path. If the SDP precompact hooks are armed on this host, say that the resume happens automatically after compaction and that the printed prompt is only a fallback; otherwise tell the user to paste the printed prompt as the first message after manual compact.

## Automation

On the Claude host the plugin ships three hooks (`hooks/hooks.json`) that close the loop between compaction and the next prompt: a `Stop` hook that reads context usage from the session transcript and answers `decision: block` past the threshold so the model gets one more turn to write the snapshot, a `PreCompact` hook that binds that snapshot to this `session_id`, and a `SessionStart` (`compact`) hook that injects the snapshot path as `additionalContext` after compaction. Codex does not expose these lifecycle hooks, so on this host the command is manual: run it yourself before compacting, and paste the printed resume prompt afterwards.

Mode lives in `~/.sdp/precompact.json` and is off until set. `python3 <plugin>/scripts/precompact_hook.py config set auto` turns it on; `doctor` reports health.

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
