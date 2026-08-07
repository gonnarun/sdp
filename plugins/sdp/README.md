# SDP — Staged Development Process

**A language-agnostic Claude Code / Codex plugin that turns an ad-hoc "spec → plan → build → test" habit into a repeatable, gated workflow — with a cross-model review gate that runs off raw CLIs and fails closed.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/gonnarun/sdp/blob/master/LICENSE)

SDP gives an agent session a fixed spine — eight numbered stages, two mandatory review gates, and an escalation state machine that refuses to let a stuck planner burn tokens in place. The reviewer at each gate is **the opposite model from whoever authored the artifact**, so no agent can approve its own work.

---

## Why SDP

- **Language/tool agnostic** — the core holds no `gradle` / `npm` / `Flyway` / DB-schema literals. Every build/test/migrate command is injected as project config. Works for Java, Node, Python, Go, Rust, or a plain library with no server.
- **A gate that survives plugin loss** — the review gate runs off the raw `codex` / `claude` CLIs. No companion plugin, no marketplace, no version-scan — just the binary on your `PATH`, then Fail-Close.
- **Cross-model review** — Claude-authored artifacts are reviewed by codex; codex-authored artifacts are reviewed by Claude. Self-review is structurally prevented, and the test suite asserts it.
- **Real-world tests, not just units** — the test stage mandates a floor of *smoke + integration against a real backing service* (local DB / local server, or a designated test DB/server), not mocks.
- **Resource-aware escalation** — after 6 consecutive gate BLOCKs, planner-solo execution is hard-blocked and a team re-review is forced on every even round.
- **Clean stage numbering** — stages are plain integers **1…8**, never `0 / 0.5 / 2.5`.

---

## Requirements

| | |
|---|---|
| **Host** | Claude Code with plugin support, and/or the `codex` CLI with plugin support |
| **Python** | 3.9+ (standard library only — no pip installs) |
| **Reviewer CLIs** | `codex` (≥ 0.141.0) and/or `claude` on `PATH`. At least one is required; the gate reviews with the *opposite* one from the author. |
| **git** | Required — `worktree-dispatch` creates worktrees |
| **Optional** | `tmux` (long-lived batch engine), `shellcheck` (lint), `agy` (fallback reviewer — see below) |

**About `agy`.** `agy` is an optional third-party multi-model reviewer CLI. When the primary reviewer hits an *infrastructure* failure (binary missing, timeout, empty or malformed output), the gate tries `agy` before failing closed. It is **not required**: with no `agy` installed the gate simply Fail-Closes to `BLOCK: INFRA_ERROR` instead, which is the safe outcome. A content `BLOCK:` from the primary reviewer is terminal and is *never* sent to `agy` for override.

---

## Install

### Claude Code

```
/plugin marketplace add gonnarun/sdp
/plugin install sdp
```

### Codex

```
codex plugin marketplace add /path/to/sdp
codex plugin add sdp@sdp-local
```

Codex packaging lives in `.codex-plugin/plugin.json`, with a bundled MCP server in `.mcp.codex.json`. The Codex-side review gate is exposed as MCP tool `claude_review_gate`.

### Verify the toolchain

```
python3 scripts/review_gate.py doctor    # reports claude / codex / agy presence + versions
```

Codex-side gate order:

```
Claude Code review
  → agy fallback only when Claude has infra/format failure
    → Fail-Close BLOCK: INFRA_ERROR
```

Claude content `BLOCK:` is terminal. It is never sent to agy for override.

### Claude/Codex role mapping and cost policy

Claude Code keeps the agent types and `opus`/`sonnet`/`haiku` model profile in the shared core unchanged. The Codex skill adds an execution overlay: high-reasoning Claude roles become planning/evaluation intent, exploration roles become bounded subagents, and runner roles use shell tools directly. Codex does not currently expose a per-subagent model, reasoning-effort, token, or billing selector, so the overlay never claims a model pin.

Codex controls usable cost axes instead: agent count, fan-out, surface-aware lane collapse, direct tool use, compact evidence, duplicate-work avoidance, and early stop. Instruction-level spawn ceilings are S=0, M=2, L=3, XL=5; explicit team requests, High-impact separation, or gate escalation may exceed them with a recorded reason. These are orchestration rules, not runtime-enforced token or billing guarantees.

`CLAUDE_GATE_MODEL` affects only the isolated Claude reviewer process. It does not select Codex main or subagent models. Adversarial review stops on the first `ALLOW:`, counts only content `BLOCK:` verdicts toward the maximum of 13, excludes `INFRA_ERROR`, records provider/revision/correction evidence, and forbids attempt 14. This preserves team execution, independent cross-validation, and Claude-gate safety without changing Claude Code's native workflow.

---

## Quick start

```
/sdp add a per-user login attempt limit
```

That runs Stages 1–8 in the current session: it interviews you for scope, assigns REQ-IDs, investigates the current code, writes a design + plan, submits the plan to **Gate A**, implements, writes and runs real-backing-service tests, submits results to **Gate B**, and finishes with a verification checklist. Deliverables land under `.private/sdp-artifacts/{date}/{topic}/`.

To adopt it in your own project, drop a thin config in `.sdp/defaults.yaml` (see [Configuration](#configuration)) — the plugin owns everything else.

---

## Commands

| Command | Use it for | How it runs |
|---|---|---|
| **`/sdp`** | A single task, start to finish. | Full SDP workflow inline in the current session, serial. Small tasks take a fast-path. |
| **`/batch-sdp`** | A large scope that should be split and run unattended. | Splits into segments and delegates them (Agent-tool by default; long-lived tmux opt-in). |
| **`/worktree-dispatch`** | Several independent tasks in parallel. | You do only Stage 1 (interview); each task gets a handover that another session runs as the full SDP workflow in its own git worktree. |
| **`/precompact`** | Manual context compaction prep. | Writes a gitignored progress snapshot and prints a resume prompt for the next context. |

The first three share **one SDP core** — identical Stage 1–8, identical two gates, identical evaluator PASS. Parallelism never weakens the gate. `/precompact` is a utility command and does not run the SDP core.

A per-command reference with examples is in [`COMMAND_MANUAL.md`](https://github.com/gonnarun/sdp/blob/master/COMMAND_MANUAL.md).

---

## The workflow (Stages 1–8)

```
1 Interview            → scope the work with the user
2 Normalize reqs       → assign REQ-IDs, coverage map
3 Current-state report → investigate the existing code
4 Design + Plan        → design section (language-neutral) then implementation plan   ── Gate A
5 Implement
6 Test plan
7 Test execution       → real-world tests against a live backing service              ── Gate B
8 Verification checklist
```

**Stage 4** is *design-led, plan-inclusive*: a language-neutral design section first, then a stack-specific plan. High-risk / large / large-brownfield-delta work is promoted to a standalone design document with an earlier design gate.

---

## The gate (Gate A / Gate B)

At Stage 4 and Stage 7 an external reviewer returns `ALLOW:` or `BLOCK:`. Resolution order:

```
companion plugin (accelerator, optional)
  → raw CLI fresh review                    ← works with no plugin installed
    → agy fallback (infra failure only)
      → Fail-Close BLOCK
```

- **Contract**: stdout first line `ALLOW:` / `BLOCK:`, exit `0` / `1`. The plugin only *calls* the script — no duplicated logic.
- **3-state verdict**: `ALLOW` / `BLOCK` / `INFRA_ERROR` (tooling unavailable / timeout / empty / malformed) so infrastructure hiccups are never mistaken for a real rejection.
- **Concurrency-safe**: each artifact's state decision is serialized by a per-artifact, KEY-namespaced `fcntl.flock` lock (`review_gate_<KEY>.lock`) — fail-closed on timeout and released by the kernel on process death (no TTL, no stale-reclaim) — so parallel worktrees and batch segments never race on one artifact's counter.
- **Read-only**: the reviewer runs `-s read-only` and cannot modify your repo.
- **Prompt-injection resistant**: artifact content is wrapped as untrusted data, artifact paths are validated inside the workspace, the reviewer runs with an empty tool allowlist and no session persistence, and workspace-local reviewer binaries are rejected.

### Escalation (≥ 6 BLOCKs)

| Round | Planner-solo | Required |
|---|---|---|
| 1–5 | allowed | — |
| 6, 8, 10, 12 (even) | **blocked** | `TEAM_REVIEW` (roster ≥ 2, root-cause table, decision) |
| 7, 9, 11 (odd) | **blocked** | `TEAM_CARRY` (retain the team) |
| 12 | — | `.halt` + report to user |

Planner-solo is a hard block across the entire 6+ range — the gate refuses to re-run the reviewer until a valid team roster is recorded in the gate log — a fail-closed check on log content, not a barrier against a same-uid writer who can append to that log.

### Recording a team-review marker

- `review_gate.py --cwd DIR prepare-marker <artifact> --marker-roster a,b --marker-outputs p1,p2` — composes the marker and writes a request file.
- `review_gate.py --cwd DIR record-marker <artifact> --marker-*` — appends the marker to the gate log.

`prepare-marker` writes a request file for a human to read; `record-marker` is the only command that writes to a gate log, and it requires a terminal and a human-provisioned token.

The marker is honor-plus-evidence: the gate checks roster cardinality, distinctness and output freshness, but the log is agent-writable same-uid and forgery cannot be fully prevented (`review_gate.py:1103-1104`).

Running `record-marker` twice is safe and the **second marker wins**: both lines stay in the log as an audit trail, and only the last is consumed by the escalation check. `--marker-decision pivot` and `--marker-decision halt` change gate state and additionally require `--i-am-recording-a-state-changing-decision` and a typed confirmation phrase.

Gate state operations are an operator procedure — see [`docs/GATE_OPERATIONS.md`](https://github.com/gonnarun/sdp/blob/master/docs/GATE_OPERATIONS.md).

---

## Configuration

Projects own a thin config; the plugin owns everything else. Discovery order:

```
$PROJECT_DIR/.sdp/         →  $PROJECT_DIR/scripts/sdp/
  →  $XDG_CONFIG_HOME/sdp/  →  ~/.sdp/
```

Project-local paths always win. Whichever file is selected is still subject to the **no-weakening** check: a user-global config can strengthen the base safety keys but never relax them.

```yaml
base_dir: .private/sdp-artifacts        # deliverable root (default)
output_locale: auto                     # auto | en | ko | ja | ...
sdp_version: "1.0"                      # pin the plugin version

build:   { ... }                        # opaque, project-specific commands
test:
  commands: { install, build, lint, unit, integration, contract, e2e, smoke, migrate, seed }
  layers:   { mandatory: [smoke, integration], risk_gated: [contract, e2e], supporting: [unit] }
  db:       { isolation: dedicated_test_db, dsn_env: TEST_DATABASE_URL }
  guards:   { prod_dsn_denylist: [...], require_test_marker: true }

gate:
  review_checklist_include: <path to project domain rules>   # optional

forced_ext: { ... }                     # project security rules (extend, never weaken the base)
```

Gate cadence, timeouts and halt limits live alongside it in `.sdp/gates.yaml`.

---

## Deliverables & language

Command deliverables land under:

```
${CLAUDE_PROJECT_DIR}/.private/sdp-artifacts/{YYYY-MM-DD}/{topic}/{doc-type}
```

- `.private/` is **auto-created and registered in `.gitignore`** on first run (idempotent — no duplicate lines).
- **Deliverable language follows your environment.** With `output_locale: auto`, generated documents (current-state report, plan, test results, checklists, handovers) are written in the language of the installed environment (`LC_ALL` / `LANG` / Claude Code UI locale), falling back to English.
- Plugin-facing assets (this README, the SDP core, command definitions) stay in **English**.
- Machine-parsed tokens — `ALLOW:` / `BLOCK:`, markers like `TEAM_REVIEW`, REQ-IDs, config keys — stay ASCII/English regardless of locale.

---

## Testing philosophy

Unit tests are *supporting*, not the spine. Every non-trivial task must clear a **mandatory floor**:

- **smoke** — the app/module boots and passes a health probe, and
- **integration ≥ 1** — against a **real backing service** (local DB / local server, or a designated test DB/server), not a mock.

Higher-risk changes add contract and e2e tiers. Destructive tests are Fail-Close guarded: a writeful test aborts unless the target DSN is on the test-marker allowlist. Test DB isolation defaults to a dedicated test database (Testcontainers recommended for ephemeral, language-agnostic, random-port runs).

---

## Using the gate without the plugin

The gate is intentionally decoupled. Any project — even one that never installs SDP — can drive the same review by calling `review_gate.py` directly:

```
# --reviewer = the OPPOSITE model of whoever authored the artifact (CLI default is codex):
python3 "$SDP_ROOT/scripts/review_gate.py" --cwd "$PWD" --reviewer codex  "<review prompt>" "<artifact-path>"   # Claude-authored → codex reviews
python3 "$SDP_ROOT/scripts/review_gate.py" --cwd "$PWD" --reviewer claude "<review prompt>" "<artifact-path>"   # codex-authored → Claude reviews
# → first stdout line: ALLOW: ... | BLOCK: ...   exit 0 | 1
```

`$SDP_ROOT` is the SDP checkout (the path is absolute so the fallback runs from any project cwd). The gate validates artifact paths inside the workspace, wraps artifact content as untrusted data, runs the selected reviewer first — `--reviewer` picks it (CLI default `codex`; pass `--reviewer claude` for codex-authored work), with agy as the fallback only on that reviewer's infra failure — with safe-mode/no-session-persistence/plan permissions and an empty tool allowlist, and rejects workspace-local reviewer binaries.

---

## Documentation

- [Requirements definition](https://github.com/gonnarun/sdp/blob/master/docs/20260703_SDP_requirements_definition_EN.md) — REQ-IDs, acceptance criteria
- [Stage-4 design record](https://github.com/gonnarun/sdp/blob/master/docs/20260703_SDP_stage4_design_EN.md)
- [Known gaps](https://github.com/gonnarun/sdp/blob/master/docs/KNOWN_GAPS.md) — advertised-but-not-implemented register, with code locations
- [Gate operations](https://github.com/gonnarun/sdp/blob/master/docs/GATE_OPERATIONS.md) — operator procedures for gate state

---

## Known limitations

See [`KNOWN_GAPS.md`](https://github.com/gonnarun/sdp/blob/master/docs/KNOWN_GAPS.md) for details and code locations.

- **`batch-sdp` `tmux_long_lived` engine** and **`worktree-dispatch` `auto` mode** are now **backed by the vendored `scripts/run_segment_tmux.sh`** (selected via `dispatch.*` in `.sdp/defaults.yaml`), but they require `tmux` **and** `claude` on `PATH` and a permissive codex auto-mode classifier; when unavailable they **fall back** to `agent_tool` (batch) / `manual` (worktree). Two residual gaps remain: no live headless-session test in CI (exit codes 7/124/125 unexercised), and per-worktree gate-audit ndjson is not aggregated to main.
- **`output_locale: auto` dual-copy** is an *authoring-time* instruction, not a runtime feature: `sdp-anchor.sh` resolves `auto` to a single environment locale, so nothing at runtime distinguishes `auto` (English canonical + synced copy) from a fixed `<locale>`. The Stage templates carry the authoring rule (REQ-U-08) that reads the mode from `.sdp/defaults.yaml`.
- **Gate-log integrity is honor-plus-evidence, not cryptographic.** The log is same-uid agent-writable; the gate validates structure and freshness, not authorship.
- **Token budget accounting is not live.** `dispatch.token_budget` enforces only when an external hook supplies `SDP_TOKENS_USED`; no such writer ships.

---

## Status

**Working, pre-1.0.** The plugin installs and runs on both hosts, the gate is exercised by ~350 assertions across 14 suites, and the source repo dogfoods SDP on itself. Interfaces (config keys, marker grammar, gate CLI) may still change before 1.0 — pin `sdp_version` if you depend on them.

---

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](https://github.com/gonnarun/sdp/blob/master/CONTRIBUTING.md). To report a security issue, see [SECURITY.md](https://github.com/gonnarun/sdp/blob/master/SECURITY.md).

---

## License

[MIT](https://github.com/gonnarun/sdp/blob/master/LICENSE) © 2026 run2u

---

## Deploying a change to the plugin

A repo-local commit changes nothing for any consumer, including live sessions. The plugin cache at `~/.claude/plugins/cache/sdp-marketplace/sdp/<version>/` is a plain, version-keyed **copy** — not a symlink and not a git checkout — so a change stays inert until a human performs all four steps:

1. `git push`
2. `git -C ~/.claude/plugins/marketplaces/sdp-marketplace pull`
3. Reinstall the plugin — this creates a new version-keyed cache directory, and the pre-commit hook has already bumped the version manifests as a cachebuster.
4. **Restart every live session.** The `.in_use/<pid>` refcount keeps old copies alive otherwise, and the restart is what stops an older engine from mis-counting a log head it does not know.
