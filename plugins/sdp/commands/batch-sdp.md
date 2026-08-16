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

- **`agent_tool` (default, recommended).** Delegate each segment to a subagent via the **Task tool**. This is compatible with the codex auto-mode classifier and needs no external process. Applies whenever the anchor-selected `defaults.yaml` sets no `dispatch.batch_engine` — check the file the anchor actually selected, which is frequently user-global, rather than assuming the default because no project-local `.sdp/defaults.yaml` exists.
- **`tmux_long_lived` (opt-in).** Drives each segment in a long-lived **Codex** tmux session via `${CLAUDE_PLUGIN_ROOT}/scripts/run_segment_tmux.sh`; Claude Code remains review-gate only. Selected by `dispatch.batch_engine: tmux_long_lived` in the anchor-selected `defaults.yaml` — discovery runs project `.sdp/` → project `scripts/sdp/` → `$XDG_CONFIG_HOME/sdp/` when explicitly set, otherwise passwd-home `~/.config/sdp/` → passwd-home `~/.sdp/`, first safe existing candidate wins, and a user-global file counts. Requires `tmux`+`codex`+`git` and a git-backed `SDP_SESSION_CWD`; unavailable tools/cwd fall back to `agent_tool`. Per-segment lifecycle remains `init` → `continue` → `shutdown`; completion comes from `STATUS.md`, never TUI scraping.

## 4. Unattended safety

Under unattended execution keep the core's guarantees: never self-authorize a blocked artifact, stop/report if a segment cannot pass its gate, and run team review before repeated rewrite attempts after content `BLOCK:`. If the gate escalates and no valid `TEAM_REVIEW`/`TEAM_CARRY` marker exists, **stop and report**. Run `review_gate.py prepare-marker <artifact>` and hand the request file to the human. Never append a marker to a gate log yourself — that is a human action, and `record-marker` will refuse without a terminal and a token.

> The tmux engine now launches Codex workers and uses Claude only for review gates. Real headless Codex sessions are not exercised in CI; see `docs/KNOWN_GAPS.md`.
