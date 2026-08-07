---
description: Interview several independent tasks, then hand each off to run the full SDP workflow in its own git worktree, in parallel.
argument-hint: [set of independent tasks]
---

# /worktree-dispatch — parallel tasks via per-worktree handover

You are dispatching **several independent tasks to run in parallel**, each as a full SDP workflow in its **own git worktree**. This command is a thin dispatch adapter over the shared SDP core: each dispatched session runs the identical Stage 1–8 + two codex gates at identical strength (REQ-C-01/REQ-C-04). Parallelism must not weaken the gate — GATE_LOG is keyed per (command·scope·artifact) so each worktree has an independent counter and independent round-6 team-review obligation (REQ-C-06).

Tasks (raw request): **$ARGUMENTS**

## 1. Anchor (mandatory — REQ-P-03)

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdp-anchor.sh"
```

Requires a **git repository** (worktrees need one). Confirm the runtime env was written.

## 2. Main does Stage 1 only, then hands off (REQ-C-04)

In **this** (main) session, perform only **Stage 1 (Interview)** with the user (via `AskUserQuestion`) to scope and separate the independent tasks. Do **not** run Stages 2–8 here. Then, for each task, write a **handover** that another session will run as the full SDP workflow (`${CLAUDE_PLUGIN_ROOT}/core/SDP.md`) in its own worktree.

Each handover must include a **shared design skeleton / data-model contract** covering only the shared surfaces — schema, shared modules, trust boundaries (REQ-C-05) — so per-task designs don't collide. Each session designs task-local detail beneath that contract.

## 3. Dispatch mode (`dispatch_mode: manual | auto`)

- **`manual` (default).** Emit each task's handover as a copy-pasteable block. The user opens a session per task (`git worktree add …`), pastes the handover, and that session runs the full SDP core in its worktree.
- **`auto` (opt-in).** Selected by `dispatch.worktree_mode: auto` in `.sdp/defaults.yaml`. Launches each task automatically via the vendored `${CLAUDE_PLUGIN_ROOT}/scripts/run_segment_tmux.sh`: `git worktree add` the task branch, set `SDP_SESSION_CWD` to that worktree, then `run_segment_tmux.sh <batch_dir> <worktree_dir> init` (`bypassPermissions` headless session → the runner's prompt anchors the worktree via `sdp-anchor.sh`, injects the handover, and runs the full SDP core unattended → `STATUS.md` completion → a line appended to the batch history under the main `base_dir`). **Capability probe + fallback**: `auto` works only if `tmux`+`claude` are present and the codex auto-mode classifier does not block headless/tmux/`bypassPermissions` loops (§4.6); the script exits `5` when tools are missing → **fall back to `manual`** (do not hard-fail). Runtime-touching stages still require `worktree.runtime_isolation: ephemeral_per_worktree` (REQ-T-08), else they stay checklist-only and main runs them serially. `auto` also needs a one-time `bypassPermissions` grant + the §0-A unattended charter + concurrency cap + hard deadline + kill switch.

## 4. Invariants the dispatched sessions must preserve (REQ-C-04)

- **No screen tests in dispatched sessions.** Shared docker/DB/port would collide, so worktree sessions produce **verification checklists only** (Stage 8). The **main** session runs screen tests **serially after merge**.
- Each session runs the full two gates (Stage 4 plan, Stage 7 test result); gate strength is identical to the serial `/sdp` path.

## 5. After sessions complete

Main integrates each task after its session finishes (incremental integration), then runs the deferred screen tests serially. Report per-task status.

> Inferred vs documented: roles, handover/contract, the no-screen-test invariant, per-artifact GATE_LOG keying, and the `manual|auto` mode are documented (REQ-C-04/05/06/07, §12). Both modes are now backed — `dispatch.worktree_mode` in `.sdp/defaults.yaml` selects the mode and `scripts/run_segment_tmux.sh` is vendored. `auto` still requires `tmux`+`claude` and a permissive classifier; when unavailable it degrades to `manual`. The per-worktree audit-ndjson aggregation and live headless-session execution are not built/tested in the sandbox — see `docs/KNOWN_GAPS.md`.
