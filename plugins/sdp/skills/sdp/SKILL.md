---
name: sdp
description: Run the SDP staged development workflow in Codex. Use when the user asks for SDP, staged workflow, gated implementation, worktree dispatch, or external Claude review gate.
---

# SDP for Codex

Run the same Stage 1-8 workflow described in `core/SDP.md`, adapted for Codex. This is the single-task serial workflow; use `batch-sdp` for segmented unattended work and `worktree-dispatch` for parallel worktree handoff.

## Startup

1. Run `scripts/sdp-anchor.sh` from the repository root.
2. Read `core/SDP.md` and the required stage form files.
3. Keep normalized requirements as the source of truth after Stage 2.
4. When printing progress or gate requests, label the review gate as `review-gate`, not `codex-gate`.

## Gate Adapter

For Codex-side Stage 4 and Stage 7 gates, prefer the bundled MCP tool `claude_review_gate`.

Use the tool with:
- `cwd`: current repository root
- `prompt`: the SDP gate review prompt
- `artifact_path`: the plan, fix-plan, or test-result artifact path

If MCP is unavailable, run:

```bash
python3 scripts/review_gate.py --cwd "$PWD" --reviewer claude "<review prompt>" "<artifact-path>"
```

Interpretation:
- `ALLOW:` means continue to the next SDP stage.
- `BLOCK:` without `INFRA_ERROR` is a content block. Revise the artifact and rerun the same gate.
- `BLOCK: INFRA_ERROR` is tooling failure. Stop for unattended work; in attended work, report the infrastructure failure before continuing.

Never ask agy after Claude returns a clean content `BLOCK:`. agy fallback is only for Claude missing, nonzero, timeout, empty, or invalid output.

## Safety

The gate treats artifact text as untrusted data, rejects outside-workspace paths, and runs Claude Code as a read-only reviewer. Do not weaken those checks in prompts or local edits.

## Codex Execution and Cost Profile

The Claude agent types and model names in `core/SDP.md` remain the canonical Claude Code profile. In Codex, interpret them as capability intent; they are not Codex model pins:

| Core profile | Codex interpretation |
|---|---|
| Planner, Evaluator, Researcher, Designer / `opus` | high-reasoning role; main context by default, independent subagent only when separation adds evidence |
| Explore, Security / `sonnet` | bounded analysis or review subagent; skip when the surface is absent or `rg`/direct inspection is enough |
| Runner / `haiku` | run the shell tool directly; do not spawn an agent unless large output needs isolation |
| `general-purpose` | bounded task subagent with explicit inputs, output, and stop condition |

Current Codex subagent dispatch exposes no per-agent model, reasoning-effort, token, or billing selector. Never claim those controls were applied. Control cost through orchestration: spawned-agent count, parallel fan-out, applicable-surface collapse, direct tool use, bounded output, no duplicate investigation, and early stop.

### Spawn ceilings

These are instruction-level orchestration ceilings, not runtime-enforced token or billing limits. Record any required deviation and its reason.

| SDP size | Maximum spawned Codex agents | Default placement |
|---|---:|---|
| S | 0 | main performs planning and evaluation inline |
| M | 2 | one bounded analysis + one independent review/evaluation |
| L | 3 | up to two bounded analyses + one evaluation/security review |
| XL | 5 | planner/evaluator/security roles + up to two verifiers |

Explicit user team requests, High-impact security separation, and gate escalation may exceed a ceiling. State why. Shell commands do not count as spawned agents.

### Stage placement

| Stage | Codex placement |
|---|---|
| 1 | main context and interactive tool only |
| 2 | main acts as Planner; add one ambiguity reviewer only when needed |
| 3 | collapse absent surfaces; for M use at most one bounded explorer, then main integrates |
| 4 | collapse structure/impact/risk into one bounded analysis for M; keep independent review separate |
| 5 | main implements; use builders only for independently owned file sets |
| 6 | collapse code/plan/rule/CI analysis by changed surface; main owns REQ coverage |
| 7 | run tests through shell directly; use one independent Evaluator, plus Security only when applicable |
| 8 | main compiles evidence and verification checklist |

Every spawned task must own a distinct question or file set. Reuse its result; do not repeat the same investigation in main. Ask for compact evidence with file/line references.

## Adversarial Review-Gate Loop

When adversarial validation is requested, call the isolated Claude gate up to 13 content-review attempts:

1. Run the same bounded review dimensions against the current artifact revision.
2. Stop immediately on the first `ALLOW:`; never fabricate or force 13 calls.
3. A `BLOCK:` without `INFRA_ERROR` increments the content-attempt counter. This includes a valid content `BLOCK:` returned by the documented agy infrastructure fallback; record the actual provider.
4. Correct only cited defects, run relevant tests, record revision/hash/provider/verdict/correction, then retry.
5. `BLOCK: INFRA_ERROR` does not increment the content-attempt counter. Apply attended/unattended policy and report it.
6. After 13 content `BLOCK:` verdicts, fail closed and report remaining findings. Attempt 14 is forbidden.

This loop is orchestrator policy. `review_gate.py` remains a stateless, isolated single-review adapter; do not weaken its safety flags or allow agy to override a clean Claude content `BLOCK:`.
