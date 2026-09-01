# SDP — Staged Development Process

**A language-agnostic Claude Code / Codex plugin that turns an ad-hoc "spec → plan → build → test" habit into a repeatable, gated workflow — with a cross-model review gate that runs off raw CLIs and fails closed.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Tests](https://github.com/gonnarun/sdp/actions/workflows/ci.yml/badge.svg)](https://github.com/gonnarun/sdp/actions/workflows/ci.yml)

SDP gives an agent session a fixed spine — eight numbered stages, two mandatory review gates, and an escalation state machine that refuses to let a stuck planner burn tokens in place. The reviewer at each gate is **the opposite model from whoever authored the artifact**, so no agent can approve its own work.

---

## Why SDP

- **Language/tool agnostic** — the core holds no `gradle` / `npm` / `Flyway` / DB-schema literals. Every build/test/migrate command is injected as project config. Works for Java, Node, Python, Go, Rust, or a plain library with no server.
- **A gate that survives plugin loss** — the review gate runs off the raw `codex` / `claude` CLIs. No companion plugin, no marketplace, no version-scan — just the binary on your `PATH`, then Fail-Close.
- **Cross-model review** — Claude-authored artifacts are reviewed by codex; codex-authored artifacts are reviewed by Claude. Self-review is structurally prevented, and the test suite asserts it.
- **Real-world tests, not just units** — the test stage mandates a floor of *smoke + integration against a real backing service* (local DB / local server, or a designated test DB/server), not mocks.
- **Resource-aware escalation** — once an artifact's *cumulative* gate BLOCK count reaches `cadence.escalate_from` (default 6), planner-solo execution is hard-blocked and a recorded team marker is required to proceed. `cadence.marker_span` (default 1) sets how many rounds one marker covers.
- **Clean stage numbering** — stages are plain integers **1…8**, never `0 / 0.5 / 2.5`.

---

## Requirements

| | |
|---|---|
| **Host** | Claude Code with plugin support, and/or the `codex` CLI with plugin support |
| **Python** | 3.9+ (standard library only — no pip installs) |
| **Reviewer CLI** | The gate reviews with the model **opposite** the author, so the one you need is the one your host is *not*: on **Claude Code** you need `codex` (≥ 0.141.0) on `PATH`; on **Codex** you need `claude`. Using both hosts means installing both. Having only your own host's CLI leaves the gate with no reviewer and it fails closed to `INFRA_ERROR`. |
| **git** | Required — `worktree-dispatch` creates worktrees |
| **Optional** | `tmux` (long-lived batch engine), `agy` (fallback reviewer — see below) |
| **To run the test suite** | `shellcheck` — the lint step is not skippable; see [Test](#test) |

**About `agy`.** `agy` is an optional third-party multi-model reviewer CLI. When the primary reviewer hits an *infrastructure* failure (binary missing, timeout, empty or malformed output), the gate tries `agy` before failing closed. It is **not required**: with no `agy` installed the gate simply Fail-Closes to `BLOCK: INFRA_ERROR` instead, which is the safe outcome. A content `BLOCK:` from the primary reviewer is terminal and is *never* sent to `agy` for override.

---

## Install

SDP installs as a plugin on either host. The two hosts keep **separate** plugin caches, so installing on one does not install on the other — run the block for each host you use.

### Claude Code

From inside a Claude Code session:

```
/plugin marketplace add gonnarun/sdp
/plugin install sdp@sdp-marketplace
```

Or from a shell:

```bash
claude plugin marketplace add gonnarun/sdp
claude plugin install sdp@sdp-marketplace
```

### Codex

```bash
codex plugin marketplace add gonnarun/sdp
codex plugin add sdp@sdp-marketplace
```

`codex plugin marketplace add` also accepts a local path or an HTTPS/SSH Git URL, so `codex plugin marketplace add https://github.com/gonnarun/sdp.git` and `codex plugin marketplace add /path/to/a/clone` work too.

Codex packaging lives in `plugins/sdp/.codex-plugin/plugin.json`, with a bundled MCP server in `plugins/sdp/.mcp.codex.json`. The Codex-side review gate is exposed as MCP tool `claude_review_gate`.

### Restart the session

**Required, on both hosts.** The gate engine is a running process; installing or updating the plugin does not swap it. `/reload-plugins` refreshes skills, commands and hooks but leaves the engine on the old version — see `NC-19` in the known-gaps register. Start a new session before using the gate.

### Verify the toolchain

From a checkout:

```bash
python3 scripts/review_gate.py doctor
```

From an installed plugin — the two hosts keep separate caches, and several versions coexist in each by design, so pick the newest:

```bash
# Claude Code
python3 "$(ls -d ~/.claude/plugins/cache/sdp-marketplace/sdp/*/ | sort -V | tail -1)scripts/review_gate.py" doctor

# Codex
python3 "$(ls -d ~/.codex/plugins/cache/sdp-marketplace/sdp/*/ | sort -V | tail -1)scripts/review_gate.py" doctor
```

`doctor` reports two axes — `toolchain` (claude / codex / agy presence and versions) and `gate-state` — and exits non-zero if either is unhealthy.

---

## Update

Updating is two steps per host — refresh the marketplace snapshot, then upgrade the installed plugin — followed by a session restart.

### Claude Code

```bash
claude plugin marketplace update sdp-marketplace
claude plugin update sdp@sdp-marketplace
```

### Codex

```bash
codex plugin marketplace upgrade sdp-marketplace
codex plugin add sdp@sdp-marketplace
```

Then **restart the session** on that host. `claude plugin update` says so itself; the reason is the same running-engine problem described above.

Confirm the update took, by running the **installed** engine — not a checkout copy, which would report on itself — against the project you care about:

```bash
cd /path/to/your/project

# Claude Code
python3 "$(ls -d ~/.claude/plugins/cache/sdp-marketplace/sdp/*/ | sort -V | tail -1)scripts/review_gate.py" --cwd . doctor | grep anchor:

# Codex
python3 "$(ls -d ~/.codex/plugins/cache/sdp-marketplace/sdp/*/ | sort -V | tail -1)scripts/review_gate.py" --cwd . doctor | grep anchor:
```

`doctor` reports `anchor: current` when the project's recorded runtime matches the installed plugin, and `anchor: STALE` when it still names an older one. A stale anchor is a report, not a failure — re-run the anchor in that project to clear it:

```bash
CLAUDE_PROJECT_DIR="$PWD" bash "<plugin>/scripts/sdp-anchor.sh"
```

The `/sdp` command runs the anchor itself on entry, so a project you are about to use SDP in needs no manual step.

Older plugin versions stay on disk after an update because live sessions still hold them. That is expected; deleting them breaks running sessions.

## Test

No installation is needed to run the suite — clone the repository and run:

```bash
git clone https://github.com/gonnarun/sdp.git
cd sdp
bash tests/run.sh
```

`tests/run.sh` is the only entry point. `--fast` runs the subset the pre-commit hook uses:

```bash
bash tests/run.sh --fast      # regen-check + orphan-detector + packaging + smoke + lint
```

| To run the suite | |
|---|---|
| `bash`, `git`, `python3` 3.9+ | required |
| `shellcheck` | **required** — `tests/run.sh` runs the lint step on both the `--fast` and full paths and fails if it is absent |
| `tmux`, `codex` | optional — the dispatch suites print `SKIP` and pass without them |
| `claude` / `codex` / `agy` | **not required** — the gate suites drive the engine through a stub binary resolver, and `tests/smoke.sh` self-skips `doctor`'s toolchain axis when no reviewer CLI resolves |

The suite is fully offline: no network, no model calls, no reviewer account. It must be green from any working directory.

## Quick start

```
/sdp add a per-user login attempt limit
```

That runs Stages 1–8 in the current session: it interviews you for scope, assigns REQ-IDs, investigates the current code, writes a design + plan, submits the plan to **Gate A**, implements, writes and runs real-backing-service tests, submits results to **Gate B**, and finishes with a verification checklist. Deliverables land under `.private/sdp-artifacts/{date}/{topic}/`.

User-global config works across repositories with no setup in each repo. Add `.sdp/defaults.yaml` only when that project deliberately overrides the global defaults (see [Configuration](#configuration)).

---

## Commands

| Command | Use it for | How it runs |
|---|---|---|
| **`/sdp`** | A single task, start to finish. | Full SDP workflow inline in the current session, serial. Small tasks take a fast-path. |
| **`/batch-sdp`** | A large scope that should be split and run unattended. | Splits into segments and delegates them (Agent-tool by default; long-lived tmux opt-in). |
| **`/worktree-dispatch`** | Several independent tasks in parallel. | You do only Stage 1 (interview); each task gets a handover that another session runs as the full SDP workflow in its own git worktree. |
| **`/precompact`** | Context compaction prep. | Writes a gitignored progress snapshot and prints a resume prompt. With the shipped hooks armed, the snapshot is taken and the resume is injected automatically around compaction. |

The first three share **one SDP core** — identical Stage 1–8, identical two gates, identical evaluator PASS. Parallelism never weakens the gate. `/precompact` is a utility command and does not run the SDP core.

A per-command reference with examples is in [`COMMAND_MANUAL.md`](COMMAND_MANUAL.md) ([한국어](COMMAND_MANUAL.ko.md)).

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

### Escalation (default configuration)

Rounds and kinds below are the **shipped default** — `escalate_from: 6`, `marker_span: 1`, `review_on: even`, `max_block: 13`. Both cadence keys are configurable; see [Configuration](#configuration).

| Round | Planner-solo | Required |
|---|---|---|
| 1–5 | allowed | — |
| 6, 8, 10, 12 (even anchor) | **blocked** | `TEAM_REVIEW` (roster ≥ 2, root-cause table, decision, fresh `outputs=`) |
| 7, 9, 11 (odd anchor) | **blocked** | `TEAM_CARRY` (retain the team) |
| 13 | — | `.halt` + report to user |

At `marker_span: 1` every round is its own window, so the anchor is the live round and the table reads directly.
This repository's own `.sdp/gates.yaml` deliberately runs `escalate_from: 8` / `marker_span: 4`, with the `cadence.relaxation_ack` that `sdp-regression.sh` requires for any value past the baseline. It is an example of the override, not the default. At a wider span one marker covers the whole window and the **anchor** — the round that opened it — fixes the required kind for every round inside.

Planner-solo is a hard block across the entire 6+ range — the gate refuses to re-run the reviewer until a valid team roster is recorded in the gate log — a fail-closed check on log content, not a barrier against a same-uid writer who can append to that log.

### Recording a team-review marker

- `review_gate.py --cwd DIR prepare-marker <artifact> --marker-roster a,b --marker-outputs p1,p2` — composes the marker and writes a request file.
- `review_gate.py --cwd DIR record-marker <artifact> --marker-*` — appends the marker to the gate log.

`prepare-marker` writes a request file for a human to read; `record-marker` is the only command that writes to a gate log, and it requires a terminal and a human-provisioned token. The request file carries the exact command as a single runnable line, pinned to the engine that composed it — open it and paste.

The marker is honor-plus-evidence: the gate checks roster cardinality, distinctness and output freshness, but the log is agent-writable same-uid and forgery cannot be fully prevented (`review_gate.py:1103-1104`).

**What `--marker-roster` should name.** The gate checks that the roster holds at least two **distinct entries** — a lone member, planner or otherwise, is refused, which is what "no planner-solo" means in practice. It does **not** check who those entries are or that a review happened, so the names are a claim you are accountable for. Name the **Agent-team roles that actually examined the artifact** — Planner, Evaluator, Explorer, Researcher, Designer, Runner, Security — each from its own angle, and cite what they produced in `--marker-outputs`. Escalation exists to replace one model looking again with several perspectives looking once. **Do not list `agy`**: it is the infrastructure fallback for the primary reviewer, not a team member.

Running `record-marker` twice is safe and the **second marker wins**: both lines stay in the log as an audit trail, and only the last is consumed by the escalation check. `--marker-decision pivot` and `--marker-decision halt` change gate state and additionally require `--i-am-recording-a-state-changing-decision` and a typed confirmation phrase.

### After a halt: report, or split

A halt is terminal for that artifact. The gate prints the whole procedure in the halt body — an agent's only move is to **stop and report** (artifact path, halt reason, cumulative BLOCK count, last finding, resolved vs unresolved). `RESET` / `OVERRIDE` / `PIVOT_RESET` and `SDP_GATE_OVERRIDE` are human-only levers and an agent must not use them **or offer them as options**; team markers are not consulted at all once `.halt` exists.

When the halt is really a **scope** problem — every round raises a different defect rather than the same one — the sanctioned recovery is to split the artifact:

- `review_gate.py --cwd DIR prepare-split <parent> --split-child <a> --split-child <b> --split-rationale "<why>"` — writes a request file, touches no gate state. On codex this is the MCP tool `sdp_prepare_split`.
- `review_gate.py --cwd DIR record-split <parent> --split-child … --i-am-recording-a-state-changing-decision` — closes the parent as `SPLIT` and seeds each child's log. Human-only: TTY, `~/.sdp/marker.token`, and a typed confirmation phrase.

The parent keeps its BLOCK history and answers `BLOCK: artifact was split; gate the children` from then on; each child starts at round 0 with `SPLIT_CHILD_OF parent=<key> parent_round=<n> depth=<d>` in its log. A split is refused unless the artifact is halted, two or more child artifacts exist on disk, none is the parent, a rationale is given, and the log carries **two or more distinct BLOCK reasons** — one reason repeated is an unfixed finding, not an oversized artifact. `halt.split_depth_cap` (default 2) caps the chain: because gate state is keyed by artifact path, splitting has always restarted the counter as a side effect, and the cap is what keeps the sanctioned path from becoming "split until it passes".

Gate state operations are an operator procedure — see [`docs/GATE_OPERATIONS.md`](docs/GATE_OPERATIONS.md).

---

## Configuration

SDP is a user-global harness. User-global config supplies cross-repository defaults; projects may own a thin, explicit override. Discovery order:

```
$PROJECT_DIR/.sdp/         →  $PROJECT_DIR/scripts/sdp/
  →  $XDG_CONFIG_HOME/sdp/  →  ~/.sdp/
```

Project-local paths always win, and selection is **whole-file, not a per-key merge**: candidates are checked in precedence order, missing ones are skipped, and the **first safely readable regular file** is selected and used alone — a key absent from it falls back to a built-in default, never to a lower-precedence file. Any unsafe or unreadable candidate aborts discovery immediately rather than deferring to the next one. A project `.sdp/defaults.yaml` carrying one key therefore makes the user-global file unread. A selected `defaults.yaml` is still subject to the **no-weakening** check: a `forced_ext` that gives one of the five base safety key names anything but a truthy literal is refused. That check validates the **claim**, not the behaviour: the validator is the only thing that recognises those five names, and no enforcement consumer reads their values (see Known limitations), so it stops a config from advertising a weakened base, not from weakening one. Missing files use safe built-in defaults. A present symlink, non-regular file, unreadable file, or relative `XDG_CONFIG_HOME` fails closed instead of falling through.

`XDG_CONFIG_HOME` is a trusted operator locator and must be absolute. Ambient `HOME` does not redirect fallback: SDP resolves `~/.config/sdp/` and `~/.sdp/` from the password database. Config contents are never sourced as shell code; `.sdp_runtime.env` is metadata for the active command only.

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

forced_ext: { ... }                     # project rules; a base safety key may appear only as a truthy claim
```

Gate cadence, timeouts and halt limits use the same discovery order in `gates.yaml`. Put shared values in the user-global location; use project `.sdp/gates.yaml` only for a deliberate override.

Escalation cadence has two knobs. `cadence.escalate_from` is the cumulative BLOCK count at which planner-solo is refused and a team marker becomes mandatory. `cadence.marker_span` is how many consecutive rounds one accepted marker discharges — default `1` (a marker every round); at `4` with `escalate_from: 8` and `max_block: 13` the windows are 8-11 and 12-13, so two markers cover the whole escalation range. Both raise the cost of getting stuck, so `sdp-regression.sh` bounds them: `escalate_from <= 8`, `marker_span <= 4`, `max_block <= 13`. A wider span also fixes the required marker **kind** to the window anchor's parity, so `review_on: even` with `span: 4` yields `TEAM_REVIEW` every time and `TEAM_CARRY` never falls due.

User-global `gates.yaml` affects both Codex- and Claude Code-hosted workflows. Promote only truly shared values: `mode` and `require_primary_verdict` change interactive/unattended policy everywhere, while legacy `model` is passed to Claude, Codex, and agy and should stay empty unless one identifier is valid for all three. Provider timeouts (`claude_timeout`, `codex_timeout`, `agy_timeout`) remain separate.

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

## Repository layout

| Path | What it is |
|---|---|
| `plugins/sdp/` | **Canonical plugin tree.** Edit payload here. |
| `scripts/`, `skills/`, `commands/` | Generated root mirror of the canonical tree (`scripts/build_plugin_tree.py`). |
| `core/`, `plugins/sdp/core/` | Stage 1–8 templates. Host-specialized on reviewer *direction* only; divergence is bounded by a test guard. |
| `scripts/review_gate.py` | The gate engine (~2.7k lines). Standalone-callable. |
| `scripts/sdp_mcp_server.py` | MCP server exposing the gate to Codex. |
| `.sdp/` | This repo's own SDP config — SDP dogfoods itself. |
| `tests/` | 15 suites, 626 assertions. `tests/run.sh` is the single entry point. |
| `docs/` | Requirements, Stage-4 design, known gaps, operator procedures. |

---

## Development

```bash
git config core.hooksPath .githooks   # once after cloning
bash tests/run.sh --fast              # regen-check + orphan-detector + packaging + smoke + lint
bash tests/run.sh                     # full suite (every layer in .sdp/defaults.yaml)
```

`plugins/sdp/` is the single source of truth for `scripts/` / `skills/` / `commands/` / `hooks/`; the root copies are **generated**. Edit the canonical tree, then `python3 scripts/build_plugin_tree.py`. `tests/run.sh --fast` fails on a stale mirror, so a hand-edited root copy cannot be committed. The pre-commit hook runs the fast suite and bumps the Codex plugin manifests as an install-cache cachebuster.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full workflow.

---

## Documentation

- [`docs/20260703_SDP_requirements_definition_EN.md`](docs/20260703_SDP_requirements_definition_EN.md) — requirements definition (REQ-IDs, acceptance criteria)
- [`docs/20260703_SDP_stage4_design_EN.md`](docs/20260703_SDP_stage4_design_EN.md) — Stage-4 design record
- [`docs/KNOWN_GAPS.md`](docs/KNOWN_GAPS.md) — advertised-but-not-implemented register, with code locations
- [`docs/GATE_OPERATIONS.md`](docs/GATE_OPERATIONS.md) — operator procedures for gate state (root-only; never read by an agent as instructions)

The design documents predate the current implementation and are kept as a historical record; `docs/KNOWN_GAPS.md` is the authoritative list of where they diverge from shipped behavior.

---

## Known limitations

See [`docs/KNOWN_GAPS.md`](docs/KNOWN_GAPS.md) for details and code locations.

- **`batch-sdp` `tmux_long_lived` engine** and **`worktree-dispatch` `auto` mode** launch **Codex implementation workers** through `scripts/run_segment_tmux.sh`; Claude Code is used only by review gates. They require `tmux`, `codex`, `git`, and a git-backed cwd; unavailable environments fall back to `agent_tool` / `manual`. Residual gaps: no live headless Codex test in CI, no live Orca/Codex re-measurement, and no per-worktree gate-audit aggregation.
- **`output_locale: auto` dual-copy** remains an authoring-time instruction. The anchor records both `OUTPUT_LOCALE` and `OUTPUT_LOCALE_MODE` in runtime metadata, so stages can distinguish automatic dual output from a fixed locale without re-reading a local config file.
- **Gate-log integrity is honor-plus-evidence, not cryptographic.** The log is same-uid agent-writable; the gate validates structure and freshness, not authorship.
- **Token budget accounting is not live.** `dispatch.token_budget` enforces only when an external hook supplies `SDP_TOKENS_USED`; no such writer ships.
- **Config is selected, not merged.** REQ-U-04's "2-layer merge" was never implemented: there is one winning file per basename and no key-level layering. The base safety keys it names (`hardcoded_secret_block`, `redact_secrets`, `no_auto_push_to_main`, `sandbox_outputs_under_base_dir`, `migration_creation_requires_approval`) have no **enforcement** reader either. The claim validator is the only code that recognises them, and it does act on the value — a non-truthy one is rejected and the anchor fails — but an accepted truthy value enables none of the named safety behaviours, because no downstream consumer implements them.

---

## Status

**Working, pre-1.0.** The plugin installs and runs on both hosts, the gate is exercised by 626 assertions across 15 suites, and this repo dogfoods SDP on itself. Interfaces (config keys, marker grammar, gate CLI) may still change before 1.0 — pin `sdp_version` if you depend on them.

---

## Contributing

Issues and pull requests are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). Every change must keep `bash tests/run.sh` green, and changes to gate behavior must come with a test.

To report a security issue, see [`SECURITY.md`](SECURITY.md).

---

## License

[MIT](LICENSE) © 2026 run2u

---

## Deploying a change to the plugin

A repo-local commit changes nothing for any consumer, including live sessions. The plugin cache at `~/.claude/plugins/cache/sdp-marketplace/sdp/<version>/` is a plain, version-keyed **copy** — not a symlink and not a git checkout — so a change stays inert until a human performs all four steps:

1. `git push`
2. `git -C ~/.claude/plugins/marketplaces/sdp-marketplace pull`
3. Reinstall the plugin — this creates a new version-keyed cache directory, and the pre-commit hook has already bumped the version manifests as a cachebuster.
4. **Restart every live session.** The `.in_use/<pid>` refcount keeps old copies alive otherwise, and the restart is what stops an older engine from mis-counting a log head it does not know.
