Create a gitignored snapshot of current in-progress work before manual compact, then print a resume prompt for the next context: $ARGUMENTS

> Use when auto-compact is near or before manual compact. Unlike a full session handover, this is for the same session after compaction: no SSOT entry, no work log, no commit, no push.

## Arguments (`$ARGUMENTS`)

- If a topic is provided, use it.
- If no topic is provided and one in-progress task is clear, infer the topic and state it in one line before continuing.
- If two or more topics are plausible, do not guess. List candidates one per line, ask the user to choose, then wait.
- Use the topic only as a filename slug. Keep it short, for example `B`, `mtls`, or `f30`. Restrict it to `[A-Za-z0-9._-]` (no slashes, spaces, or non-ASCII) so the snapshot path stays portable.

## Workflow

1. Gather measured context. Do not rely on memory: in-progress work, completed work in this session (`git log --oneline origin/<branch>..HEAD` plus changed files), current diff, remaining steps, open or edited files with line references, pitfalls already hit, and open questions. If data is unavailable, write `unknown`. Leave no blank sections.
2. Save the in-progress snapshot to `.private/precompact/{YYYYMMDD}/precompact_{topic}.md`. If the request came from the host automation it names a session tag and asks for `precompact_{topic}_{tag}.md`; use that exact name, since it is what tells two sessions writing into the same directory apart.
   - `{YYYYMMDD}` is today's absolute date. Do not use relative dates.
   - Create the directory if missing.
   - `.private/` is gitignored by project standard. No separate backup or commit needed.
   - Use the structure below. If the same topic file already exists, ask before overwriting.
3. Print the resume prompt to chat only. Do not save it to any file.
4. Queue the compaction, if this session can be typed into. Locate the plugin from the file you are reading: `${CLAUDE_PLUGIN_ROOT}` is a hook variable and is NOT set for ordinary tool calls on either host, so it expands to nothing here. Take the absolute path of this file and walk UP its ancestors, choosing the first one where `<ancestor>/scripts/precompact_hook.py` is a real file -- do not assume a fixed depth, since this file ships at several (`plugins/sdp/skills/...`, `skills/...`, `.agents/skills/...`, `.codex/prompts/...`, and the installed cache). A host-expanded, non-empty, absolute `${CLAUDE_PLUGIN_ROOT}` may be used as a shortcut when present. If neither yields a real `scripts/precompact_hook.py`, stop and take the manual fallback. Do not pick a version out of the install cache: the newest one there is not necessarily the one this session loaded, and on the other host it is the wrong host's copy entirely.
5. Run `python3 "<plugin root>/scripts/precompact_hook.py" compact "<snapshot path>"`, passing the absolute path of the snapshot written in step 2. Passing it is what makes the binding deterministic: a hand-run snapshot carries no session tag, and if another recent one sits beside it neither can be bound, leaving the cycle with no resume context at all.
   Exit 0 means the compaction is **queued, not submitted**. Nothing is typed while this turn is running: text sent mid-turn interrupts the turn rather than starting a new one. A detached waiter blocks on the driver's own idle condition and submits `/compact` once this turn actually ends. So end the turn promptly -- say the cycle is queued and stop, print no resume prompt as an instruction, and start no new work.
   Exit non-zero means no terminal driver is bound to this session, or the pane did not resolve to exactly one live terminal. Do not retry, and never guess a terminal. Tell the user to run `/compact` themselves, and that the printed prompt is their fallback for the first message afterwards.
6. Finish with one clickable Markdown link to the snapshot path.

## Automation

The plugin ships three hooks (`hooks/hooks.json`) that close the loop between compaction and the next prompt: a `Stop` hook that reads context usage from the session transcript and answers `decision: block` past the threshold so the model gets one more turn to write the snapshot, a `PreCompact` hook that binds that snapshot to this `session_id`, and a `SessionStart` (`compact`) hook that injects the snapshot path as `additionalContext` after compaction. Both hosts support these events with the same semantics, but they read different files: Claude Code auto-loads `hooks/hooks.json`, while Codex reads `hooks/hooks.codex.json` as declared in its `plugin.json`. The Codex copy is generated from the Claude one, so the two never drift.

Codex skips a plugin's hooks until they are trusted. Run `/hooks` once on this host and accept them; until then they are registered but never fire, and the command behaves as it always did -- run it yourself before compacting and paste the printed resume prompt afterwards. Context is measured from the Codex rollout's `token_count` events, taking `last_token_usage.input_tokens` and `model_context_window` from the same newest event -- the model can change mid-session, so pairing the latest usage with the widest window ever seen would under-report occupancy by several times and skip the snapshot. That shape is not a documented interface, so if a CLI update changes it the hook measures nothing and stays silent rather than guessing.

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
