---
name: worktree-dispatch
description: Interview several independent tasks and dispatch each as a full SDP workflow in its own git worktree, preserving Claude review gates and merge-time verification.
---

# Worktree Dispatch for Codex

Use when the user asks for `worktree-dispatch`, parallel SDP worktrees, independent task dispatch, or per-worktree handoff.

## Startup

1. Confirm the current project is a git repository.
2. Run `scripts/sdp-anchor.sh` from the repository root.
3. Read `core/SDP.md`, `commands/worktree-dispatch.md`, and required stage form files.
4. Treat `commands/worktree-dispatch.md` as dispatch guidance only; Codex-side gates are `review-gate` via `claude_review_gate` MCP or `python3 scripts/review_gate.py --reviewer claude`.
5. When printing progress or gate requests, label the review gate as `review-gate`, not `codex-gate`.

## Workflow

1. Main session runs Stage 1 only to separate independent tasks.
2. Write a shared design skeleton / data-model contract for shared surfaces.
3. For each task, create a handoff that runs full SDP Stage 2-8 in its own worktree.
4. Dispatch mode:
   - `manual`: emit copy-pasteable handoff blocks and worktree setup commands; require the user to open each handoff in a Codex session.
   - `auto`: use `scripts/run_segment_tmux.sh` only when `dispatch.worktree_mode: auto` is configured and `tmux` + `codex` are available. The runner launches Codex implementation workers; Claude Code remains review-gate only.
   - `orca`: use `scripts/orca_dispatch.sh` only when `dispatch.worktree_mode: orca` is configured and its Orca-CLI capability probe passes. The adapter pins `--agent codex`; no agent/model override is allowed. Any probe failure falls back to `manual` only, never `auto`. Do not `git worktree add` for these tasks — Orca creates the worktree, and a second one would be integrated by mistake. Read the verdict from the adapter's exit code (0 SUCCESS, 10 FAIL_12X, 11 HALT_BLOCK, 12 PAUSE, 9 unrecognized), never from `STATUS.md` merely existing.
5. After worktrees complete, integrate incrementally, then run deferred screen/API/data verification serially in main.

## Invariants

- Each worktree session must run both `review-gate` reviews at full strength.
- Implementation worker must be Codex in every dispatch mode. Claude Code may appear only behind `claude_review_gate` / `--reviewer claude`.
- Dispatched sessions do not run shared screen tests against colliding local services; they produce verification checklists.
- Main session runs merge-time verification serially after integration.

## Gate Adapter

For every Stage 4 plan, promoted design, fix-plan, and Stage 7 result gate:

- Prefer MCP tool `claude_review_gate`.
- Fallback:

```bash
python3 scripts/review_gate.py --cwd "$PWD" --reviewer claude "<review prompt>" "<artifact-path>"
```

Never ask agy after Claude returns a clean content `BLOCK:`. agy fallback is only for Claude missing, nonzero, timeout, empty, or invalid output.
