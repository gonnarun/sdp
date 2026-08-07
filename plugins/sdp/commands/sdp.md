---
description: Run the full SDP staged workflow (Stages 1–8, two Claude gates) on a single task, serially, in this session.
argument-hint: [task description]
---

# /sdp — single-task staged workflow

You are running the **SDP** (Structured Development Process) workflow for one task, start to finish, **serially in this session**. This command is a thin dispatch adapter over the shared SDP core — it adds no gate logic of its own (REQ-C-01: all three commands run identical Stage 1–8 + two gates at identical strength).

Task (raw request): **$ARGUMENTS**

## 1. Anchor (mandatory — REQ-P-03)

Run the anchor so every later Bash call and `review_gate.py` can resolve `SDP_ROOT` / `base_dir` / locale from a written runtime env (do not rely on `${CLAUDE_PLUGIN_ROOT}` propagating into later Bash calls — §4.9):

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdp-anchor.sh"
```

This prints the runtime-env path (`${base_dir}/.sdp_runtime.env`) and auto-creates `.private/` + registers it in `.gitignore`. Confirm it succeeded before proceeding.

## 2. Load the core and follow it

Read `${CLAUDE_PLUGIN_ROOT}/core/SDP.md` and execute it exactly: Stages 1–8, the stage form files (`core/Stage1_interview.md` … `core/Stage8_verification.md`), the progress indicator at every transition, the review-gate plan review after Stage 4, the review-gate test-result review after Stage 7, the automatic fix loop (max 12), and the Agent-team roles. The core is the single source of truth for the workflow — this adapter does not restate or override it.

## 3. Orchestration specific to /sdp

- **Serial, in-session.** No segment splitting, no parallel worktrees, no delegation — run every stage in this session in order.
- **Fast-path for small tasks.** For a small, low-impact task that meets the core's "Exception — direct implementation" criteria (obvious one/two-line fix, complete user spec, or explicit "start now"), you MAY collapse stages — but still record the one-line note the core requires, and the two Claude gates (Stage 4 plan, Stage 7 test result) still apply to any code change. Never skip a gate to save time.
- **Attended mode** is the default; on `INFRA_ERROR`, report the Claude/agy tooling failure before any stage advance.

Begin at Stage 1 (Interview) using the `AskUserQuestion` tool, unless the user said "just build it" / "start now" (then go to Stage 2), per `core/SDP.md`.
