# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is the plugin manifest version in `plugins/sdp/.claude-plugin/plugin.json`.

**A manifest version is not by itself a release.** The pre-commit hook bumps both plugin manifests on every commit, as an install-cache cachebuster — `plugins/sdp/.codex-plugin/plugin.json` additionally carries a `+codex.<timestamp>` build tag for the same reason. The sections below are the releases.

SDP is pre-1.0: config keys, marker grammar and the gate CLI may change between minor versions. Pin `sdp_version` in `.sdp/defaults.yaml` if you depend on them.

## [Unreleased]

### Added
- **Every halt now says what to do (issue #4, request 1).** The five halt branches returned one line with an empty body. An agent told only that it lost fills the gap itself, and the moves it invents are the human-only ones — delete `.halt`, zero the counter, set `SDP_GATE_OVERRIDE` — which it then offers the user as choices. The halt body now names the agent's only action (stop and report, with the report's contents), fences off `RESET`/`OVERRIDE`/`PIVOT_RESET`/`SDP_GATE_OVERRIDE` as human-only and not to be proposed, states that team markers are not consulted after a halt, and points at the one sanctioned recovery below. Downstream repositories were each writing this paragraph into their own project rules.
- **`prepare-split` / `record-split`: a sanctioned way to split a halted artifact (issue #4, request 2).** A halt usually means the scope was too broad — every round raises a different defect — and patching one over-broad artifact does not converge. Because gate state is keyed by the artifact's absolute path, splitting has *always* restarted the counter as a side effect, with no rule saying when that was legitimate. It is now a recorded, human-approved path with pivot-strength ceremony (TTY, `~/.sdp/marker.token`, `--i-am-recording-a-state-changing-decision`, a typed phrase): the parent is closed as `SPLIT` and keeps its BLOCK history, each child's log is seeded with `SPLIT_CHILD_OF parent=<key> parent_round=<n> depth=<d>` and starts at round 0, and the split is refused unless the artifact is halted, two or more child artifacts exist on disk, none is the parent, a rationale is given, and the log carries two or more **distinct** BLOCK reasons (one reason repeated is an unfixed finding, not an oversized artifact). `halt.split_depth_cap` (default 2) caps the chain and `sdp-regression.sh` bounds it the way it bounds the cadence scalars. `prepare-split` is a restricted, lock-free writer that touches no gate state and never returns the recording command; codex reaches it through the new MCP tool `sdp_prepare_split`. Covered by `tests/gate_split.sh` (45 checks).
- **User-global configuration.** `defaults.yaml` / `gates.yaml` now resolve through one canonical engine (`scripts/config_discovery.py`) shared by the anchor, the gate, the MCP server, the tmux and Orca adapters and the regression harness: project override → `$XDG_CONFIG_HOME/sdp/` → passwd-home `~/.config/sdp/` → `~/.sdp/`. A present-but-unsafe candidate (symlink, non-regular file, unreadable, relative `XDG_CONFIG_HOME`) fails closed instead of falling through, and the anchor records the selected `gates.yaml` path plus digest in `.private/sdp-config-provenance.json` so a config swapped after anchoring surfaces as `INFRA_ERROR` rather than taking effect silently.
- **Gate review checklist enforcement.** `review_checklist_include` / `require_checklist` are implemented: the include is resolved inside the workspace, fails closed when required-but-absent, unsafe or empty, and reaches the reviewer inside a nonce-delimited untrusted region.
- **`cadence.marker_span`** — how many consecutive escalation rounds one accepted team marker discharges (default `1`, the historical marker-per-round rule). The rounds a marker covers form a window; the window **anchor**, not the live round, selects the required marker kind, and expiry is derived from the log (BLOCK attempts recorded after the marker) rather than from any field the marker carries. Markers gain a `since=` token pinning `outputs=` freshness to the BLOCK that opened the window.
- Open-source release scaffolding: MIT `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, this changelog, GitHub issue/PR templates, and a CI workflow running the full test suite.
- English `COMMAND_MANUAL.md` with a Korean sync copy (`COMMAND_MANUAL.ko.md`).

### Fixed
- **The review gate no longer reviews its author's own work (issue #3).** The stage documents pinned `--reviewer` in their copy-pasteable gate commands, and `core/` is not per-host: Claude Code reads it as `${CLAUDE_PLUGIN_ROOT}/core/SDP.md` from the same `plugins/sdp/core/` the Codex skills read. The pinned value was therefore inverted on one host, and a Claude-authored plan was gated by Claude — 15 of 15 verdicts on one dispatch recorded `provider=claude`, and re-gating with the opposite model blocked 5 of 8 artifacts it had passed. Gate commands in Stages 4, 5 and 7 now pass no `--reviewer` (the CLI default, `codex`, is already the opposite of the Claude Code author; the codex side keeps preferring the MCP tool `claude_review_gate`), each gate block restates that the reviewer is the model opposite the author, and the two `core/` trees are byte-identical again. `tests/docs.sh` asserts both. The tests that previously *required* the per-tree pin are retired, since they encoded the defect. The same-model ledger itself is still undetected at runtime — registered as `KNOWN_GAPS` NC-32. The Codex direction is closed in the same pass: `core/`'s gate blocks are the **Claude Code** form (unpinned, because there the CLI default `codex` is already the opposite model), so a Codex worker whose MCP tool is down would have copied one and had codex review codex. Every stage callout now names the Codex CLI fallback (`--reviewer claude`) and says the block is host-specific, the three Codex skills carry the same warning, and `tests/docs.sh` (xv-b) asserts both.
- `scripts/lib/sdp-config.sh` no longer points at an `sdp_cfg_merge()` that was never written. Config resolution is **whole-file selection**, not a 2-layer merge: candidates are checked in precedence order, missing ones are skipped, and the **first safely readable regular file** wins outright (an unsafe or unreadable candidate aborts discovery immediately instead of deferring to the next), so a key absent from it falls back to a built-in default rather than to the user-global file. The no-weakening check over `forced_ext` is likewise restated as what it is — a validator over the *claim* a config makes, not an enforcement point, since it is the only code that recognises the five base safety keys: it rejects a non-truthy value, but an accepted truthy one enables none of the named safety behaviours, no downstream consumer having implemented them. The READMEs say so now, and the gap against REQ-U-04 — including the fact that an accepted truthy value on its five base safety keys enables nothing — is registered as `KNOWN_GAPS` NC-31.
- Claude Code command adapters no longer document `CODEX_GATE_MODE` as the way to select attended/unattended. The engine has always read `mode` from `gates.yaml` and never from the environment, so the variable was inert and the stated default was wrong; `SDP_GATE_OVERRIDE` is also named correctly now.
- `.sdp_runtime.env` is documented as agent-readable metadata everywhere; no script or stage sources it as shell code.
- `worktree-dispatch` now launches Codex implementation workers in `auto` and `orca` modes; Claude Code is restricted to external review gates. The tmux runner probes/starts Codex, Orca pins `--agent codex`, and regression tests assert this boundary.
- CI actions moved off the Node.js 20 runtime, which GitHub has deprecated: `actions/checkout` v4 → v7.0.1 and `actions/setup-python` v5 → v7.0.0, both on Node 24. Each is now pinned to a commit SHA rather than a movable tag.
- `tests/smoke.sh` no longer fails on a machine with no reviewer CLI installed. `doctor` reports two axes and exits non-zero if either is unhealthy; the suite now asserts the `gate-state` axis it owns and self-skips the `toolchain` axis when neither `codex` nor `claude` is resolvable, matching `tests/run_segment.sh`'s existing skip. A wedged gate still fails the suite.

### Changed
- **`sdp-regression.sh` gate-strength check is now two-tier and combination-aware.** The baseline stays the shipped default (`escalate_from <= 6`, `marker_span <= 1`, `max_block <= 13`); relaxing past it requires an explicit `cadence.relaxation_ack` and is reported loudly, and is still capped by a sanctioned envelope (`<= 8` / `<= 4` / `<= 13`). Independently, the harness simulates the anchors over the half-open live range `[escalate_from, max_block)` and refuses a `(escalate_from, marker_span, review_on)` triple under which every window is a `TEAM_CARRY` — such a triple never demands fresh `outputs=` evidence anywhere. `escalate_from >= max_block` is treated as halt-first and therefore stricter, not as a weakening.
- This repository's own `gates.yaml` moves to `escalate_from: 8`, `marker_span: 4` with the required `relaxation_ack`; the escalation range 8–13 is now covered by two markers instead of seven.
- Rewrote both READMEs for public consumption: requirements table, quick start, repository layout, development workflow, an explanation of the optional `agy` fallback reviewer, and a Status section that reflects shipped behavior instead of the pre-implementation draft.
- Redacted the six private source repositories SDP was extracted from as `Project-A` … `Project-F` across the remaining design documents.

### Removed
- Korean-canonical requirements, the Korean Stage-4 design copy, the feasibility review, the Stage-5 progress log and the session work summary. These were internal working documents; they are not part of the public release.

## [0.1.37] — 2026-08-07

### Added
- **User-global config fallback (REQ-U-05).** Discovery is now `$PROJECT_DIR/.sdp/` → `$PROJECT_DIR/scripts/sdp/` → `$XDG_CONFIG_HOME/sdp/` → `~/.sdp/`. Project paths always win, and the no-weakening check still runs on whichever file is selected, so a global config can strengthen but never relax the base safety keys. *(Later found to be a validator over the claim only — it rejects a non-truthy value, but an accepted truthy one enables none of the named safety behaviours; see `KNOWN_GAPS` NC-31.)*

## [0.1.36] and earlier

Condensed; see `git log` for the full record.

### Added
- **Sanctioned marker recording.** `prepare-marker` composes a team-review marker and writes a request file for a human; `record-marker` is the only command that writes to a gate log, and it requires a terminal plus a human-provisioned token. State-changing decisions (`pivot`, `halt`) additionally require an explicit flag and a typed confirmation phrase.
- **Durable escalation stall signal**, with `halt.max_stall` bounding consecutive stalls before `.halt`.
- **Complete D-07 gate state machine** — stuck detection, escalation cadence, team markers, pivot.
- **MCP server** (`scripts/sdp_mcp_server.py`) exposing the gate to Codex as `claude_review_gate`, resolved via `CLAUDE_PLUGIN_ROOT`.
- **De-domained `run_segment_tmux.sh`** (maintainer-authored; no third-party code) backing `batch-sdp`'s `tmux_long_lived` engine and `worktree-dispatch`'s `auto` mode, with graceful fallback when `tmux`/`codex`/`git` are absent.
- **Single-source plugin tree generator** (`scripts/build_plugin_tree.py`) with a `--check` mode wired into the fast test suite, so a hand-edited root mirror cannot be committed.
- **i18n authoring rule (REQ-U-08)** in the core and per-Stage anchors; `OUTPUT_LOCALE_MODE` emitted alongside `OUTPUT_LOCALE`.
- Test suites for concurrency, MCP protocol, gate markers, config safety, docs consistency, i18n, packaging, adapters, the segment runner, and a multi-project regression harness.

### Changed
- **Directional cross-model review restored and pinned.** The reviewer is always the opposite model from the artifact's author; same-model exclusion is enforced at the codex MCP boundary and asserted by the test suite.
- **`fcntl.flock`** replaced the earlier bash lock — fail-closed on timeout, released by the kernel on process death, no TTL and no stale-reclaim.
- Reviewer model and timeouts are sourced from `.sdp/gates.yaml` only, never from the environment; residual environment knobs were removed in favor of constants.
- `claude_gate.py` renamed to `review_gate.py`; operator documentation retargeted accordingly.
- The Claude reviewer's tool policy was inverted to an **empty allowlist**.
- Reconciled the two `core/` trees so the 3-state policy is identical and only reviewer direction diverges, bounded by a test guard.

### Fixed
- **Fail-closed codex stream validation** — exact per-event schema, top-level event type validation, stream ordering and turn-lifecycle binding. A tool-use run in a tool-free review is refused rather than trusted.
- **TOCTOU-safe reviewer execution** via a hardlink into a trusted-ancestry temp directory, so Homebrew- and nvm-installed reviewers resolve without weakening the group-writable rejection. Fails closed if the temp-directory ACL strip fails on macOS.
- A clean `ALLOW` now clears the per-artifact infra flag.
- Gate tool timeout raised above the gate's own self-cap so the MCP transport no longer times out before the gate returns a verdict.

### Removed
- `codex-gate.sh` and `agy-gate-fallback.sh`, superseded by `review_gate.py`.
