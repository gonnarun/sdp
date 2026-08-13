# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is the plugin manifest version in `plugins/sdp/.claude-plugin/plugin.json`.

**A manifest version is not by itself a release.** The pre-commit hook bumps both plugin manifests on every commit, as an install-cache cachebuster — `plugins/sdp/.codex-plugin/plugin.json` additionally carries a `+codex.<timestamp>` build tag for the same reason. The sections below are the releases.

SDP is pre-1.0: config keys, marker grammar and the gate CLI may change between minor versions. Pin `sdp_version` in `.sdp/defaults.yaml` if you depend on them.

## [Unreleased]

### Added
- **User-global configuration.** `defaults.yaml` / `gates.yaml` now resolve through one canonical engine (`scripts/config_discovery.py`) shared by the anchor, the gate, the MCP server, the tmux and Orca adapters and the regression harness: project override → `$XDG_CONFIG_HOME/sdp/` → passwd-home `~/.config/sdp/` → `~/.sdp/`. A present-but-unsafe candidate (symlink, non-regular file, unreadable, relative `XDG_CONFIG_HOME`) fails closed instead of falling through, and the anchor records the selected `gates.yaml` path plus digest in `.private/sdp-config-provenance.json` so a config swapped after anchoring surfaces as `INFRA_ERROR` rather than taking effect silently.
- **Gate review checklist enforcement.** `review_checklist_include` / `require_checklist` are implemented: the include is resolved inside the workspace, fails closed when required-but-absent, unsafe or empty, and reaches the reviewer inside a nonce-delimited untrusted region.
- **`cadence.marker_span`** — how many consecutive escalation rounds one accepted team marker discharges (default `1`, the historical marker-per-round rule). The rounds a marker covers form a window; the window **anchor**, not the live round, selects the required marker kind, and expiry is derived from the log (BLOCK attempts recorded after the marker) rather than from any field the marker carries. Markers gain a `since=` token pinning `outputs=` freshness to the BLOCK that opened the window.
- Open-source release scaffolding: MIT `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, this changelog, GitHub issue/PR templates, and a CI workflow running the full test suite.
- English `COMMAND_MANUAL.md` with a Korean sync copy (`COMMAND_MANUAL.ko.md`).

### Fixed
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
- **User-global config fallback (REQ-U-05).** Discovery is now `$PROJECT_DIR/.sdp/` → `$PROJECT_DIR/scripts/sdp/` → `$XDG_CONFIG_HOME/sdp/` → `~/.sdp/`. Project paths always win, and the no-weakening check still runs on whichever file is selected, so a global config can strengthen but never relax the base safety keys.

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
