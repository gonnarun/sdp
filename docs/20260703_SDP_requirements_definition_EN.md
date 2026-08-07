# SDP — General-Purpose Worktree Dispatch Plugin — Requirements Definition

| Field | Value |
|---|---|
| Document | Requirements definition for the SDP (shared staged-workflow / worktree harness) marketplace plugin |
| Date | 2026-07-03 |
| Version | v1.0-draft (becomes v1.0 once the 15 open decisions in §14 are confirmed) |
| Method | Team investigation (5 topics in parallel) → adversarial cross-review (5) → synthesis. Load-bearing corrections verified against source. |
| Status | **Requirements defined.** Implementation not started. Begins after §14 decisions are confirmed. |
| Prior doc | Feasibility review and Korean-canonical requirements (both private; not published) |

> **Redaction note (open-source release)**: SDP was extracted from six private repositories. Their names are redacted throughout this document as **Project-A … Project-F**, and the private prior documents referenced above are not published. Every requirement, correction and acceptance criterion is otherwise unmodified — this is the original design record, not a rewrite.

> **Purpose**: Promote the SOP/workflow infrastructure — currently duplicated ~1MB × 6 copies across 6 projects (Project-A / Project-B / Project-C / Project-D / Project-E / Project-F) — into a single **marketplace-installable shared plugin `sdp`**. Corrections raised during cross-review are folded in. The three load-bearing corrections (requirement #6 already implemented / raw-CLI gate not yet satisfied / resume uses an explicit thread-id) were confirmed by grepping source.
>
> **Publishing note**: All plugin-facing assets (SDP core, command definitions, README, this document) are authored in **English** for global-market publishing. **Runtime deliverables produced by the commands (Stage outputs, checklists, handovers) auto-select the language of the installed environment** — see REQ-U-08.

---

## 1. Overview / Purpose

| Item | Content |
|---|---|
| Goal | Consolidate per-project duplicated SOP/batch/worktree infrastructure into a **single language-agnostic plugin**, distributed and updated via the marketplace. Must keep working in other projects even after Project-A is deleted. |
| Background problems | (a) `scripts/sop/` relative paths hardcoded; (b) `base_dir` forks per project (`.references/임시` vs `.private/임시`); (c) command-name drift across 5 names (`/sop`·`/batch-sop`·`/meta-sdp`·`/meta-workflow`·`/worktree-dispatch`); (d) **real drift bug**: `agy-gate-fallback.sh` exists only in Project-A → the other 5 projects unconditionally Fail-Close BLOCK when codex does not run. |
| Key deliverables | ① Shared SDP core (de-domained), ② single `codex-gate.sh` gate, ③ three commands (`sdp`/`batch-sdp`/`worktree-dispatch`), ④ project-injected config schema (`defaults.yaml` 2-layer + `gates.yaml` + `test.*`). |
| Immediate win | Consolidation alone resolves the Fail-Close drift bug in 5 projects. |

---

## 2. Scope / Non-scope

**In scope**
- A **de-domained SDP core** holding no language/tool command literals (orchestration, gates, agent team, bridge summaries, fix loop).
- `codex-gate.sh`: works under the same contract (first line `ALLOW:`/`BLOCK:`, exit 0/1) whether or not the plugin (companion) is present. Includes a raw-codex-CLI-only path.
- Three commands + a single shared SDP core. Marketplace packaging.
- New escalation state machine (team re-review on even rounds ≥6, planner-solo blocked).
- Universal real-world test tiers (smoke+integration mandatory floor) + real-runtime bring-up / DB isolation / destructive-guard config.

**Out of scope**
- Project domain rules (`CLAUDE.md`, `.claude/rules/*`, `forced.*` extension keys, domain review checklists) — **owned by each project, not migrated**.
- Project-F legacy workflow (`WORKFLOW.md`/`META_WORKFLOW.md`/`meta_workflow.defaults.yaml`, `workflow_prompt/`+`workflow_codex/` dual tree) migration — separate follow-up track (decision §14).
- Each project's build/test/migrate command implementations — referenced only as injected config values.

---

## 3. Terminology

| Term | Definition |
|---|---|
| SDP core | Read-only orchestration asset that projects cannot modify. Holds no language/tool command literals. |
| dispatch adapter | The three commands that call the shared SDP core (only the orchestration layer differs). |
| Gate | The codex adjudication checkpoint between Stage 4 (design·implementation plan) / Stage 7 (test execution). |
| 3-state verdict | `ALLOW` / `BLOCK` (substantive rejection) / `INFRA_ERROR` (codex·agy unavailable·timeout·empty output·schema violation). |
| ROUND | Cumulative BLOCK count. Anchor of the escalation counter. |
| TEAM_REVIEW / TEAM_CARRY | Even-round team-reconfiguration review marker / odd-round team-retention marker. |
| mandatory floor | The minimum test layer required at risk tier T2+ (smoke + ≥1 integration against a real backing service). |
| base_dir | Single root for deliverables·gate logs·halt·thread files. **Common default = `${CLAUDE_PROJECT_DIR}/.private/sdp-artifacts`** (project-overridable). Replaces Project-A's legacy `.references/임시`. |
| deliverable tree | `${base_dir}/{YYYY-MM-DD}/{topic}/{doc-type}...` — organized date → topic (feature) → doc-type (inherits Project-A's organization). |
| sdp-artifacts | Default base_dir folder name. Matches the `artifacts` config term; placed under `.private/` to avoid collision with the config directory `.sdp/`. Project-overridable. |
| anchoring | Mechanism where command entry fixes `SDP_ROOT` and writes it to `${base_dir}/.sdp_runtime.env`, which gate bash then reads. |
| output locale | The language in which runtime deliverables are authored. Auto-selected from the installed environment; project-overridable. See REQ-U-08. |

---

## 4. Current-State Summary (cross-review corrections applied)

| # | Current state | Correction / note |
|---|---|---|
| 4.1 | Core is separable (SOP.md skeleton, 500-char bridge summary, 12× fix loop, Agent Team, gate bash) | `run_segment_tmux.sh` lives in **`scripts/meta_wf/`**, not `scripts/sop/`. |
| 4.2 | **The core itself is polluted with Project-A domain rules** | SOP.md/Phase2/4/5 body contains `tenant_id VARCHAR(16)`·Flyway filename·`./gradlew`·`start.sh`. Splitting config is insufficient → **de-domain the body text**. |
| 4.3 | **The codex gate PROMPT itself is domain-polluted** | Phase2 review items hardcode MariaDB-only syntax·lombok `@Data`·`@Auditable`·`@DataScopeFilter`·`INVARIANTS.md`. Not only build/test commands — the **review prompt must also be externalized**. |
| 4.4 ✅verified | Requirement #6 (team re-review at 6+) is **not a net-new feature** | **Correction (source-confirmed)**: already implemented in Project-A `Phase2_구현계획서.md` — when `BLOCK_COUNT>=6` and no `CONSENSUS_REACHED` marker exists after the last BLOCK, codex re-run is physically refused; "do not substitute planner-solo" is spelled out. **But the current cadence forces every round (7–12)**, whereas the requirement is even rounds only. Actual work = **consolidation + cadence adjustment + retaining the planner-solo hard block**. |
| 4.5 ✅verified | Requirement #5 (raw-CLI-only gate) is **not met today** | **Correction (source-confirmed)**: when companion is absent, it does **not** fall to a raw `codex exec` fresh review — it goes straight to agy → Fail-Close. resume is already implemented as `codex exec resume "$THREAD_ID"` with an **explicit thread-id** (4-tuple `threadId\|basename\|block_count\|epoch`), not `--last`. **Adding a raw `codex exec` fresh-review tier is the real new work.** |
| 4.6 | The batch execution engine forks fundamentally | tmux-long-lived (Project-A family) vs **Agent-tool-dispatch (Project-D family)**. Project-D's codex auto-mode classifier hard-blocks `tmux`/`claude -p`/`bypassPermissions` unattended loops, forcing a switch to the Agent tool. |
| 4.7 ✅verified | Design-doc approach has prior art | A `design-doc.md` command **already exists in all 6 projects** → material for requirement #4. |
| 4.8 | Drift bug | `agy-gate-fallback.sh` only in Project-A (in fact 2 copies: `scripts/sop/`+`scripts/sop_codex/`). Consolidation auto-resolves. |
| 4.9 | Plugin variable trap | `${CLAUDE_PLUGIN_ROOT}` is exported only in the command/skill frontmatter context. Body bash in Phase*.md runs as a separate Bash call, so propagation is uncertain → **anchoring is mandatory**. |

---

## 5. Functional Requirements (REQ table)

> Priority: **M** (must) / **S** (should) / **C** (conditional). All user requirements 1–9 are traceably covered (zero gaps).

### 5.1 Plugin / Marketplace (user req #1)

| ID | Requirement | Pri | Verification |
|---|---|---|---|
| REQ-P-01 | Marketplace-installable plugin. Layout `.claude-plugin/plugin.json` + `marketplace.json` + `commands/` + `core/` (SDP.md+Stage1~8) + `scripts/` (codex-gate.sh·agy-gate-fallback.sh·run_segment_tmux.sh) + `skills/`. | M | 3 commands work from installed build |
| REQ-P-02 | All core references relative to `${CLAUDE_PLUGIN_ROOT}`. State (counters/halt) under `${CLAUDE_PLUGIN_DATA}` or `${base_dir}`. Deliverables under `${CLAUDE_PROJECT_DIR}`/`${base_dir}`. Remove all `scripts/sop/` relative paths and user absolute paths. | M | grep for hardcoded paths = 0 |
| REQ-P-03 | **Anchoring**: command entry fixes `SDP_ROOT` + fixes base_dir (REQ-U-06) + auto-creates `.private` and registers gitignore (REQ-U-07), then writes `${base_dir}/.sdp_runtime.env`. Gate bash reads core/helper paths and base_dir from that file (no reliance on `${CLAUDE_PLUGIN_ROOT}` propagation). | M | Helper source succeeds when gate bash runs standalone |
| REQ-P-04 | All shared assets vendored inside the plugin. No dependence on external files / cross-plugin symlinks (marketplace cache copy skips external symlinks; local install breaks cross symlinks). **Ship the 3 commands + shared skill in one plugin.** | M | Local + marketplace install smoke |
| REQ-P-05 | Pin `sdp_version` in project config. Freeze the version so an in-flight batch/worktree session's gate-log/halt format does not change on plugin update. | S | Counter integrity across update |

### 5.2 Generality / De-domaining (user req #2)

| ID | Requirement | Pri | Verification |
|---|---|---|---|
| REQ-U-01 | **Core invariant**: the SDP core holds no build/test/lint/migrate command strings, DB schema rules, or framework conventions as literals. All are config-key references (`${build.*}`,`${base_dir}`,`${migrate.*}`,`${test.commands.*}`). | M | Zero stack literals in core files |
| REQ-U-02 | Remove domain sentences (`tenant_id`/Flyway/gradle/`start.sh`, etc.) from SDP.md/Stage*.md body → externalize to config references or a **project rules addendum**. | M | 6-project regression passes |
| REQ-U-03 | **De-domain the gate review prompt too**: core prompt covers only universal items (REQ coverage·impact·scope match·unauthorized external send·trust boundary·no secret leak). Domain checks (MariaDB/lombok/INVARIANTS, etc.) are injected per-project via `gate.review_checklist_include`. **A minimal security baseline (secrets/PII logging) stays in the core** (prevents regression even if a project leaves include empty). | M | Zero domain literals in core prompt |
| REQ-U-04 | `forced.*` **2-layer merge**: base safety keys (`hardcoded_secret_block`, `redact_secrets`, `no_auto_push_to_main`, `sandbox_outputs_under_base_dir`, `migration_creation_requires_approval`) are common; domain rules added freely via `project.forced_ext`. **Base safety keys allow strengthening override only, never weakening.** | M | Load fails on a weakening override |
| REQ-U-05 | Specify config discovery order: `${PWD}/.sdp/defaults.yaml` → `${PWD}/scripts/sdp/defaults.yaml`. Promote `base_dir` to a single config key from which all paths derive. | M | Discovery order documented + tested |
| REQ-U-06 | **Unified deliverable root**: base_dir default = `${CLAUDE_PROJECT_DIR}/.private/sdp-artifacts`. Tree = `${base_dir}/{YYYY-MM-DD}/{topic}/{doc-type}` (date→topic→doc-type, inheriting Project-A's organization). Replaces Project-A's legacy `.references/임시` and the Project-D-family `.private/임시` with this single default (project-overridable). | M | Deliverable path convention |
| REQ-U-07 | **Auto-create `.private` + register gitignore** (idempotent): during the entry anchoring step, if `${CLAUDE_PROJECT_DIR}/.private` is absent, auto `mkdir -p`; then check whether `.gitignore` already contains `.private/` → append one line if missing (no duplicate append; no-op if present). If base_dir is overridden outside `.private`, apply the same rule to that root. | M | `.private` created + single idempotent `.gitignore` line |
| REQ-U-08 | **Deliverable language — English-canonical + locale sync (i18n)**: plugin-facing assets (SDP core, command defs, README, this doc) stay **English**. For **runtime deliverables** (current-state report, design·plan, test plan/results, verification checklist, handovers, gate human-readable lines), **English is the canonical original**; when the installed-environment locale differs from English and `output_locale: auto`, a **synchronized copy in that locale is also generated for user verification**, kept in sync with the English canonical. `output_locale` modes: `auto` (default — English canonical + env-locale sync copy when locale≠en) \| `en` (English only) \| `<locale>` (single fixed language). Detection: `output_locale` explicit → env (`LC_ALL`/`LANG`, Claude Code UI locale) → English. Machine-parsed tokens (`ALLOW:`/`BLOCK:`, markers `CONSENSUS_REACHED`/`TEAM_REVIEW`, REQ IDs, config keys) stay ASCII/English regardless of locale. | M | locale≠en produces canonical EN + synced locale copy; `en` = single; markers ASCII |

### 5.3 Stage Model Renumbering (user req #3) — details §7

| ID | Requirement | Pri | Verification |
|---|---|---|---|
| REQ-S-01 | Surface stage numbers are **integers 1..8**. No 0 / 0.5 / negative / decimal (2.5 fix-plan) numbering. | M | Progress display + filenames integer-only |
| REQ-S-02 | Promote interview and requirements-normalization to formal Stage 1·2. Fix-loop outputs named "Stage 4 re-run (Nth)" instead of a decimal number. | M | Output naming rule |

### 5.4 Design-Doc Approach (user req #4) — analysis/recommendation §8

| ID | Requirement | Pri | Verification |
|---|---|---|---|
| REQ-D-01 | Make Stage 4 a **design-led, plan-inclusive** single stage: ① design-decision section (language-neutral: component boundaries·interface contracts·data/state model·key trade-offs) → ② implementation-plan section (stack-specific: tasks·file changes·order·rollback). | M | Stage 4 output structure |
| REQ-D-02 | **Conditional promotion**: if impact is High (security/PII/DB-schema/public API·contract) or blast radius is exceeded (new module/service, cross-cutting beyond N files, large brownfield delta), promote to a standalone `design_{feature}.md` + **one early design gate**. Otherwise (small/medium·Low) keep the design section inline; when trivial, a one-line `design trivial: {reason}` (an explicit, logged decision). | M | Auto-judge promotion threshold |
| REQ-D-03 | Record meaningful design decisions as **ADRs** (decision + alternatives + rationale + status: proposed/accepted/superseded). Standalone file outside Stage 4 only when promoted. | S | ADR present/traceable |
| REQ-D-04 | Traceability **REQ→design element→file→test** (4-hop). Design section = REQ→design matrix, plan section = REQ→file, test = REQ→design invariant→test case. | M | 3 matrices |
| REQ-D-05 | **Detail-level ceiling (readability)**: Stage 4 design/plan content is written to a level a typical developer can skim and act on — not exhaustive. No over-granular tables of contents, no redundant restatement, no micro-specification the author never re-reads. Prefer decisions + rationale + the changes that matter; omit boilerplate. Traceability tables stay compact. (Requirements docs may be more precise — this ceiling targets design/plan verbosity.) | M | Reviewer confirms no over-detailing |

### 5.5 Codex Gate (user req #5) — details §9

| ID | Requirement | Pri | Verification |
|---|---|---|---|
| REQ-G-01 | `codex-gate.sh` single contract: input = PROMPT + artifact, output = stdout first line `ALLOW:`/`BLOCK:` + exit (0/1). The plugin is a thin wrapper that only **calls** this script (no logic duplication). | M | Contract smoke |
| REQ-G-02 | **4-tier fallback**: companion (accelerator if present, optional) → **raw `codex exec` fresh review (new tier)** → agy fallback → Fail-Close BLOCK. Remove node dependence (companion JSON parser·version scan) from the verdict path; use only POSIX awk/grep/flock. | M | Verdict succeeds via raw with companion off |
| REQ-G-03 | fresh: `codex exec --json --skip-git-repo-check -s read-only [-m $CODEX_GATE_MODEL] -o OUT "$PROMPT"`. Capture `thread.started.thread_id` from `--json`; parse the verdict from **the OUT file only** with awk (the `--json` JSONL may carry non-fatal errors → never use it as verdict basis). | M | thread_id + verdict captured |
| REQ-G-04 | Re-review uses an **explicit UUID** `codex exec resume "$UUID"`. `--last`/`--all` fully forbidden (concurrency cross-contamination). stash key = artifact basename + **cwd (pwd)** (no git-dir hash: worktrees share a git-dir → collision). flock serialization. | M | No UUID collision under concurrent gates |
| REQ-G-05 | Elevate the verdict to structured JSON `{verdict, reason, findings[]}` via `--output-schema`; the first-line string is a human echo. Classify empty output / invalid JSON as INFRA_ERROR (reduces false BLOCK). | S | Schema verdict passes |
| REQ-G-06 | **3-state verdict**: `ALLOW`/`BLOCK`/`INFRA_ERROR`. Default INFRA_ERROR policy is mode-dependent (attended = warn + flag then continue, unattended = pause + notify, auto-advance opt-in only). Force gate re-run before merge. (Default value §14.) | M | 3-state branching |
| REQ-G-07 | `resume` has no `-s` flag → fix read-only in fresh with `-s read-only` and inherit, or override via `-c sandbox_mode`. The gate cannot modify the repo. | M | read-only retained on resume |
| REQ-G-08 | Ship `codex-gate.sh doctor` (codex/agy presence·version) + a companion on/off **parity smoke** (assert identical exit·first-line grammar). | S | doctor·smoke pass |
| REQ-G-09 | Ship `agy-gate-fallback.sh` as a single source under the plugin `scripts/` → resolves the 5-project drift bug at once. Clean up Project-A's 2 duplicate copies. | M | fallback OK in all 6 projects |

### 5.6 Escalation (user req #6) — details §10

| ID | Requirement | Pri | Verification |
|---|---|---|---|
| REQ-E-01 | BLOCK 1–5: planner-led fixes allowed, no team obligation. | M | State machine |
| REQ-E-02 | **Planner-solo hard-blocked across the entire ≥6 range**: awk roster validation (comma-split ≥2 members & not planner-only). If unmet, refuse codex re-run (`BLOCK: planner-solo forbidden — team re-review not performed`). | M | Entry refused when roster<2 |
| REQ-E-03 | Even rounds (6·8·10·12): mandatory `TEAM_REVIEW` marker = roster diff + cumulative 1..n BLOCK root-cause table + decision (continue\|pivot\|halt). Odd rounds (7·9·11): `TEAM_CARRY` (retain the last TEAM_REVIEW roster; planner-solo still forbidden). | M | Marker grammar/parity check |
| REQ-E-04 | Fixed marker grammar: `TEAM_REVIEW <ISO> round=<n> roster=<a,b,..> added=<..> removed=<..> rootcause=<..> decision=<continue\|pivot\|halt> summary=<..>`. Guard validates roster≥2·not-planner-solo·round parity·decision present via awk. | M | Grammar parser |
| REQ-E-05 | **Forgery resistance**: markers name each agent's output path; the guard checks file existence + recent mtime + distinct paths. Full prevention is impossible — stated in the doc. | S | Output path verification |
| REQ-E-06 | BLOCK 12 → `.halt` + user report. Same BLOCK first-line twice in a row → `.halt`. **Cadence-halt conflict resolution**: place halt after the 12th TEAM_REVIEW so it executes (halt blocks the 13th entry), or make 12 halt-only explicitly (§14). | M | 12th re-review reachable |
| REQ-E-07 | On decision=pivot, whether counter RESET is allowed · pivot cap (e.g. 2) to prevent infinite bypass of the 12 limit. | S | pivot cap |
| REQ-E-08 | Escalation is **per-artifact log** based (independent counters even under batch/worktree parallelism). Roster/cadence/halt thresholds externalized to `gates.yaml` (code checks only cardinality·parity). A **global concurrency cap** prevents N parallel artifacts summoning N×max-team simultaneously. | M | Independent parallel counters + cap |

### 5.7 Test Strategy (user req #7) — details §11

| ID | Requirement | Pri | Verification |
|---|---|---|---|
| REQ-T-01 | Testing Trophy: **mandatory floor = smoke + ≥1 integration against a real backing service**, risk-gated = contract/e2e (T2 optional·T3 required), supporting = unit. Demote unit from the spine. | M | DoD check |
| REQ-T-02 | **T1 (low-risk: i18n keys/colors/copy/labels) exempt**: the mandatory floor is not blanket. Scoped to risk tier. | M | T1 exemption works |
| REQ-T-03 | **Serviceless generality**: library/CLI/compute packages define "real-world test" as real filesystem/subprocess/SUT self-hosted local HTTP. Decouple the mandatory concept from DB/service dependence. | M | DB-less project passes |
| REQ-T-04 | Universal `test.*` config: opaque command map (install/build/lint/unit/integration/contract/e2e/smoke/migrate/seed) + service health probe (http/tcp/cmd) + layers (mandatory/risk_gated/supporting). Core assumes no gradlew/npm/JUnit; runs only existing commands, skips absent ones with a logged reason. | M | Schema + skip log |
| REQ-T-05 | `db.isolation ∈ {transaction, dedicated_test_db, ephemeral_container}`. Default `dedicated_test_db`. High-risk (triggers/DDL/multi-connection verification) forces dedicated/ephemeral. Recommend **Testcontainers** (language-agnostic random-port·ready-wait) as the standard ephemeral backend. | M | Isolation modes work |
| REQ-T-06 | **Destructive guard** (generalized flyway_prod_block, Fail-Close): writeful real-world tests run only if the target DSN passes a test-marker allowlist (localhost/container/explicit test). Abort on prod-denylist match or an unclassified DSN. Remote test servers/DBs **must be explicitly registered in the allowlist** (priority §14). | M | prod DSN aborts |
| REQ-T-07 | **Teardown safety**: `dedicated_test_db` uses `db.reset` (truncate/re-migrate) only, never `down -v` (prevents deleting the shared dev DB volume). `down -v` is for `ephemeral_container` only. Refuse `down -v` when the compose project name equals the dev project name. | M | Dev DB not destroyed |
| REQ-T-08 | worktree runtime: `serial_main` (default·infra-free: sessions produce checklists only, main runs serially after merge) vs `ephemeral_per_worktree` (opt-in: `docker compose -p <slug>` + dynamic ports/network DNS + ephemeral DB). Projects that cannot parameterize auto-fallback to serial_main. Both modes keep identical gate strength. | M | Both modes work |
| REQ-T-09 | **flake policy**: classify infra-flake vs real-fail; infra-flake gets N retries + quarantine label; codex **BLOCKs on real FAIL only**. Retry logging keeps infra noise from triggering the req#6 6+ consensus loop. | S | flake isolation |
| REQ-T-10 | **Objective evidence appendix**: the test-results doc records executed command + exit code + service log tail + DB connection/query count (e.g. `pg_stat_activity`/connection counter). codex reviews evidence, not self-testimony (confirms real backing target·not mock). | S | Evidence present |
| REQ-T-11 | Auto risk-tier: `risk_globs.{T1,T2,T3}` lets the planner auto-judge from changed-file globs (e.g. T3: `**/crypto/**`,`**/auth/**`); user override at interview. | S | Glob judgment |

### 5.8 Command System (user req #9) — details §12

| ID | Requirement | Pri | Verification |
|---|---|---|---|
| REQ-C-01 | **One shared SDP core + 3 dispatch adapters** layering. All 3 commands run identical Stage 1~8 + 2 gates + evaluator PASS at identical strength (invariant). | M | Single core source |
| REQ-C-02 | `sdp` = single-scope·inline·serial. Below the size threshold, a **fast-path** (skip design doc·collapse stages) prevents over-engineering small tasks. | M | fast-path works |
| REQ-C-03 | `batch-sdp` = large-scope·split·unattended. **Config-selectable execution-engine adapter**: `agent_tool` (default·recommended, compatible with the codex auto-mode classifier) vs `tmux_long_lived` (opt-in). tmux unattended loops may be blocked outright in codex-gated projects, so tmux is not promoted as default. | M | Both engines work |
| REQ-C-04 | `worktree-dispatch` = multiple independent tasks·parallel·handover-based. Main performs only Stage 1 (interview) with the user → per-task handover (human paste) → each session runs full SDP workflow in a worktree. **Invariant constraints**: sessions never run screen tests directly (shared docker/DB/port collision), produce checklists only; screen tests run serially by main after merge. Unattended §0-A supported. | M | Constraints preserved |
| REQ-C-05 | Prevent cross-task worktree conflicts: main writes once a **design skeleton / data-model contract** covering only shared surfaces (schema·shared modules·trust boundaries) into the handover (Stage 1 dispatch output); each session designs task-local beneath it. | S | Contract handover |
| REQ-C-06 | Key GATE_LOG by (command·scope·artifact) → parallel paths get independent counters·independent escalation. Parallelism cannot bypass the round-6 team-review obligation. | M | No parallel bypass |
| REQ-C-07 | **worktree-dispatch auto-launch mode** (`dispatch_mode: manual \| auto`): remove the manual copy-paste of handovers. In `auto`, main launches each selected task as a long-lived headless session (reuse `run_segment_tmux.sh`: `git worktree add` → tmux `claude --permission-mode bypassPermissions` in the task's worktree → **inject the handover prompt automatically** → session runs full SDP workflow under §0-A unattended → writes 완료기록 to main's `base_dir` → existing incremental integration trigger). **Hard constraints**: (a) codex auto-mode classifier may block headless/tmux/bypassPermissions loops (§4.6) → `auto` is config-selectable and falls back to `manual`/`agent_tool` when blocked; (b) runtime-touching stages require `test.worktree.runtime_isolation: ephemeral_per_worktree` (REQ-T-08), else they stay checklist-only and main runs them serially (current invariant preserved); (c) requires a one-time `bypassPermissions` grant + mandatory §0-A + K cap + hard deadline + kill switch. Gate strength identical to manual. | M | auto launches sessions with zero manual paste; falls back when classifier blocks |

### 5.9 Prior Art / Enhancements (user req #8) — details §13

| ID | Requirement | Pri |
|---|---|---|
| REQ-R-01 | Cite GitHub prior-art findings as design basis (§13 table). | S |
| REQ-R-02 | Present enhancement candidates (verification gate, NDJSON audit log, quorum option, token/time budget cap, auto risk-tier) as a separate roadmap. | C |

### 5.10 Traceability Matrix (user req → REQ)

| User req | Covering REQ |
|---|---|
| #1 marketplace plugin | REQ-P-01~05 |
| #2 language-agnostic | REQ-U-01~08 |
| #3 stages 1,2,3 | REQ-S-01~02 |
| #4 design doc vs impl plan | REQ-D-01~05, §8 |
| #5 gate without plugin install | REQ-G-01~09 |
| #6 6+ even-round team review·planner block | REQ-E-01~08 |
| #7 broad real-world tests | REQ-T-01~11 |
| #8 GitHub prior art·enhancements | REQ-R-01~02, §13 |
| #9 3 commands role boundary·shared core | REQ-C-01~07 |
| (publishing) English assets + locale-aware deliverables | REQ-U-08 |

---

## 6. Non-Functional Requirements

| ID | Item | Requirement |
|---|---|---|
| NFR-01 | Language-agnostic | Verdict·counter·escalation logic uses only POSIX awk/grep/flock. Zero node-dependent verdict paths. |
| NFR-02 | Portability | Gate respects config.toml/env vars. No model hardcoding (`-m` only when `CODEX_GATE_MODEL` is set). Provide an optional **recommended default model pin (overridable)** for cross-machine verdict reproducibility. |
| NFR-03 | Safe defaults | Gate `-s read-only` (reviewer cannot modify repo). Destructive guard Fail-Close. No weakening override of base safety keys. |
| NFR-04 | Auditability | Record gate decisions·dispatch events·resolved provider+version as an NDJSON audit log (replay/diff). |
| NFR-05 | Resource caps | Per-task token/time hard cap + BLOCK 12 halt + global concurrency cap for parallelism. Prevents runaway token burn in long unattended runs. |
| NFR-06 | Session retention | Keep resume rollouts non-ephemeral (`--ephemeral` forbidden). Specify cleanup/retention policy for accumulated sessions across 6 projects. |
| NFR-07 | Regression safety | After de-domaining·renaming, 6-project regression is mandatory (confirm zero gate-strength weakening). |
| NFR-08 | i18n integrity | Deliverable language follows env locale (REQ-U-08), but machine-parsed tokens/markers/IDs/config keys stay ASCII/English. Locale detection failure falls back to English, never blocks. |

---

## 7. Stage Model — Renumbering (req #3)

### 7.1 Mapping

| New Stage | Current | Name | Gate | Approval |
|---|---|---|---|---|
| **1** | Phase0_0 | Interview (scope the investigation) | — | User |
| **2** | Phase0_5 | Requirements normalization | — | Planner-led |
| **3** | Phase1 | Current-state report | — | — |
| **4** | Phase2 | **Design·Implementation plan** (design-led, plan-inclusive) | **Gate A** (plan gate, + conditional early design gate) | evaluator |
| **5** | Phase3 | Implementation | — | — |
| **6** | Phase4 | Test plan | — | — |
| **7** | Phase5 | Test execution (real-world) | **Gate B** (test-results gate) | evaluator |
| **8** | Phase6 | Verification checklist | — | User |

### 7.2 Rules
- Retire decimal/0/negative numbers. Fix-loop outputs named "Stage 4 re-run (Nth)" (no 2.5).
- Rename files `Phase1_..~Phase8_`. Replace numbers uniformly across progress display·bridge summary (500-char)·fix loop (12×).
- Stage 8 filename uses the generic **`verification_checklist`** as the core default (covers screenless CLI/library projects). Screen test is its T2/T3 sub-tier.
- Whether to merge intake (Stage 1+2) into one stage for a 7-stage total is a decision (§14 D-02).

---

## 8. Design Doc vs Implementation Plan — Analysis & Recommendation (req #4)

### 8.1 Frame correction
"Design doc or implementation plan" is a false choice. They are not substitutes but outputs at **different altitudes**: design doc = structure·interfaces·data model·trade-offs (what/why, audience = architect); implementation plan = task breakdown·file changes·order·rollback (how, audience = implementer). The current Phase2 is a hybrid that dissolves design judgment into the file-change spec, so structural errors surface only at the file-spec stage (delayed detection).

### 8.2 Prior-art comparison (links to req #8)

| Case | Position | SDP implication |
|---|---|---|
| spec-kit | Implementation-plan-first (design output embedded in the plan). **But** its user surface is named commands (/specify,/plan,/tasks,/implement) + an internal Phase -1 gate → **weak** as a precedent for "clean 1,2,3 numbering" (uses a negative phase). | Supports plan-embedded direction; not adopted as numbering basis |
| Kiro | Forces a separate `design.md`. **Böckeler (Thoughtworks, ※not Martin Fowler)** critique: markdown review is verbose, "a sledgehammer for a walnut" on small fixes. | Making a heavy standalone design doc the default over-burdens small tasks |
| ADR/RFC/arc42/C4 | Industry standard for recording design decisions in lightweight units. | Name the design section = ADR |

### 8.3 Brownfield correction (cross-review core)
The cited spec-kit/Kiro are greenfield-biased. **SDP is brownfield** (edits based on the Stage 3 current-state report). In brownfield the design doc's value is capturing the **delta architecture** (how the change meshes with existing structure), which a pure implementation plan can under-specify. So "plan-embedded is always better" holds for greenfield only.

### 8.4 Recommendation — **conditional tiered (design-led, plan-inclusive)**
1. **Single Stage 4**: design section (language-neutral) first → implementation-plan section (stack-specific). Keeps clean surface numbers 3 (current-state)·4 (design·plan)·5 (implementation) → consistent with req #3.
2. **Conditional promotion (REQ-D-02)**: High/large/large-brownfield-delta → standalone design doc + one early design gate. small/medium·Low → inline design section, one-line explicit skip when trivial.
3. **Correction**: a "single-call 2-lens" gives no real early structural-detection benefit (still reviews after the file spec is written). Genuine early detection comes only from **the advanced gate in the promoted case** → non-promoted cases explicitly "accept late structural detection".
4. **What is rejected**: rejecting "mandatory 2-document split for all work" (small-task overkill·number inflation), not the promotion path itself.
5. **Fix-loop over-engineering guard**: do not force a design section onto a 1-line bugfix in the 12× fix loop → fix outputs carry deltas only.
6. **Traceability REQ→design→file→test (REQ-D-04)**. The codex design lens outputs "which design invariant each planned test proves" → prevents design theater + directly serves req #7.

**Conclusion**: "current-state → design doc" and "current-state → implementation plan" are not a dichotomy. The SDP universal workflow adopts **Stage 4 = a single stage with a design section first + an implementation-plan section after**, promoting to a standalone design doc (with an advanced design gate) only for high-risk/large/large-brownfield-delta cases.

---

## 9. Codex Gate (plugin + CLI-only) (req #5)

### 9.1 Verified CLI surface (measured)
On codex 0.141.0, `codex exec` has `-m`, `--skip-git-repo-check`, `-o/--output-last-message`, `--json`, `--output-schema`, `-s read-only|workspace-write|danger-full-access`. `codex exec resume [SESSION_ID] --last --all --output-schema --json -o` exists (but **resume has no `-s`**). Capture UUID from fresh `--json` first event `{"type":"thread.started","thread_id":"..."}`, capture verdict via `-o OUT`. (The current Project-A Phase2 gate already uses explicit-id `codex exec resume "$THREAD_ID"` — not `--last`.)

### 9.2 Verdict pipeline

```
codex-gate.sh <PROMPT> <artifact>
 ├─ tier1 companion (accelerator if present, optional)
 ├─ tier2 raw codex exec  ← fresh review (req #5 real new work)
 │     fresh: codex exec --json --skip-git-repo-check -s read-only [-m $MODEL] -o OUT "$PROMPT"
 │            → capture thread.started.thread_id, parse verdict from OUT only (--json JSONL not basis)
 │     re-review: codex exec resume "$UUID"  (--last/--all forbidden)
 ├─ tier3 agy fallback
 └─ tier4 Fail-Close BLOCK
Contract: stdout first line ALLOW:/BLOCK: + exit 0/1  (structured --output-schema {verdict,reason,findings} first-class; first line is echo)
```

### 9.3 Key rules
- **Concurrency**: stash key = artifact basename + **cwd (pwd)**. No git-dir hash (worktrees share a git-dir → UUID merge). flock -x serialization. Same-cwd concurrency (Stage4 plan gate + Stage7 test gate, batch segments) is the real risk → defend with explicit-UUID resume.
- **resume-failure detection**: invalid ids still exit 0 → detect failure only via stderr patterns (`^Error:`/`thread`/`resume failed`/`no rollout found`). Inherit the `trap EXIT` stash discipline exactly (re-stash on the BLOCK branch then `trap - EXIT`; omission loses the thread).
- **INFRA_ERROR 3-state (REQ-G-06)**: codex+agy both unavailable·timeout·empty output·schema violation are separated from a genuine BLOCK. Policy is mode-dependent (attended = warn + flag, unattended = pause + notify, auto-advance opt-in only). Force re-run before merge. (Ref: avoids the fail-close rewake infinite-loop antipattern of codex-plugin-cc issue #248. fail-open is a **policy option**, not a requirement — req #5 is raw-CLI availability, not gate weakening.)
- **read-only inheritance**: since resume has no `-s`, fix read-only in fresh → inherit, or override via `-c sandbox_mode`.
- **anchoring**: read helper paths from `${base_dir}/.sdp_runtime.env` (REQ-P-03).
- **de-domaining**: core review prompt = universal items only; domain injected via `gate.review_checklist_include`; minimal security baseline retained (REQ-U-03).
- **doctor + parity smoke** (REQ-G-08).

---

## 10. Escalation State Machine (6+) (req #6)

### 10.1 State transitions

| Round (cumulative BLOCK) | State | Planner-solo | Required marker |
|---|---|---|---|
| 1~5 | NORMAL | Allowed (lead) | None |
| 6 (even) | ESCALATION | **Forbidden** | TEAM_REVIEW |
| 7 (odd) | ESCALATION | **Forbidden** | TEAM_CARRY |
| 8 (even) | ESCALATION | **Forbidden** | TEAM_REVIEW |
| 9,11 (odd) | ESCALATION | **Forbidden** | TEAM_CARRY |
| 10,12 (even) | ESCALATION | **Forbidden** | TEAM_REVIEW |
| reach 12 | HALT | — | `.halt` + user report |
| same BLOCK twice | HALT | — | `.halt` |

### 10.2 Vs current (cross-review correction — source-confirmed)
- **Correction**: req #6 is not net-new but a **consolidation + cadence parameterization** of what Project-A `Phase2_구현계획서.md` already implements. Current forces every round (7–12) (`CONSENSUS_REACHED` marker); the requirement is even rounds only.
- **Weakening tension**: even-only removes the odd-round team-consensus obligation → nominal weakening. **Resolution**: odd rounds keep the team via `TEAM_CARRY` + planner-solo still forbidden (entire 6+ range). Even = heavy reconfiguration review, odd = light team retention. That "even-only heavy review" is a relaxation vs current is a user-confirmation item (§14 D-08).

### 10.3 Mandatory output (TEAM_REVIEW)
① roster diff vs previous round (add·assign evaluator/researcher/Plan/architect), ② full cumulative 1..n BLOCK cause table (classify recurring/contradiction/unresolved), ③ approach-shift decision (continue/pivot/halt), ④ if decision=halt report immediately, if pivot a RESET candidate (pivot cap §14).

### 10.4 Enforcement / caveats
- Planner-solo block relies on **marker roster-cardinality awk validation** (honor + verification model) since the shell cannot see actual agent execution. Forgery resistance via output-path existence check (REQ-E-05); full prevention impossible (stated).
- **Cadence-halt conflict**: currently the halt (≥12) check precedes the consensus check, so the 12th TEAM_REVIEW is unreachable (only 6/8/10 execute). Resolution: place halt after the 12th re-review, or make 12 halt-only (§14 D-07).
- **Resource-amplification guard**: N parallel batch/worktree artifacts at 6+ summon N×max-team simultaneously → the gate would cause exactly the resource waste req #6 targets. Global concurrency cap (REQ-E-08).

---

## 11. Test Strategy (req #7)

### 11.1 Layer model
- **mandatory floor** (T2+): smoke (app/module boot + health probe) + integration ≥1 (**against a real backing service, not mock**).
- **risk-gated**: contract, e2e (T2 optional / T3 required).
- **supporting**: unit.
- **T1 exempt**: low-risk (i18n/color/copy/label) exempt from the floor.
- **serviceless** (library/CLI): real-world = real filesystem/subprocess/SUT self-hosted local HTTP.

### 11.2 Execution sequence (Stage 7)
```
install → migrate(test DB) → seed → services up + health-wait
 → [guard: DSN prod-denylist / test-marker allowlist check, abort on failure (Fail-Close)]
 → smoke → integration → (risk-gated: contract / e2e)
 → teardown( dedicated_test_db: db.reset  |  ephemeral: down -v )
```
All commands looked up from `test.commands.*`. Record each step's evidence in the test-results doc.

### 11.3 Config schema (excerpt)
```yaml
test:
  runtime: { provider, compose_file, up, down, services:[{name,health,ready_timeout_s}] }
  commands: { install, build, lint, unit, integration, contract, e2e, smoke, migrate, seed }  # opaque·optional
  layers: { mandatory:[smoke,integration], risk_gated:[contract,e2e], supporting:[unit] }
  db: { isolation: dedicated_test_db, dsn_env: TEST_DATABASE_URL, reset }
  guards: { prod_dsn_denylist:[...], require_test_marker: true, destructive_ops_require_ephemeral }
  worktree: { runtime_isolation: serial_main, port_strategy: fixed }
  risk_globs: { T1:[...], T2:[...], T3:[...] }
gate:
  review_checklist_include: "<project domain-rules file path>"
output_locale: auto   # auto | en | ko | ja | ...  (REQ-U-08)
```

### 11.4 Corrections / caveats (cross-review)
- **Correction**: req #5 is also unmet at the test gate — current fresh verdict needs companion; raw codex only resumes. Adding a raw `codex exec` fresh verdict is required.
- **Teardown risk**: `down -v` is compose-project level → deletes the shared dev DB volume. dedicated uses `db.reset` only; `down -v` is ephemeral-only.
- **serial_main reframing**: routing session screen/shared-runtime integration to checklist-only is **stricter** than current (current worktree DoD allows sessions to GREEN integration against a shared DB). Note the bottleneck re-concentrates on main's serial path.
- **flake**: only real FAIL BLOCKs codex → prevents polluting the req #6 consensus loop.
- **evidence**: executed command + exit code + service log tail + DB connection/query count makes "not mock" machine-checkable.
- **Testcontainers**: solves ephemeral·worktree port collision in one library (avoids hand-rolled `-p`+`0:5432` readback).

---

## 12. Command System + Plugin/Marketplace Structure (req #9, #1)

### 12.1 Role boundary of the 3 commands

| Command | Scope | Orchestration | Execution | Gate strength |
|---|---|---|---|---|
| `sdp` | Single task | Inline in current session | Serial (+small-task fast-path) | Full 2 gates |
| `batch-sdp` | Large scope split | Split then delegate segments | **agent_tool (default)** / tmux_long_lived (opt-in), unattended 4-charter | Full 2 gates |
| `worktree-dispatch` | Multiple independent tasks | Main = Stage 1 only → handover (human paste) | Each session full SDP workflow in a worktree, parallel | Full 2 gates (sessions no screen test; main serial after merge) |

**Shared SDP core (single copy) = Stage 1~8 + 2 gates + Agent Team**. The 3 commands are dispatch adapters that call it. All 3 paths keep the identical-strength invariant of codex 2 gates + evaluator PASS. Per-artifact GATE_LOG keying prevents parallelism from weakening/bypassing the gate.

**Correction (cross-review)**: the batch execution engine is not uniform — Project-D abandoned tmux delegation due to the codex auto-mode classifier block and switched to the Agent tool. So the batch-sdp engine is a **config-selectable adapter**, default agent_tool.

### 12.2 Plugin layout
```
sdp/
 ├─ .claude-plugin/plugin.json
 ├─ commands/ (sdp.md · batch-sdp.md · worktree-dispatch.md)
 ├─ core/ (SDP.md + Stage1~8)
 ├─ scripts/ (codex-gate.sh · agy-gate-fallback.sh · run_segment_tmux.sh)
 └─ skills/ (shared SDP-core skill, bundled)
marketplace/.claude-plugin/marketplace.json (plugins[].source ./sdp)
```
- Core reference `${CLAUDE_PLUGIN_ROOT}`, persistent state `${CLAUDE_PLUGIN_DATA}`, deliverables `${base_dir}` (default `${CLAUDE_PROJECT_DIR}/.private/sdp-artifacts/{YYYY-MM-DD}/{topic}/{doc-type}`). Auto-create `.private` + register gitignore if absent (REQ-U-07).
- **Ship 3 commands + shared skill in one plugin** (cross-plugin symlinks are skipped on local/`--plugin-dir` install, breaking the gate → within-plugin references only).
- Projects own only thin config (`defaults.yaml` override + `gates.yaml` + `test.*` + `output_locale` + `sdp_version` pin). `CLAUDE.md`/`rules/*` not migrated.

---

## 13. Prior Art · Recommended Enhancements (req #8)

### 13.1 Prior art

| Case | Core | SDP application |
|---|---|---|
| spec-kit | constitution (9-article), empty Articles IV-VI injected per project, plan-first, test-first NON-NEGOTIABLE | Universal core = principles only, stack injected "empty Article"-style via config (REQ-U) |
| Kiro / Böckeler critique | design.md mandatory vs "sledgehammer on a small task" | Basis for conditional design-doc promotion (§8) |
| codex-plugin-cc #248 | Stop hook confuses infra failure with a genuine BLOCK → rewake loop; proposes 3-way {allow\|block\|infra_error} | Verdict 3-state (REQ-G-06) |
| ccswarm | Sangha quorum consensus, NDJSON replay/diff/rollback, codex non-interactive thread-id | quorum option + audit log (NFR-04) |
| metaswarm | 5 specialist parallel reviews, **3-iteration cap → human escalation**, distrust self-report·file:line evidence, coverage blocking | Multi-party escalation (§10), evidence-based verification |
| agent-review-panel | verification gate re-checks judge hallucination, anti-groupthink | Strengthens false-BLOCK waste prevention |
| Fusion / Dex / orc | per-task worktree + plan-review-execute gate + parallel multi-reviewer + backoff | worktree-dispatch reference architecture |
| Testcontainers | language-agnostic ephemeral·random-port·ready-wait | Isolation·port-collision (REQ-T-05) |
| Taskfile/just/make | opaque command map | `test.commands.*` delegation target |
| Nx/Turborepo affected | changed-file-based auto impact judgment | auto risk-tier (REQ-T-11) |
| semantic-release verifyConditions | single contract / many providers | "plugin = thin wrapper" model (REQ-G-01) |
| pre-commit | language-agnostic hook runner | POSIX zero-coupling model |
| OPA/conftest | externalized policy | `gates.yaml` analogy |
| circuit-breaker / GitHub required-checks + CODEOWNERS | cap·roster escalation | 12 halt = circuit breaker, roster |

> ※ Names above are candidates gathered by the investigation team. Re-verify URL·license·current status before citing (some are concept/pattern references only).

### 13.2 Recommended enhancements (separate roadmap)
1. **verification gate**: re-verify BLOCK reasons against file:line evidence (stops pointless retries from false BLOCK).
2. **NDJSON audit log**: record gate decisions·dispatch·resolved provider+version → replay / prevent version-scan drift recurrence.
3. **quorum (Sangha) option**: multi-reviewer consensus instead of a single codex (opt-in for high-risk projects).
4. **`--output-schema` structured verdict**: removes string-parse failure (a cause of infra_error).
5. **token/time budget cap**: a first-class escalation trigger alongside BLOCK count and parallelism.
6. **circuit-breaker half-open**: make the 12 halt an explicit circuit breaker; override/pivot = half-open, pivot cap.

---

## 14. Open Decisions

> **Decisions — settled 2026-07-03.** Rounds 1–2 **confirmed by the user via interview** (D-02·06·07·13·03·05·09·11, all at the recommended option). Auto-applied (aligned with requirements): D-08, D-12, D-15. Resolved earlier: D-01, D-04, D-16. D-14 set to the recommended safe default (allowlist-first) — user was away; flag to change. **All §14 items are now settled.**
>
> | # | Provisional value |
> |---|---|
> | D-02 | **8 stages** |
> | D-03 | **config-tunable threshold + defaults** (promote when impact=High OR >10 files OR large brownfield delta) |
> | D-05 | **separate follow-up track** (Project-F legacy out of v1.0 scope) |
> | D-06 | **mode-dependent** (attended = warn+flag+continue, unattended = pause+notify, auto-advance opt-in) |
> | D-07 | **raise halt to 13** (12th TEAM_REVIEW executes) |
> | D-08 | **planner-solo forbidden across entire 6+ range** (auto-applied) |
> | D-09 | **RESET allowed, pivot cap = 2** |
> | D-11 | **contract = risk_gated** (not mandatory) |
> | D-12 | **risk-tier auto (risk_globs) + user override** (auto-applied) |
> | D-13 | **companion kept as optional accelerator** |
> | D-14 | **explicit-registration allowlist first; unregistered → denylist** |
> | D-15 | **single-plugin bundle** (auto-applied) |
> | D-16 | **`output_locale: auto`** = English canonical + env-locale sync copy when locale≠en (per user preference, REQ-U-08) |

| # | Item | Options | Recommendation |
|---|---|---|---|
| D-01 | Command name `worktree-dispatch` | ~~dispute~~ → **dispatch confirmed** (user directive 2026-07-03) | **Resolved.** Matches original Project-F `/worktree-dispatch` (dispatch) semantics; unified across the doc. |
| D-02 | Number of stages | 8 stages vs intake-merged 7 stages | 8 stages (interview·normalization promoted) tentative, user to confirm |
| D-03 | Design-doc promotion threshold | Fixed (10+ files/High) vs config-tunable | config-tunable + provide defaults |
| D-04 | base_dir default | **Resolved** (user 2026-07-03): common default = `${CLAUDE_PROJECT_DIR}/.private/sdp-artifacts/{YYYY-MM-DD}/{topic}/{doc-type}`, project-overridable. Auto-create `.private` + gitignore (REQ-U-07). Folder name `sdp-artifacts` (adjusted from the user's `sdp-outputs` for `artifacts` config consistency·`.sdp/` collision avoidance). | Confirmed |
| D-05 | Project-F legacy workflow migration | Include in sdp vs separate follow-up | Separate follow-up track |
| D-06 | INFRA_ERROR default policy | fail-open+warn vs fail-close BLOCK, attended/unattended split | attended = continue+flag, unattended = pause, safe by default (auto-advance opt-in) |
| D-07 | Cadence-halt conflict | Raise halt to 13 (12th re-review executes) vs 12 halt-only (cadence 12 vestigial) | Raise halt so the 12th re-review executes |
| D-08 | Odd-round planner-solo | Forbid entire 6+ (TEAM_CARRY) vs even-only obligation·odd relaxed | Forbid entire range (req #6 intent) |
| D-09 | pivot RESET cap | Allow RESET + cap (e.g. 2) vs forbid RESET | cap 2 |
| D-10 | db.isolation default | dedicated_test_db vs transaction fallback | dedicated_test_db |
| D-11 | contract test | mandatory vs risk_gated | risk_gated (no universal-tool standard) |
| D-12 | risk-tier judge | planner auto (risk_globs) vs interview-fixed | auto + user override |
| D-13 | Keep companion support | optional accelerator vs full raw-CLI unification | keep optional (needs parity regression test) |
| D-14 | Remote test DB allowlist priority | allowlist-first vs denylist-first | explicit-registration allowlist first, unregistered → denylist |
| D-15 | Shared-core packaging | single-plugin bundle vs split+symlink | single-plugin bundle |
| D-16 | output_locale default | `auto` (English canonical + env-locale sync copy) vs fixed `en` vs single `<locale>` | **Resolved** (user 2026-07-03): `auto` = English canonical original + a synced locale copy for verification when env locale≠en. Markers/IDs stay ASCII (REQ-U-08). |
| D-17 | worktree `dispatch_mode` default | `manual` (paste) vs `auto` (headless auto-launch) | **manual default + auto opt-in per wave** — auto carries classifier-block / resource / runtime-collision risk (REQ-C-07); user asked for auto, so ship it opt-in with guards. Flip default to `auto` on request. |

---

## 15. Acceptance Criteria

| # | Criterion |
|---|---|
| AC-01 | After marketplace install, with Project-A's `scripts/sop/` deleted, `sdp`/`batch-sdp`/`worktree-dispatch` all work. |
| AC-02 | grep of core files finds **zero** build/test/migrate command literals·DB schema literals·gate-review-prompt domain literals. |
| AC-03 | With companion forced off, `codex-gate.sh` reaches a verdict (ALLOW/BLOCK) via raw `codex exec` fresh review, and fallback works in all 6 projects (Fail-Close drift bug resolved). |
| AC-04 | Concurrent Stage4·Stage7 gates in the same repo + batch parallel-segment gates show zero UUID·stash cross-contamination (cwd key + flock). |
| AC-05 | At BLOCK rounds 6·8·10·12, absent a TEAM_REVIEW marker (roster≥2·not-planner-solo·decision) codex re-run is physically refused. TEAM_CARRY forced at 7·9·11. A planner-solo roster is refused across the entire 6+ range. |
| AC-06 | The 12th re-review is reachable before halt (D-07 applied). Same BLOCK twice → `.halt`. |
| AC-07 | Under N-parallel batch/worktree, per-artifact counters are independent and the global concurrency cap prevents N×max-team simultaneous summoning. |
| AC-08 | For T2+ tasks, absent smoke+real-backing integration the gate BLOCKs. T1 tasks are floor-exempt. Serviceless projects pass via the real-world definition. |
| AC-09 | In dedicated_test_db mode `down -v` never runs (dev DB volume intact); writeful tests against a prod DSN abort. |
| AC-10 | worktree sessions run zero screen tests directly, produce checklists only, and screen tests run serially by main after merge. |
| AC-11 | User requirements 1–9 all traceably covered by REQ IDs (§5.10), zero gaps. |
| AC-12 | After de-domaining·renaming, 6-project regression confirms zero gate-strength weakening. |
| AC-13 | Common deliverables land under `${CLAUDE_PROJECT_DIR}/.private/sdp-artifacts/{YYYY-MM-DD}/{topic}/{doc-type}`. On a project lacking `.private`, first run auto-creates it + registers `.private/` in `.gitignore` (zero duplicate append even on a 2nd run). |
| AC-14 | With `output_locale: auto` and env locale≠en, a runtime deliverable is produced as an English canonical original **plus** a synced copy in the env locale (both kept in sync). `output_locale: <locale>` forces a single language; `en` = English only; env-detection failure falls back to English. Machine-parsed markers (`ALLOW:`/`BLOCK:`/`TEAM_REVIEW`/REQ IDs) stay ASCII regardless. Plugin-facing assets (SDP core, commands, README) remain English. |

---

### Document status
- v1.0-draft. Team-produced + cross-review corrections applied (Böckeler attribution fix, req#6 already-implemented fact, raw CLI unmet, batch engine fork, resume by explicit thread-id, `run_segment_tmux.sh` location, teardown risk, T1 exemption, serviceless gap, cadence-halt conflict, etc.). The 3 load-bearing corrections were source-grep verified.
- **English is canonical** for global-market publishing. A Korean sync copy was maintained privately for user verification and is not part of the public release.
- §14 decisions (16): **all settled** — 8 confirmed via interview (Rounds 1–2), 3 auto-applied (D-08·12·15), 3 resolved earlier (D-01·04·16), D-14 = recommended safe default (allowlist-first, user away).
- Next step: promote to **v1.0** → author the **Stage 4 design doc** (full config schemas, gate port + raw fresh tier, de-domaining file map, manifests, command `.md` skeletons) at the REQ-D-05 detail ceiling → begin implementation.
