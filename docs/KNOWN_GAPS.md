# SDP — Known gaps & doc/code reconciliation

> Durable, factual record of gaps between what the design/requirements docs advertise and what the shipped code currently does. Each item cites code locations. Updated as gaps are closed. This is the single source of truth for "advertised but not yet implemented" and for superseded design details.

_Last reviewed: 2026-08-12._

---

## 1. Dispatch backend `run_segment_tmux.sh` — PORTED (with residual test/aggregation gaps)

**Status: ported; two residual gaps remain (below).**

`scripts/run_segment_tmux.sh` has been **ported and corrected to launch Codex implementation workers**. Claude Code is review-gate only. Config keys `dispatch.batch_engine` / `dispatch.worktree_mode` remain in the anchor-selected `defaults.yaml` (project-local or user-global); adapters fall back when `tmux`/`codex`/`git` are absent (exit `5`) or the worker cwd is not a git checkout (exit `3`).

- **`batch-sdp` `tmux_long_lived`** (REQ-C-03) — backed; `commands/batch-sdp.md` drives `init`/`continue`/`shutdown`.
- **`worktree-dispatch` `auto`** (REQ-C-07) — backed; `commands/worktree-dispatch.md` drives per-worktree `init` with `SDP_SESSION_CWD` set to the worktree.

Covered by `tests/run_segment.sh` (30 dry-run and tmux-stub checks: arg/MODE validation, exit codes, Codex worker identity/TUI controls, STATUS mapping, config resolution, charset guard).

**Residual gap 1a — no live-session test in the sandbox.** Exit codes `7`, `124`, and `125` require an actually-spawned headless Codex session. Dry-run and tmux-stub tests assert worker identity and STATUS mapping, but CI does not spend a live model session. **To close:** a controlled disposable Codex integration host.

**Residual gap 1b — gate audit ndjson is NOT aggregated across worktrees.** Each spawned session's gate resolves its own `base_dir/gate-audit.ndjson` (per-worktree, consistent with the per-KEY/cwd concurrency model, REQ-C-06). The **completion record** (`STATUS.md` + a line in `$BATCH_DIR/.session_history.log` under the main base_dir) does reach main, but the per-verdict audit trail stays per-worktree. Aggregating all worktree audits into the main base_dir is **not built** (faithful-minimum; not faked). **To close:** an audit-merge step after integration.

Referenced (advertised) at: `docs/20260703_SDP_requirements_definition_EN.md` REQ-P-01, REQ-C-03, REQ-C-07, §12 layout.

---

## 2. `output_locale: auto` is not runtime-distinguishable from a fixed `<locale>`

**Status: CLOSED (2026-07-05).** `sdp-anchor.sh` now emits `OUTPUT_LOCALE_MODE=auto|fixed` alongside `OUTPUT_LOCALE=<lang>` in `.sdp_runtime.env`, so downstream distinguishes `auto` (dual output) from a fixed single-locale at runtime without re-reading config. (Original gap description retained below for history.)

REQ-U-08 / AC-14 define `output_locale: auto` as "English canonical original **+** a synced env-locale copy when the locale ≠ en", versus a fixed `<locale>` which is a single-language deliverable. But `scripts/sdp-anchor.sh` (lines ~48–58) **collapses `auto` into the resolved environment locale** and writes only a single `OUTPUT_LOCALE=<lang>` into `.sdp_runtime.env`. Therefore `OUTPUT_LOCALE` alone **cannot distinguish** `auto` (dual output) from a fixed `<locale>` (single output).

**Workaround (in place):** the P4 authoring rule in `core/SDP.md` §"Deliverable authoring language (i18n) — REQ-U-08" and the per-Stage anchors instruct the author to read the **mode** from the `output_locale` key in the anchor-selected `defaults.yaml`, and use `OUTPUT_LOCALE` only for the target language.

**To close:** have `sdp-anchor.sh` emit the raw mode (e.g. `OUTPUT_LOCALE_MODE=auto|en|fixed`) alongside the resolved locale, so the dual-vs-single decision is available at runtime without re-reading config. (Behavior change — out of scope for the doc-only pass.)

---

## 3. Token/budget cap — enforcement wired, live accounting NOT yet sourced (NFR-05)

**Status: seam + config + check implemented; live token accounting is a gap.**

The per-task token hard cap (NFR-05; stage4 design EN:188 places it in the dispatch layer) is implemented in `scripts/run_segment_tmux.sh`: `dispatch.token_budget` (default `0` = off) is enforced before (re)spawning a segment (`init`/`continue`/`resume`) — if `used ≥ budget` the runner **exits 8** and refuses to spawn. The used-token count is read from `SDP_TOKENS_USED` (env) or `${BATCH_DIR}/.tokens_used` (file). Covered by `tests/run_segment.sh` with injected counts.

**Gap:** nothing in this environment populates `.tokens_used` from real `claude`/`codex` usage output, so the cap cannot be exercised against live token totals here — only against injected values. **To close:** a per-session usage hook that writes cumulative tokens to `${BATCH_DIR}/.tokens_used` after each segment (from the CLI's usage report). No token numbers were fabricated.

---

## 4. 6-project regression — harness built, real run PENDING native execution (AC-12 / NFR-07)

**Status: harness + self-test done; the 6 real repos were NOT run (not mounted).**

`scripts/sdp-regression.sh` implements the AC-12 / NFR-07 acceptance checks (config discoverable, anchor resolves, no forced_ext weakening, gate thresholds not weakened `escalate_from≤6`/`max_block≤13`, fail-closed checklist; plus plugin preflight for agy fallback + 3 adapters). Project list comes from args / `SDP_REGRESSION_PROJECTS` / `regression.projects` config — **no hardcoded machine paths**. `tests/regression.sh` proves the logic on synthetic fixtures (clean pass, weakened-gate FAIL, raised-max_block FAIL, fail-closed FAIL, valid-include pass, neutral skip, missing-dir FAIL).

**Gap:** the six reference repos (Project-A / Project-B / Project-C / Project-D / Project-E / Project-F) are **not present in this session**, so the real regression was **not run** and is **not claimed to pass**. **To close (native):** set `regression.projects` (or `SDP_REGRESSION_PROJECTS`) to the six repo paths and run `scripts/sdp-regression.sh`.

---

## 5. Concurrency lock — retired `mkdir` lock → `fcntl.flock` in `review_gate.py`

**Status: resolved in code; historical spec text retained.**

The bash gate's portable `mkdir`-based lock (TTL + race-safe stale-reclaim) is **retired with `codex-gate.sh`**. The unified `scripts/review_gate.py` serializes the per-artifact state decision with **`fcntl.flock`** — kernel-released on process death (incl. `SIGKILL`), **no TTL, no steal, fail-closed** on wait-timeout (→ INFRA_ERROR, never lockless-degrade); covered by `tests/concurrency.sh`. The earlier `flock`→`mkdir` migration was a **bash-only** workaround: `flock(1)`, the util-linux shell utility, is absent on macOS. `flock(2)` exists on Darwin and CPython exposes it (`fcntl.flock`), so the Python port uses the kernel lock directly and `lock_ttl` / `CODEX_GATE_LOCK_TTL` become dead keys.

The following **dated design/requirements documents still say "flock"**. They are **historical records** of the 2026-07-03 spec and are intentionally left unedited; the live mechanism is once again a kernel `flock` (via `fcntl.flock` in `review_gate.py`). The language-agnostic / POSIX-only / no-node guarantees they assert (NFR-01) still hold.

| Location | Mention | Reconciliation |
|---|---|---|
| `docs/…requirements_definition_EN.md` | REQ-G-04, NFR-01, §Concurrency, AC-04 | historical spec — live mechanism is `fcntl.flock` in `review_gate.py` |
| Historical requirements copy (not published) | REQ-G-02/04, NFR-01, §concurrency, AC-04 | historical spec — live mechanism is `fcntl.flock` |
| `docs/…stage4_design_EN.md` (and its private Korean copy) | "4-tuple thread stash + `flock` + 24h TTL" | historical design — the thread stash is **retired**; the lock is `fcntl.flock`, no TTL |

Accurate `flock` mentions (left as-is): `scripts/review_gate.py` (`fcntl.flock` in `_state_lock`), `tests/concurrency.sh` (rewritten against the flock critical section), the Stage-5 progress log (not published).

---

## 6. Gate-recovery non-conformance register

**This section carries 29 rows, `NC-01` .. `NC-29`.**

> **How this register is maintained, stated plainly.** It is a **curated list maintained by reading**. **No mechanism in this repository establishes its semantic completeness** — that residual is `NC-21` itself. Adding a row is a reading act: when a reviewer or an author notices an admission with no row, they add the row. *Nothing detects the omission for them.* An earlier self-verification apparatus claimed to; its measured recall against this same register was **9 of 21**, and it was removed. The `[[NC-nn]]` tags used in the (gitignored) design artifact are **navigation**; no check reads them, and no grep over them proves anything. `tests/docs.sh` asserts **only** the committed register's *internal integrity* — id contiguity with no gap or duplicate, and that the stated total above equals the row count below. Completeness is a **reviewer obligation**, never a checked property.
>
> Where a row concerns a user-approved scope deviation (`D1`-`D4`), **the deviation's status is recorded in the design's ADR-X04 table and nowhere else**. Rows below reference it as `status per ADR-X04` and never restate it. No row here may ever be reported as "conformed", "partially conformed", or "closed".

| # | Non-conformance |
|---|---|
| **NC-01** | **D1 — REQ-C-06, the cross-worktree escalation bypass, remains open.** A fresh `git worktree add` gets an empty, gitignored state tree, so parallel paths can bypass the round-6 obligation. Status per ADR-X04. It must not be reported as closed. |
| **NC-02** | **D2 — P7 (the gate-state key scheme and the `_audit_base` re-anchoring) is deferred to its own dispatch.** No key change, no migration and no directory move ship here. Status per ADR-X04. The successor's **eight binding obligations** are recorded verbatim in `docs/GATE_OPERATIONS.md` §"Deferred: gate-state key migration" — that section is this row's committed carrier. |
| **NC-03** | **D3 — the escalation BLOCK does not increment the cumulative block counter.** REQ-003's literal text asks for it; `ESCALATION_STALL` + `stall_run` + `max_stall` + `.needs_human` are substituted, because incrementing the counter moves the round number and flips `_need_marker`'s parity into the untested `TEAM_CARRY` path. Status per ADR-X04. |
| **NC-04** | **D4 — Track A and Track B run serially, not in parallel.** REQ-021's own-dispatched-worktree half is met; the parallel half is not. Status per ADR-X04. |
| **NC-05** | **`REQ-E-04-strict` — the marker read-path grammar is not tightened.** `_validate_marker` performs no `decision=` presence check at all, although REQ-E-04 requires one; and `fix` is outside REQ-E-04's `<continue\|pivot\|halt>` enum while the gate honours it and live markers use it. Tightening the grammar would invalidate every legacy marker on disk, so the whole read-path question is deferred as one unit. The **write** path emits the full grammar. |
| **NC-06** | **REQ-017 is POLICY, not enforcement.** The `record-marker` TTY + token gate is **affordance, not capability**. Verbatim: *"`SDP_MARKER_HUMAN` is an intent signal, not a secret: `~/.sdp/marker.token` is same-uid readable, so any agent that can run `cat` can supply it. The only affordance barrier is the TTY test; the token exists so that an accidental invocation from a non-interactive context cannot succeed even under a pty."* `record-marker` is a CLI reachable from Claude via Bash, so withholding the MCP write tool withholds it from **codex**, not from Claude. |
| **NC-07** | **REQ-032 — plugin-cache reinstall is deliberately not addressed.** It is structurally unreachable inside a boundary that stops at a local commit; satisfying it requires the human deploy hand-off in `docs/GATE_OPERATIONS.md` §Deploy. |
| **NC-08** | **REQ-025's completion report is contingent**, not unconditional: it does not hold if the follow-on Track B work is BLOCKED or cannot obtain a primary-provider ALLOW. It is reported honestly — which of P1-P7 closed and at what level — never claimed as complete. |
| **NC-09** | **`require_primary_verdict` is inert on any engine that has no reader for the key**, including the deployed plugin version other repositories run. In general form, **an agy-fallback ALLOW remains possible on any such engine**; a manual check of `gate-audit.ndjson`'s `provider` field before accepting an ALLOW is the only live control there. |
| **NC-10** | **The `roster == "planner"` branch in `_validate_marker` is dead.** The `len(items) < 2` check pre-empts it. Behaviourally covered by `tests/gate_integration.sh`; left in place rather than removed. |
| **NC-11** | **`TEAM_CARRY` had zero test coverage** before this dispatch. `tests/gate_marker.sh` T16 adds the first case. The parity hazard it guards — an off-by-one in the cumulative count silently switching the required marker kind — remains the reason no new head may be counted. |
| **NC-12** | **The `--cwd` state-directory hole.** `_state_paths` derives the gate directory from `_audit_base(root)`, and `root` is the caller's `--cwd` whenever that is an ancestor of the artifact, so a caller varying `--cwd` addresses a different gate directory for the same artifact. **Pre-existing and deliberately not closed here**; it rides with the deferred P7 dispatch. `tests/gate_integration.sh` T31 pins today's behaviour so a refactor cannot relocate the directory silently. |
| **NC-13** | **The gate never validates a marker's own timestamp.** `_validate_marker` parses only `last_block_ts` from the `BLOCK_ATTEMPT` lines, so a malformed marker timestamp is accepted silently. The **emitting** side is fixed (timestamps come from Python, never from a shell `date`); the **validating** side is deferred with `REQ-E-04-strict`, because adding the parse would invalidate a live marker currently discharging an escalation. |
| **NC-14** | **Older deployed engines conflate absent, symlink and read error for `gates.yaml`.** Repository head now uses canonical local→XDG→passwd-home discovery and fails closed on unsafe/unreadable presence; tests cover ancestor/leaf symlinks, FIFO, relative XDG and provenance mismatch. Installed version-keyed cache copies retain the old behavior until human deploy + session restart, so this operational non-conformance remains recorded. |
| **NC-15** | **Artifact proliferation.** `cp plan.md plan_v2.md`, or splitting a plan into a new part, mints a fresh key at count 0 and launders the escalation state. Process rules forbid the plan-split; the engine leaves the primitive fully open, and no path-derived key can close it. |
| **NC-16** | **An absolute `SDP_BASE_DIR` shared by two repositories couples them**: one gate directory, colliding keys for identically-named artifacts, one shared `gate-audit.ndjson`, and one shared `.halt` / `.infra_flag` / `.needs_human` / `.marker-request` namespace. `_audit_base` explicitly supports the configuration. |
| **NC-17** | **Direct same-uid appends of `RESET` / `OVERRIDE` / `PIVOT_RESET` to any gate log** reset the counter. The log is agent-writable same-uid; this is the documented non-goal REQ-E-05 names. (`ALLOW` is no longer a stall-reset primitive.) |
| **NC-18** | **The `prepare-marker` request file materialises a fully-composed, gate-validated marker line on disk.** `record-marker` is gated; **the log is not**, so any process that can append to the log can append that line. This is a **genuine net increase in forgery affordance**, deliberately accepted as the cost of REQ-018's human hand-over: before it, an agent had to guess the grammar, and the incident that motivated this work shows the guess failing. It is bounded only by the next `BLOCK_ATTEMPT` erasing the pending marker. The MCP redaction removes the line from the model's **context**, not from its **reach**. |
| **NC-19** | **The `ESCALATION_STALL` old-engine parity drift.** An engine without the new head counts each `ESCALATION_STALL` and each `MARKER_AUDIT_FAILED` `+1` toward `max_block` — drift **toward** halting, so fail-closed, but real: it can flip `_need_marker`'s parity for that engine. It is closed by the mandatory session restart in `docs/GATE_OPERATIONS.md` §Deploy, and the caveat is that **the restart is an instruction**: the `.in_use/<pid>` refcount is not wired to the deploy procedure. |
| **NC-20** | **The unprobeable old-engine class.** A `.in_use/<pid>` refcount sees only plugin-cache-installed engines, so a checkout-invoked engine or a generated root mirror leaves **no ref file at all**, and a missing ref is fail-**open**. Any quiescence precondition built on it is therefore **procedural, not mechanical**, and is recommended on a comparative rather than a proven argument. |
| **NC-21** | **Register completeness rests on human reading.** No mechanism here establishes that every admitted non-conformance has a row. An apparatus that claimed to do so was measured at **9 of 21** recall and defeated by eight single-edit mutations, and was removed. The two `tests/docs.sh` checks over this section guard its **internal integrity only** — contiguity and stated-total-equals-row-count. |
| **NC-22** | **The `_ISATTY` test seam is a documented bypass of the `record-marker` TTY control.** `tests/lib/harness.py` binds it via argv so `tests/gate_marker.sh` can exercise the accept path. It is test-only and `tests/` never ships — `plugins/sdp/` carries no `tests/` and neither `review_gate.py` nor `sdp_mcp_server.py` references the harness — but it is a real affordance and is recorded rather than assumed harmless. |
| **NC-23** | **A live unaudited marker survives whenever the compensating append does not land.** `record_marker` appends `MARKER_AUDIT_FAILED` to invalidate a marker whose audit row could not be written, but the two appends are separate writes, so the compensation can be missing two ways: a **process death between them**, and the **compensating append itself failing** (that branch raises `InfraError` and attempts `.infra_flag`, so it is at least loud). The marker is live either way, and no append-only compensation can close either. The invariant is *"no unaudited state-mutating write **survives a completed `record_marker` call**"*, not an absolute. |
| **NC-24** | **Older deployed engines ignore `review_checklist_include` / `require_checklist`.** Repository head now validates the include inside the workspace, fails closed on required/missing/unsafe/empty input, and supplies it in a nonce-delimited untrusted reviewer region. Version-keyed installed cache copies keep the old no-op behavior until human deploy + session restart, so downstream sessions must not claim the fix before rollout. |
| **NC-25** | **`_parse_log` counts reviewer prose as BLOCK_ATTEMPTs.** The parser dispatches on each line's first token and its final `else` branch increments the counter for any unrecognised head (by design: "a malformed line counts toward the halt, never away"). Reason text is not malformed, but its lines are unrecognised, so every one is counted. Measured against the retired `codex_gate` engine's logs, which did persist reason text: a log with **8** real `BLOCK_ATTEMPT` lines parses as **98**. This is latent today only because the current engine wrote no reason text and `_doctor_gate_state` globs `review_gate_*.log`, so the old `codex_gate_*.log` files are never re-parsed. The `REASON ` prefix added with reason persistence keeps *new* lines inert; **pre-existing `codex_gate` logs remain mis-countable if anything ever parses them.** |
| **NC-26** | **`orca` dispatch mode (`dispatch.worktree_mode: orca`) has never been driven by `worktree-dispatch` itself.** Six **Claude-agent** workers were run against the adapter's call sequence and measured pinned bases, byte-identical spec delivery, worktree/branch naming, concurrency, failure isolation, and branch preservation. The adapter now pins `--agent codex`; those transport and verdict observations are not claimed as live Codex evidence until one controlled Codex-agent run re-measures them. The command path, merge integration, `--timeout-ms`, privileged permission boundary, setup-hook sequencing, and crash/restart reconciliation also remain unexercised. The version allow-list stays the single verified `(1.4.176, 1)` pair. Orca still owns no worker process: deadline expiry reports `124` without stopping it. |
| **NC-27** | **A verdict-bearing file must be read, never merely counted — and the `orca` adapter shipped violating that.** `run_segment_tmux.sh` has gated on `STATUS.md`'s *content* since N3/REQ-034; `orca_dispatch.sh` shipped checking only that the file was non-empty, so every segment that ended `FAIL_12X`, `HALT_BLOCK` or `PAUSE_USER_INPUT_REQUIRED` was reported to the caller as success. Demonstrated live on 2026-08-09: a worker whose `STATUS.md` read `FAIL_12X` was reported by Orca as `state: succeeded, stage: settled, dispatch.status: completed` — correct on Orca's terms, since it answers "did the process end cleanly" — and the adapter returned exit `0`. In a five-task dispatch with one failure, main would have integrated the failed task. Now fixed and locked by regression, but the **general hazard is registered rather than considered closed**: the 54-assertion suite that shipped with the adapter asserted `STATUS.md present → 0`, i.e. it encoded the defect as the expected behaviour, because the test was written from the implementation. A test derived from the code it tests cannot detect this class. |
| **NC-28** | **`.sdp_runtime.env` goes stale silently, and a plugin reinstall does not refresh it.** `sdp-anchor.sh` writes it once per command entry; nothing else updates it, so between runs it can name a plugin-cache version that is no longer installed. Because old cache versions stay on disk — live sessions hold them via `.in_use/<pid>` — a stale `SDP_ROOT` still *resolves*, and anything following it runs a different engine without any error. No script dot-sources the file (GAP-04/C1 removed that vector, and `tests/config_safety.sh` asserts it), so the consumer is the **agent**: `core/SDP.md` and the Stage templates instruct it to read `$BASE_DIR`, `$DATE` and `OUTPUT_LOCALE` from there, which is also how a stale `SDP_SCRIPTS` could route a gate call to an old engine and a stale `DATE` could file deliverables under the wrong day. Measured 2026-08-09 on this machine: of 21 runtime-env files, **1** named the installed version; the rest named 0.1.1 / 0.1.34 / 0.1.37 / codex builds, one of them dated the same day. `doctor` now reports the condition (`anchor: current` / `STALE`, distinguishing a recorded directory that still exists from one that is gone) and `sdp-anchor.sh` records `SDP_VERSION` + `ANCHORED_AT`. **This is reporting, not enforcement, and deliberately so**: making it fatal would fail every project whose last command entry predates the current install, all at once, and the repair — re-run the anchor — is identical either way. Deleting old cache versions was considered and rejected as the primary fix: 40 live PIDs held four older versions at the time of measurement, it would break ~20 projects simultaneously, it does not prevent recurrence (the next install leaves today's version behind), and the directory is owned by the host's plugin installer. |
| **NC-29** | **`cadence.marker_span` relaxes the escalation obligation by design, and the relaxation is bounded only by the acceptance harness.** One accepted marker now discharges `marker_span` consecutive rounds instead of exactly one, so at this repository's `escalate_from: 8` / `marker_span: 4` / `max_block: 13` the whole escalation range 8-13 is covered by **two** markers where the pre-span rule required seven. Expiry is derived from the log (`_LogState.blocks_since_marker`), not from a marker field, so a hand-appended marker cannot widen its own window — but the ceiling itself (`marker_span <= 4`, `escalate_from <= 8`) lives in `scripts/sdp-regression.sh`, an acceptance harness a project is not obliged to run, exactly like the pre-existing `max_block` ceiling. Two further consequences are recorded rather than fixed: a span whose stride keeps the anchor on one parity **retires the lighter `TEAM_CARRY` kind entirely** (at `review_on: even` / `span: 4` every window anchor is even, so only `TEAM_REVIEW` ever falls due — intended here, but it is a cadence the `review_on` key can no longer express), and a marker written by a pre-span engine carries no `since=`, so under `span > 1` its cited evidence is measured against the moving newest BLOCK and it **cannot span** — fail-closed, and covered by `tests/gate_integration.sh` T36b. |

**Three named residuals**, distinct from the rows above because they are *unverified questions* rather than admitted non-conformances:

1. The quiescence control recorded against the cross-worktree bypass may compensate for a different risk than the one it is recorded against.
2. The claim that `tests/lib/harness.py`'s argv rebinding blocks extracting a `gate_state.py` module is **unverified in both directions**.
3. The byte-identity of the three `review_gate.py` copies (canonical, generated root mirror, deployed plugin cache) is **asserted from a survey, not independently re-verified**; every reviewer to date read only the root mirror.

**Unattended full access (REQ-C-07), explicit.** `auto` starts Codex with `--ask-for-approval never --sandbox danger-full-access` only after validating a git-backed cwd. This matches the old unattended capability but does not make it safe by itself; use only in a controlled worktree environment with deadline and kill switch. `orca` never falls through to this mode implicitly.

---

## Resolved (for the record)

- **INFRA_ERROR / override-ALLOW audit wiring** (P1) — `_audit` now fires on the INFRA_ERROR terminal branches and the override-ALLOW path; the live gate's M5 audit-on-validation-failure is now in `scripts/review_gate.py` (`_preroot_audit` + the L1 try/except).
- **flock → mkdir portable lock** (P2) — see item 5.
- **Dangling `commands` manifest ref** (P3) — `commands/` now exists with three adapters; `plugin.json` re-wired.
- **REQ-U-08 i18n authoring rule absent from `core/`** (P4) — canonical section in `core/SDP.md` + per-Stage anchors.
- **`run_segment_tmux.sh` port** (P5) — de-domained + adapters wired; see item 1 for residual gaps.
- **Token cap + 6-project regression harness** (P6) — enforcement seam + acceptance harness built; see items 3 & 4 for the live-accounting and real-run gaps.
- **Global config consumer convergence (repository head)** — anchor, gate/MCP, tmux, Orca and regression now share local→XDG→passwd-home discovery; unsafe presence fails closed and audit rows record the actual selected gates path. Deployment remains governed by the procedure below.
- **Escalation cadence windows (repository head)** — `cadence.marker_span` lets one marker discharge several rounds; window anchor decides the required kind, log-derived counter decides expiry, `since=` pins evidence freshness to the BLOCK that opened the window. Bounded by `sdp-regression.sh` and registered as NC-29.
- **Gate checklist enforcement (repository head)** — `review_checklist_include` / `require_checklist` now validate and inject bounded nonce-delimited untrusted policy data. Older installed cache versions remain covered by NC-24 until rollout.

> **Gate-verification environment note.** When neither a `claude` nor an `agy` CLI is resolvable on the getpwnam-derived safe path, `python3 scripts/review_gate.py doctor` reports `health: UNHEALTHY` and exits 1. Running the real gate on any artifact then returns **INFRA_ERROR → BLOCK** (attended: stage may advance, merge/push refused until a clean ALLOW clears the infra flag) — *not* a real ALLOW. The audit wiring records this INFRA_ERROR verdict. A genuine `ALLOW` requires a real `claude` (or `agy`) reviewer on the safe path; the integration suite exercises the verdict path with a controllable **stub** reviewer only.
