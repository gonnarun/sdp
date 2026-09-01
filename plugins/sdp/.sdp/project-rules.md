# Project-specific rules

> De-domain sink for `core/SDP.md`. Stack/DB/build/server/migration conventions that are **not** universal live here, per project. The core references this file by pointer only.
>
> **Gate inclusion (exact contract, per `scripts/review_gate.py`)**: the gate includes this file in the review prompt only when `gates.yaml: review_checklist_include: .sdp/project-rules.md` is set — and then the file must exist non-empty or the gate fail-closes (BLOCK). Setting `require_checklist: true` **without** an include is itself a BLOCK. `require_checklist: true` alone does NOT auto-include this file.
>
> The **"## Review checklist (normative)"** section below is the authoritative source for the project-specific dimensions that Stage 4 / Stage 7 reviews cite; the "Template" examples further down are illustrative only and are NOT active rules.
>
> Machine tokens (`ALLOW:`/`BLOCK:`/`REQ-*`/config keys) stay ASCII. Keep this developer-readable — no bloat.

## Review checklist (normative)
For this repo (a bash/markdown plugin) the project-specific review dimensions are intentionally minimal:
- No secrets or credentials hardcoded in scripts; no sensitive data echoed to logs or the gate log.
- Shell changes pass `shellcheck` and keep `set -u` safety; no unquoted expansion of config/env into a command line.
- Tests (`tests/smoke.sh`, `tests/gate_integration.sh`, `tests/review_gate.sh`) updated when gate behavior changes.
- Every change batch audits all four `HOST_DIVERGENT` pairs in `scripts/build_plugin_tree.py` (`commands/sdp.md`, `commands/batch-sdp.md`, `commands/worktree-dispatch.md`, `scripts/run_segment_tmux.sh`) across root and `plugins/sdp/`; generator intentionally skips their content, so `--check` presence is not semantic parity.
- No new DB/server/migration surface (this repo has none — see below).

Downstream projects replace this section with their own normative dimensions (audit/permission/crypto/migration rules, repeated-mistake list). Stage 4 / Stage 7 cite THIS section, not the illustrative Template.

## This repo (SDP dogfoods itself)

SDP is a bash + markdown plugin, so most "build" is shell linting and its own tests.

- **Build/lint**: `${build.lint}` = `shellcheck scripts/*.sh scripts/lib/*.sh`. No compile/install/typecheck step.
- **Tests**: `${test.commands.smoke}` = `bash tests/smoke.sh`; `${test.commands.integration}` = `bash tests/gate_integration.sh`. Mandatory layers: smoke, integration, bump, packaging.
- **No DB / no server / no migrations** — `migrate.prod_block` stays `true` as a safety default; there is nothing to migrate.
- **Work log**: none required for this repo beyond the Stage 5 handover doc under `docs/`.

## Template — what a downstream project puts here

Copy the shape below and fill with the project's real conventions. Values that the core resolves as `${...}` belong in `.sdp/defaults.yaml` (`build.*`, `test.*`, `migrate.*`); prose conventions belong here.

### Server run
> Example (JVM/Node backend): start/restart the server **only** via the project's script — never ad-hoc `nohup java -jar … > /tmp/x.log`.
> ```
> cd backend && ./start.sh     # start
> cd backend && ./stop.sh      # stop
> cd backend && ./restart.sh   # restart
> ```
> Logs: `tail -f backend/logs/backend-*.log` (latest).

### DB table conventions
> Example (multi-tenant SQL): every business table has `tenant_id VARCHAR(16) NOT NULL`; no `AUTO_INCREMENT` PK — use CHAR(36) UUID or app-generated IDs.

### Migration naming
> Example (Flyway): `V{YYYYMMDDHHmmss}__{desc}.sql`, created only via `scripts/new-migration.sh {desc}`; include seconds (date-only forbidden).

### Work-log path
> Example: `.references/worklog/{YYYYMM}/{DD}/{YYYYMMDD}_worklog.md` — one entry per completed unit (category / what / changed files / notes).

### Telegram / notification policy
> Example: approval-request notifications are replaced by the review-gate; send only when the user explicitly enables a notification mode; never include secrets/PII in messages.

## forced_ext (domain safety extensions)

`.sdp/defaults.yaml: forced_ext` may carry a base safety key only as a **truthy claim** — the loader refuses every other spelling — but that validator is the only code recognising those keys and no enforcement consumer acts on their values, so it guards the claim, not behaviour (KNOWN_GAPS NC-31). Record domain-mandated hard rules here as the declared policy (e.g. a required test marker, a prod-DSN guard); the enforcement itself has to live in the project's own tests or gates. This repo's `forced_ext` is empty.
