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

**`--reviewer claude` is not optional here.** The stage documents do carry the rule in prose, but their shell blocks stay bare. `core/` is shared by both hosts, so its gate examples are written in the Claude Code form — no `--reviewer`, because there the CLI default (`codex`) is already the opposite model. Copy one of those blocks unchanged on this host and the default makes Codex review Codex's own work, which is issue #3 in the other direction. On the Codex side the reviewer is always Claude: the MCP tool, or the CLI with `--reviewer claude` pinned.

Never ask agy after Claude returns a clean content `BLOCK:`. agy fallback is only for Claude missing, nonzero, timeout, empty, or invalid output.

## Halted gate

A halt (`.halt`, `max_block`, identical-reason-twice, escalation stall, or a team `decision=halt`) is terminal for that artifact. The gate prints the full procedure in the halt body; follow it.

- Your only move is to **stop and report**: artifact path, halt reason, cumulative BLOCK count, the gist of the last finding, what you resolved and what you did not.
- `RESET` / `OVERRIDE` / `PIVOT_RESET` and `SDP_GATE_OVERRIDE` are human-only. Do not use them, and **do not offer them to the user as options**. There is no gate command that deletes `.halt`.
- Team markers are not consulted after a halt, so preparing or recording one changes nothing.
- When the halt is a **scope** problem — each round raised a different defect rather than the same one — the sanctioned recovery is a split. Prepare it with the MCP tool `sdp_prepare_split` (or `python3 scripts/review_gate.py prepare-split <parent> --split-child <a> --split-child <b> --split-rationale "<why>"`), which writes a request file and no gate state. A human records it at a terminal; you never run `record-split`. The parent then answers `artifact was split; gate the children`, and each child starts its own counter.
