---
name: batch-sdp
description: Split a large scope into independent segments and run each through the full SDP Stage 1-8 workflow in Codex, with Claude review gates and agy fallback only on infrastructure failure.
---

# Batch SDP for Codex

Use when the user asks for `batch-sdp`, batch SDP, segmented SDP, large-scope SDP, or unattended segmented execution.

## Startup

1. Run `scripts/sdp-anchor.sh` from the repository root.
2. Read `core/SDP.md`, `commands/batch-sdp.md`, and required stage form files.
3. Treat `commands/batch-sdp.md` as dispatch guidance only; Codex-side gates are `review-gate` via `claude_review_gate` MCP or `python3 scripts/review_gate.py --reviewer claude`.
4. When printing progress or gate requests, label the review gate as `review-gate`, not `codex-gate`.

## Workflow

1. Do Stage 1 interview once for the whole scope.
2. Split the request into ordered, independent segments with dependencies recorded.
3. For each segment, run the full SDP core from Stage 2 through Stage 8.
4. Preserve per-segment artifacts under the anchored `base_dir`.
5. Stop unattended execution on `INFRA_ERROR` only; report the blocked segment and artifact. A content `BLOCK:` is not a stop — it follows the core fix loop to its documented cap (max_block), and the batch continues. (`run_segment_tmux.sh` exit 12 = user input needed → stop+report; 10/11 = content outcome, not a stop.)

## Execution

- Prefer available Codex subagents for independent segments.
- If no subagent tool is available, run segments serially and say so.
- Use `scripts/run_segment_tmux.sh` only when the project explicitly opts into `dispatch.batch_engine: tmux_long_lived` and `tmux` + `codex` are available. It launches Codex implementation workers; Claude Code remains review-gate only.

## Gate Adapter

For every Stage 4 plan, promoted design, fix-plan, and Stage 7 result gate:

- Prefer MCP tool `claude_review_gate`.
- Fallback:

```bash
python3 scripts/review_gate.py --cwd "$PWD" --reviewer claude "<review prompt>" "<artifact-path>"
```

Never ask agy after Claude returns a clean content `BLOCK:`. agy fallback is only for Claude missing, nonzero, timeout, empty, or invalid output.
