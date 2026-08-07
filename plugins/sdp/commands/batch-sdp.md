---
description: Split a large scope into segments and run each through the full SDP workflow unattended (Agent-tool by default).
argument-hint: [large scope description]
---

# /batch-sdp — split a large scope and run segments unattended

You are running **SDP** over a large scope that should be **split into segments and executed unattended**. This command is a thin dispatch adapter over the shared SDP core: every segment runs the identical Stage 1–8 + two Claude gates at identical strength (REQ-C-01/REQ-C-03). Splitting must never weaken or bypass the gate (per-artifact GATE_LOG keying keeps each segment's escalation independent — REQ-C-06).

Scope (raw request): **$ARGUMENTS**

## 1. Anchor (mandatory — REQ-P-03)

```bash
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/sdp-anchor.sh"
```

Confirm the runtime env was written before proceeding.

## 2. Split the scope into segments

Do a Stage 1 interview once for the whole scope (via `AskUserQuestion`), then decompose the scope into independent, ordered **segments**, each sized to be a self-contained SDP run. Record the segment list and their dependency order before executing (a segment that depends on another runs after it).

## 3. Execute each segment through the SDP core

For every segment, run the full workflow in `${CLAUDE_PLUGIN_ROOT}/core/SDP.md` (Stages 1–8, both gates, fix loop). Because this is unattended, `INFRA_ERROR` pauses the segment and notifies the user instead of treating tooling failure as content approval.

**Execution engine (config-selectable — REQ-C-03):**

- **`agent_tool` (default, recommended).** Delegate each segment to a subagent via the **Task tool**. This is compatible with the codex auto-mode classifier and needs no external process. Use this unless the project explicitly opts into tmux.
- **`tmux_long_lived` (opt-in).** Drives each segment in a long-lived tmux session via the vendored `${CLAUDE_PLUGIN_ROOT}/scripts/run_segment_tmux.sh`. Selected by `dispatch.batch_engine: tmux_long_lived` in `.sdp/defaults.yaml`. **Capability probe first**: this engine works only if BOTH `tmux` and `claude` are on `PATH` and the project's codex auto-mode classifier does not block headless/tmux/`bypassPermissions` loops (§4.6). If either tool is missing the script exits `5` — treat that as "unavailable" and **fall back to `agent_tool`** (do not hard-fail). Per-segment lifecycle: `run_segment_tmux.sh <batch_dir> <segment_dir> init` for the first segment, then `… continue` for each subsequent one, `… shutdown` at the end. Completion is signalled by each segment's `STATUS.md` (never scrape the TUI). Set `SDP_SESSION_CWD` to the segment/worktree dir so the gate's cwd-scoped KEY stays per-segment.

## 4. Unattended safety

Under unattended execution keep the core's guarantees: never self-authorize a blocked artifact, stop/report if a segment cannot pass its gate, and run team review before repeated rewrite attempts after content `BLOCK:`. If the gate escalates and no valid `TEAM_REVIEW`/`TEAM_CARRY` marker exists, **stop and report**. Run `review_gate.py prepare-marker <artifact>` and hand the request file to the human. Never append a marker to a gate log yourself — that is a human action, and `record-marker` will refuse without a terminal and a token.

> Inferred vs documented: the `agent_tool`/`tmux_long_lived` selection and unattended semantics are documented (REQ-C-03, §12). Both are now backed — `dispatch.batch_engine` in `.sdp/defaults.yaml` selects the engine and `scripts/run_segment_tmux.sh` is vendored. The tmux engine still requires `tmux`+`claude` present and a permissive classifier; when unavailable it degrades to `agent_tool`. Real headless sessions are not exercised in the sandbox test — see `docs/KNOWN_GAPS.md`.
