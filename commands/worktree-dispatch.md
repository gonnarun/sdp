---
description: Interview several independent tasks, then hand each off to run the full SDP workflow in its own git worktree, in parallel.
argument-hint: [set of independent tasks]
---

# /worktree-dispatch — parallel tasks via per-worktree handover

You are dispatching **several independent tasks to run in parallel**, each as a full SDP workflow in its **own git worktree**. This command is a thin dispatch adapter over the shared SDP core: each dispatched session runs the identical Stage 1–8 + two codex gates at identical strength (REQ-C-01/REQ-C-04). Parallelism must not weaken the gate — GATE_LOG is keyed per (command·scope·artifact) so each worktree has an independent counter and an independent team-review obligation from `cadence.escalate_from` onward (REQ-C-06).

Tasks (raw request): **$ARGUMENTS**

## 1. Anchor (mandatory — REQ-P-03)

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdp-anchor.sh"
```

Requires a **git repository** (worktrees need one). Confirm the runtime env was written.

## 2. Main does Stage 1 only, then hands off (REQ-C-04)

In **this** (main) session, perform only **Stage 1 (Interview)** with the user (via `AskUserQuestion`) to scope and separate the independent tasks. Do **not** run Stages 2–8 here. Then, for each task, write a **handover** that a Codex implementation session will run as the full SDP workflow (`${CLAUDE_PLUGIN_ROOT}/core/SDP.md`) in its own worktree. Claude Code is used only by the review gate.

Each handover must include a **shared design skeleton / data-model contract** covering only the shared surfaces — schema, shared modules, trust boundaries (REQ-C-05) — so per-task designs don't collide. Each session designs task-local detail beneath that contract.

## 3. Dispatch mode (`dispatch_mode: manual | auto | orca`)

- **`manual` (default).** Emit each task's handover as a copy-pasteable block. The user opens a **Codex** session per task (`git worktree add …`), pastes the handover, and that Codex session runs the full SDP core in its worktree.
- **`auto` (opt-in).** Selected by `dispatch.worktree_mode: auto` in `.sdp/defaults.yaml`. Launches each task automatically via the vendored `${CLAUDE_PLUGIN_ROOT}/scripts/run_segment_tmux.sh`: `git worktree add` the task branch, set `SDP_SESSION_CWD` to that worktree, then `run_segment_tmux.sh <batch_dir> <worktree_dir> init` (Codex with `--ask-for-approval never --sandbox danger-full-access` → anchor → handover → full unattended SDP → Claude review gates → `STATUS.md`). **Capability probe + fallback**: `auto` works only if `tmux`+`codex`+`git` are present and the cwd is inside a git repository; the script exits `5` for missing tools or `3` for invalid cwd → **fall back to `manual`** (do not hard-fail). Runtime-touching stages still require `worktree.runtime_isolation: ephemeral_per_worktree` (REQ-T-08), else they stay checklist-only and main runs them serially. This unattended mode requires a controlled environment, concurrency cap, hard deadline, and kill switch.
- **`orca` (opt-in).** Selected by `dispatch.worktree_mode: orca` in `.sdp/defaults.yaml`; backed by `${CLAUDE_PLUGIN_ROOT}/scripts/orca_dispatch.sh` — `orca_dispatch.sh <BATCH_DIR> <SEGMENT_DIR> <MODE> [TIMEOUT_SECONDS]`, `MODE` ∈ `probe`|`init`|`status`|`stop`. **Do NOT run `git worktree add` for an `orca` task.** Unlike `auto`, the adapter creates the worktree (Orca does, from the pinned base), so a worktree you create as well would be a second, empty one — the worker would change Orca's and you would integrate yours, with every task still reporting SUCCESS. Here `SEGMENT_DIR` is a control directory holding `INPUT.md` and the dispatch record, *not* a checkout; the worktree Orca creates is named after the segment directory's basename, lands at `~/orca/workspaces/<repo>/<name>`, is a **linked worktree of this repository** (so `git worktree list` shows it and its branch is an ordinary local ref), and is what you integrate. Read `worktree_path`, `branch` and `base_sha` from `${SEGMENT_DIR}/.orca_dispatch.json`; merge the commit, not the branch name. On any settled outcome `status` also writes `${SEGMENT_DIR}/RESULT.json` (verdict, `result_sha`, `base_sha`, branch, ancestry, dirty set) — the worktree is disposable and `orca worktree rm` takes `STATUS.md` with it, so that file is what survives cleanup and what integration and reporting should read. **Capability probe, in order**: `orca` on PATH → `orca status --json` reports the runtime reachable and `ready` → a verified `(appVersion, schemaVersion)` pair → exactly one repo (`orca repo list --json`) whose canonicalised path equals the workspace root. **Any** probe failure exits `5` and falls back to **`manual` only — never to `auto`**: degrading to `auto` would silently start an unattended `danger-full-access` Codex session the operator never selected. **This mode enforces no hard timeout** — unlike `auto`, which owns the tmux session it spawned, `orca` does not own the worker's process: past the configured deadline, `status` exits `124` meaning "over budget, still alive, nothing was stopped." Orca's own operating guide forbids killing a worker for exceeding wall-clock, so `stop` remains an explicit operator action only, never deadline-triggered. **`STATUS.md`'s CONTENT is the SDP verdict**, and `status` maps it to the same exit codes `run_segment_tmux.sh` uses — `0` SUCCESS, `10` FAIL_12X, `11` HALT_BLOCK, `12` PAUSE_USER_INPUT_REQUIRED, `9` unrecognized, `125` absent. Presence is never enough: Orca reports `state: succeeded` for a worker whose verdict is `FAIL_12X`, because it is answering "did the process end cleanly", not "did the workflow pass" (measured). Teardown is not automatic here either; the operator removes worktrees, same as `manual`/`auto` — note `orca worktree rm` **preserves the branch** when it carries commits, which is why `init` refuses to dispatch a segment whose branch already exists rather than reusing it.

## 4. Invariants the dispatched sessions must preserve (REQ-C-04)

- **No screen tests in dispatched sessions.** Shared docker/DB/port would collide, so worktree sessions produce **verification checklists only** (Stage 8). The **main** session runs screen tests **serially after merge**.
- Each Codex implementation session runs two Claude review gates (Stage 4 plan, Stage 7 test result); gate strength is identical to the serial `/sdp` path.

## 5. After sessions complete

Main integrates each task after its session finishes (incremental integration), then runs the deferred screen tests serially. Report per-task status.

> Inferred vs documented: all three modes now select Codex implementation workers; Claude Code is review-gate only. `auto` requires `tmux`+`codex`+`git`; `orca` pins `--agent codex` and still requires the verified Orca capability probe. Either degrades to `manual` when its own preconditions fail, never to each other. Live Orca evidence was measured with Claude workers and must be re-measured with Codex (NC-26); live tmux/Codex execution and per-worktree audit aggregation also remain untested.
