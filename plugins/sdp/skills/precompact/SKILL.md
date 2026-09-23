---
name: precompact
description: Use before manual context compaction when the user says precompact, /precompact, $precompact, asks to snapshot current work, or asks for a resume prompt before compacting.
---

# Precompact

Snapshot the in-progress work to a gitignored file so the same session can
resume after a compaction. Two paths, and **the difference is a budget**.

## Automation fast-path

A `Stop` hook may ask for the snapshot once context passes the threshold. Its
block text is the **whole contract**. Follow it and stop:

- **First, read the block text for the snapshot location.** If it says the
  location is **REFUSED**, there is no snapshot: write nothing, create nothing,
  tell the user in one line what it said, and stop. Nothing below applies.
  Otherwise it has already created the directory and `mkdir` is forbidden, or
  it says the directory could not be created and allows that one `mkdir`. Do
  not assume which of the three.
- Then write `.private/precompact/{YYYYMMDD}/precompact_{topic}_{tag}.md`
  **now**, from what is already in the conversation.
- Run **no** other commands to prepare it: no `git`, no `gh`, no `ssh`, no
  reads, no searches, no agent or task listings. **Do not read `manual.md`.**
- When a snapshot is being written, keep the six sections (0 Current Work,
  1 Completed, 2 Remaining, 3 Open Files / Locations, 4 Pitfalls / Rules,
  5 Open Questions). Anything the
  conversation does not already hold is `unknown`. Never invent a hash, path
  or result to avoid one.
- The file is the deliverable. No resume prompt, no queued compaction, no
  commit, at most one short line of chat.

Why: the block buys exactly one more turn and a compaction can land inside it.
Measured 2026-09-23 on a Codex session, window 258400 -- block at 81.6%, host
compaction at 83.1%, so the turn was worth about 2800 tokens. It spent 3960
preparing (840 re-reading this skill, 2558 on an agent listing, 562 on a
`git`/`gh`/`ssh` fan-out) and **no snapshot was written**. The work was right;
only its cost was wrong. That is also why this file is short: a matched skill
is read in full, so anything left here is charged to every snapshot.

## Manual path

When a **person** asks -- `precompact`, `/precompact`, `$precompact`, "save
progress before compact", "give me a resume prompt" -- read
[`manual.md`](manual.md) beside this file and follow it. It carries the
measured-gathering workflow, the snapshot structure, the resume-prompt
template, the hook/automation reference and the rules.

## Rules that hold on both paths

- Absolute dates, never relative ones.
- `.private/` is gitignored by project standard; no backup, no commit, no push,
  no PR.
- The `_{tag}` suffix is required whenever the automation names one: two
  sessions share the directory, and the tag is what tells them apart.
