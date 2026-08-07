# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is the plugin manifest version in `plugins/sdp/.claude-plugin/plugin.json`.

SDP is pre-1.0: config keys, marker grammar and the gate CLI may change between minor versions. Pin `sdp_version` in `.sdp/defaults.yaml` if you depend on them.

## [Unreleased]

### Added
- Open-source release scaffolding: MIT `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, this changelog, GitHub issue/PR templates, and a CI workflow running the full test suite.
- English `COMMAND_MANUAL.md` with a Korean sync copy (`COMMAND_MANUAL.ko.md`).

### Changed
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
- **Vendored, de-domained `run_segment_tmux.sh`** backing `batch-sdp`'s `tmux_long_lived` engine and `worktree-dispatch`'s `auto` mode, with graceful fallback when `tmux`/`claude` are absent.
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

[Unreleased]: https://github.com/gonnarun/sdp/compare/v0.1.37...HEAD
[0.1.37]: https://github.com/gonnarun/sdp/releases/tag/v0.1.37
