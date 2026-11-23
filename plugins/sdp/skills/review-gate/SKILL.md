---
name: review-gate
description: Review one existing artifact through SDP's normal cross-model gate without running Stages 1-8. Use when the user invokes the review gate alone, not for implementation or a full SDP workflow.
---

# Standalone SDP review gate

Review the named artifact once with the existing `scripts/review_gate.py`. Do not run the SDP stages, edit the artifact, or create a new gate. Obtain review criteria from the request; ask for the artifact or its author host only when that cannot be determined.

The primary reviewer must be the model **opposite the artifact author**, not whichever CLI happens to work. For an artifact authored in the current session, use the current host. For an artifact authored elsewhere, use its known author host; if unknown, ask before invoking the gate.

| Artifact author | Primary reviewer | Gate entry |
|---|---|---|
| Codex | Claude | Prefer bundled `claude_review_gate` MCP with `cwd`, `prompt`, and `artifact_path`. If unavailable, call the bundled `scripts/review_gate.py` with `--reviewer claude`. |
| Claude Code | Codex | Call the bundled `scripts/review_gate.py` with `--reviewer codex`. Do **not** use `claude_review_gate`: that MCP entry is pinned for Codex-authored work. |

Resolve the bundled script from this skill's plugin root, not from the reviewed project's cwd. Pass the project root as `--cwd` and the artifact path as a separate argument. Keep the review prompt limited to the user's criteria and the artifact's role; the engine reads and bounds the artifact itself.

For CLI fallback, substitute absolute paths in the appropriate host form (the plugin root is two directories above the `skills/review-gate/` folder):

```bash
python3 "/absolute/plugin/root/scripts/review_gate.py" --cwd "/absolute/project/root" --reviewer claude "<review prompt>" "/absolute/artifact-path"
```

The line above is for a Codex-authored artifact. For a Claude-authored artifact, use the same command with `--reviewer codex`. Never copy a bare default-reviewer command between hosts.

The existing gate may try agy **only after primary-reviewer infrastructure failure**. agy never overrides a valid content `BLOCK:`. A content `BLOCK:` whose findings are all labelled `advisory` may come back as `ALLOW: advisory-only findings; …` (issue #6): treat the reviewer output that follows as residuals to apply or waive. Honor `severity_verdict`, `require_primary_verdict` and all other configured gate policy; do not switch to agy as primary or invent another fallback. If every allowed provider fails, report `BLOCK: INFRA_ERROR`.

Report the exact `ALLOW:` or `BLOCK:` result, actual provider, and actionable findings. MCP returns the provider with its result; for CLI, read the matching entry in `.private/sdp-artifacts/gate-audit.ndjson`. If no audit row exists, say provider unknown rather than guessing. A content `BLOCK:` ends this invocation; revise or retry only on a separate request. Never treat an infrastructure failure as review approval.
