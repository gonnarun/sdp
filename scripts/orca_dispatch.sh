#!/usr/bin/env bash
# =============================================================================
# SDP Orca Dispatch Adapter — vendored, de-domained.
# Backs worktree-dispatch's `orca` mode (dispatch.worktree_mode: orca): hands
# one task to an Orca-supervised worker in an Orca-managed worktree via the
# `orca` CLI's orchestration RPCs. Sibling of run_segment_tmux.sh (the `auto`
# adapter) — same position in the dispatch path, different mechanism, own
# fallback contract. What is unexercised about this mode: docs/KNOWN_GAPS.md
# NC-26. (The design doc this implements is a local artifact, not in the repo;
# the section refs below — §3.1/3.1a/3.1b — name its parts for the record.)
#
# This is the ONLY thing that may call `orca orchestration task-create` /
# `worker-start` for this mode. Its exit 5 IS the fail-closed mechanism that
# lets `dispatch.worktree_mode: orca` be accepted at all (§3.1).
#
# Usage:  orca_dispatch.sh <BATCH_DIR> <SEGMENT_DIR> <MODE> [TIMEOUT_SECONDS]
#   MODE = probe | init | status | stop ; TIMEOUT default from
#          dispatch.default_timeout (14400).
# probe : capability probe only (§3.1) — orca on PATH, runtime ready, a
#         verified (appVersion, schemaVersion) pair, exactly one repo match on
#         the anchored workspace root. Never mutates.
# init  : run-create -> task-create -> worker-start, fixed order (§6). Writes
#         SEGMENT_DIR/.orca_dispatch.json and RETURNS — it does not wait.
#         Refuses if that state file already exists (never re-dispatches).
# status: worker-show against the recorded dispatch id, reporting only whether
#         the WORKER settled. STATUS.md at the created worktree's root remains
#         the SDP verdict (§3.3) — this mode never reads or judges its content.
# stop  : explicit operator action only — never deadline-triggered (§3.1b).
#         Identity-binds via worker-show (dispatch.id, dispatch.task_id, both
#         halves of worker.worktree_id) before calling worker-stop; any
#         mismatch or absent field refuses with NO mutation.
#
# Exit codes: 0 success · 1 usage · 2 BATCH_DIR missing · 3 required input
#   missing (SEGMENT_DIR / SEGMENT_DIR/INPUT.md, init only) · 4 bad MODE ·
#   5 Orca unusable — CATCH-ALL. Anything about Orca the adapter cannot
#     positively verify is 5: PATH, unreachable runtime, an unparseable or
#     field-short response, an unverified (appVersion, schemaVersion) pair,
#     zero or >1 repo match, a missing/corrupt/unversioned state file, or a
#     stop whose identity binding does not match. Not limited to the initial
#     probe (§3.1's "strict probe — recognise success, not failure") ·
#   6 task created but worker-start failed (partial creation: an orphaned
#     task_id is recorded with dispatch_id null, never auto-retried) — also
#     covers init finding an existing state file (never re-dispatch) ·
#   7 worker died (state proves failed/stopped) ·
#   124 past the configured deadline, still alive — NOTHING is stopped; Orca's
#       own guide forbids killing a worker for exceeding wall-clock (§3.1b) ·
#   125 worker settled successfully but wrote no STATUS.md ·
#   126 worker settled but its outcome cannot be classified (outcome_unknown)
#       — surfaced for the operator to choose worker-stop/worker-abandon,
#       never auto-resolved here.
#
# Never kills a worker for a deadline. Never calls `orchestration reset` (it
# is runtime-wide and would delete other sessions' tasks/messages). Never
# auto-retries a failed worker-start.
#
# Env: SDP_ORCA_DRYRUN=1 validates args/config, resolves the dispatch plan
#      (spec text, agent, timeout, state-file path) and prints it WITHOUT
#      calling `orca` at all — not even the PATH probe — so the arg/state-file
#      logic is exercisable with no Orca installed (mirrors SDP_TMUX_DRYRUN;
#      returns 0 on a valid dry run, or the real error exit code otherwise).
#      The probe/response-parsing logic itself is exercised by pointing
#      SDP_ORCA_BIN at a fixture-playing stub, the same technique
#      tests/review_gate.sh uses for reviewer binaries.
#      Also: SDP_ORCA_BIN (orca executable, default "orca"), SDP_ORCA_AGENT
#      (default "claude"), SDP_ORCA_MODEL, SDP_ORCA_EFFORT (requires
#      SDP_ORCA_MODEL), SDP_ORCA_BASE_BRANCH (default: omitted -> repo
#      default base), SDP_CORE_FILE, SDP_RULES_INCLUDE, CLAUDE_PROJECT_DIR.
# =============================================================================
set -euo pipefail

# ---- usage / args ----
usage() { echo "usage: orca_dispatch.sh <BATCH_DIR> <SEGMENT_DIR> <MODE=probe|init|status|stop> [TIMEOUT_SECONDS]" >&2; }
[ "$#" -ge 3 ] || { usage; exit 1; }
BATCH_DIR="$1"; SEGMENT_DIR="$2"; MODE="$3"; TIMEOUT_ARG="${4:-}"
DRYRUN="${SDP_ORCA_DRYRUN:-}"

# ---- dir / tool guards (run before config so they are reachable even under a
#      stripped PATH, and keep exit-code precedence 2 before 5 — same as the
#      tmux adapter). python3 is the adapter's own hard dependency (JSON
#      parsing, no jq): missing it means THIS adapter cannot function, which
#      is the same "fall back to manual" bucket as Orca being unusable. ----
[ -d "$BATCH_DIR" ] || { echo "ERROR: BATCH_DIR not found: $BATCH_DIR" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not installed (adapter cannot parse Orca JSON — fall back to manual)" >&2; exit 5; }

# ---- anchor/config resolution ----
_src="${BASH_SOURCE[0]:-$0}"
SDP_SCRIPTS="$(cd "$(dirname "$_src")" && pwd)"
SDP_ROOT="$(cd "$SDP_SCRIPTS/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$SDP_SCRIPTS/lib/sdp-config.sh" ] && . "$SDP_SCRIPTS/lib/sdp-config.sh"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DEFAULTS=""
for _c in "$PROJECT_DIR/.sdp/defaults.yaml" "$PROJECT_DIR/scripts/sdp/defaults.yaml"; do
  [ -f "$_c" ] && { DEFAULTS="$_c"; break; }
done
cfg() { { [ -n "$DEFAULTS" ] && command -v sdp_cfg_get >/dev/null 2>&1 && sdp_cfg_get "$DEFAULTS" "$1"; } || printf ''; }

CORE_FILE="${SDP_CORE_FILE:-$SDP_ROOT/core/SDP.md}"
RULES_INCLUDE="${SDP_RULES_INCLUDE:-$(cfg dispatch.rules_include)}"
DEF_TIMEOUT="$(cfg dispatch.default_timeout)"; : "${DEF_TIMEOUT:=14400}"
TIMEOUT_SECONDS="${TIMEOUT_ARG:-$DEF_TIMEOUT}"
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) TIMEOUT_SECONDS="$DEF_TIMEOUT" ;; esac
case "$DEF_TIMEOUT" in ''|*[!0-9]*) DEF_TIMEOUT=14400; TIMEOUT_SECONDS=14400 ;; esac

ORCA_BIN="${SDP_ORCA_BIN:-orca}"
ORCA_AGENT="${SDP_ORCA_AGENT:-claude}"
ORCA_MODEL="${SDP_ORCA_MODEL:-}"
ORCA_EFFORT="${SDP_ORCA_EFFORT:-}"
ORCA_BASE_BRANCH="${SDP_ORCA_BASE_BRANCH:-}"

STATE_FILE="${SEGMENT_DIR}/.orca_dispatch.json"

# ---- verified compatibility allow-list (§3.1: "a verified allow-list, not a
# floor"). Exactly the (appVersion, schemaVersion) pair step 0 exercised end
# to end. Widening this is a deliberate act requiring fresh fixtures, not
# something that happens by Orca upgrading. ----
_version_allowed() { [ "$1" = "1.4.176" ] && [ "$2" = "1" ]; }

# =============================================================================
# JSON helpers (python3, no jq). Each one embodies the strict-probe rule:
# recognise success, do not recognise failure — an absent field, a type
# mismatch, or unparseable JSON is a nonzero return and NOTHING on stdout, so
# every caller's `x="$(...)" || fail` falls straight to its exit-5 path.
# =============================================================================

# _get JSON DOTTED_PATH -> the scalar/array/object at DOTTED_PATH (dot-
# separated keys only — no array indexing; callers needing an array search
# use one of the dedicated helpers below). Missing key or null -> exit 1.
# Unparseable JSON -> exit 2.
_get() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(2)
cur = d
parts = sys.argv[2].split(".") if sys.argv[2] else []
for part in parts:
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(1)
    cur = cur[part]
if cur is None:
    sys.exit(1)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
' "$1" "$2"
}

# _match_repo JSON WORKSPACE_ROOT_CANON -> "<repoId>\t<repoPath>" for the SOLE
# repo whose realpath equals WORKSPACE_ROOT_CANON. Zero or >1 matches -> exit
# 1 (ambiguous or absent — never "pick the first", per §3.1's strict table).
_match_repo() {
  python3 -c '
import json, sys, os
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(2)
try:
    repos = d["result"]["repos"]
except Exception:
    sys.exit(1)
if not isinstance(repos, list):
    sys.exit(1)
target = sys.argv[2]
hits = []
for r in repos:
    if not isinstance(r, dict):
        continue
    p = r.get("path")
    rid = r.get("id")
    if not isinstance(p, str) or not isinstance(rid, str):
        continue
    try:
        rp = os.path.realpath(p)
    except Exception:
        continue
    if rp == target:
        hits.append((rid, rp))
if len(hits) != 1:
    sys.exit(1)
print(hits[0][0] + "\t" + hits[0][1])
' "$1" "$2"
}

# _worktree_from_effects JSON -> "<repoId>\t<absPath>" from the SOLE
# effects[] entry whose kind == "worktree", split on "::" (§3.1a). Zero or
# >1 such entries, or a malformed id -> exit 1.
_worktree_from_effects() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(2)
try:
    effects = d["result"]["effects"]
except Exception:
    sys.exit(1)
if not isinstance(effects, list):
    sys.exit(1)
hits = [e for e in effects if isinstance(e, dict) and e.get("kind") == "worktree"]
if len(hits) != 1:
    sys.exit(1)
wid = hits[0].get("id")
if not isinstance(wid, str) or "::" not in wid:
    sys.exit(1)
repo_id, path = wid.split("::", 1)
if not repo_id or not path:
    sys.exit(1)
print(repo_id + "\t" + path)
' "$1"
}

# _write_state TASK_ID DISPATCH_ID WORKTREE_PATH WORKTREE_ID START_EPOCH
#              DEADLINE_EPOCH ORCA_CLI
# Atomic write: temp file in the same dir, then mv (§3.1b — a reader never
# sees a half-written record). DISPATCH_ID/WORKTREE_PATH/WORKTREE_ID may be
# empty strings for the exit-6 partial-creation record (dispatch_id: null).
# worktree_id (full "<repoId>::<path>") and deadline_epoch are additive
# fields beyond the design's example schema, kept for identity binding and
# a cheap deadline comparison respectively — both derivable from, never in
# conflict with, the documented fields.
_write_state() {
  local task_id="$1" dispatch_id="$2" worktree_path="$3" worktree_id="$4" start_epoch="$5" deadline_epoch="$6" orca_cli="$7"
  local tmp="${STATE_FILE}.tmp"
  python3 -c '
import json, sys, datetime
task_id, dispatch_id, worktree_path, worktree_id, start_epoch, deadline_epoch, orca_cli, out = sys.argv[1:9]
def rfc3339(e):
    return datetime.datetime.fromtimestamp(int(e), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rec = {
    "v": 1,
    "task_id": task_id,
    "dispatch_id": dispatch_id or None,
    "worktree_path": worktree_path or None,
    "worktree_id": worktree_id or None,
    "started_at": rfc3339(start_epoch),
    "deadline_at": rfc3339(deadline_epoch),
    "deadline_epoch": int(deadline_epoch),
    "orca_cli": orca_cli,
    "schema_version": 1,
}
with open(out, "w") as fh:
    json.dump(rec, fh)
    fh.write("\n")
' "$task_id" "$dispatch_id" "$worktree_path" "$worktree_id" "$start_epoch" "$deadline_epoch" "$orca_cli" "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# _call ORCA_ARGS... -> sets $REPLY to raw stdout (possibly empty on
# failure), returns the CLI's own exit code. Always used in place of a bare
# `$("$ORCA_BIN" ...)` so a nonzero exit never discards the JSON error body —
# dispatch_not_found etc. exit 1 but still carry a parseable
# {"ok":false,"error":...} envelope (worker-show-invalid.json,
# worker-stop-invalid.json).
REPLY=""
_call() {
  set +e
  REPLY="$("$ORCA_BIN" "$@" 2>/dev/null)"
  local _rc=$?
  set -e
  return "$_rc"
}

# _compose_spec RULES_CLAUSE -> the orchestration task spec. Reuses
# SEGMENT_DIR/INPUT.md as-is for the segment scope — "no new handover format"
# (design §3.2) — wrapped in the SAME anchor + "run the SDP core unattended"
# preamble run_segment_tmux.sh's _preamble() uses. Unlike the tmux adapter,
# the worker's cwd IS the fresh worktree Orca creates, so anchoring and
# STATUS.md both target the literal shell expression "$(pwd)" / "current
# worktree root" for the WORKER to resolve at its own runtime, rather than a
# path this adapter could thread in ahead of time.
_compose_spec() {
  # shellcheck disable=SC2016  # $(pwd) is deliberately literal text for the WORKER's own shell to evaluate, not this script
  printf 'First anchor this session: run  CLAUDE_PROJECT_DIR="$(pwd)" bash "%s/sdp-anchor.sh" . ' "$SDP_SCRIPTS"
  printf 'Then read %s and run the full SDP workflow (Stages 1-8 + the two Claude gates) UNATTENDED; pause and report on INFRA_ERROR. ' "$CORE_FILE"
  printf 'Read %s FIRST as the segment scope; skip the Stage 1 interview and start at Stage 2. ' "${SEGMENT_DIR}/INPUT.md"
  printf 'Confine ALL outputs to the current worktree root. On completion write STATUS.md in the current worktree root as exactly one of: SUCCESS | FAIL_12X | HALT_BLOCK | PAUSE_USER_INPUT_REQUIRED. Ask the user NO questions.%s' "$1"
}

# =============================================================================
# do_probe: the strict, positive-recognition capability probe (§3.1). On
# stdout, "<repoId>\t<appVersion>"; return 0. On ANY other outcome — missing
# tool, unreachable runtime, unparseable JSON, an absent field, an unverified
# version pair, zero or >1 repo match — one PROBE: line on stderr, return 1.
# Never mutates. No task-create/worker-start may run until this has passed
# (§3.1a — an ordering safety property, not an optimisation).
# =============================================================================
do_probe() {
  command -v "$ORCA_BIN" >/dev/null 2>&1 || { echo "PROBE: $ORCA_BIN not on PATH" >&2; return 1; }

  local status_json
  if _call status --json; then status_json="$REPLY"; else echo "PROBE: orca status --json failed" >&2; return 1; fi
  [ -n "$status_json" ] || { echo "PROBE: orca status --json produced no output" >&2; return 1; }

  local reachable state app_version
  reachable="$(_get "$status_json" "result.runtime.reachable")" || { echo "PROBE: result.runtime.reachable missing" >&2; return 1; }
  [ "$reachable" = "true" ] || { echo "PROBE: runtime not reachable" >&2; return 1; }
  state="$(_get "$status_json" "result.runtime.state")" || { echo "PROBE: result.runtime.state missing" >&2; return 1; }
  [ "$state" = "ready" ] || { echo "PROBE: runtime.state=$state (want ready)" >&2; return 1; }
  app_version="$(_get "$status_json" "result.runtime.appVersion")" || { echo "PROBE: result.runtime.appVersion missing" >&2; return 1; }

  local ctx_json schema_version
  if _call agent-context --json; then ctx_json="$REPLY"; else echo "PROBE: orca agent-context --json failed" >&2; return 1; fi
  [ -n "$ctx_json" ] || { echo "PROBE: orca agent-context --json produced no output" >&2; return 1; }
  schema_version="$(_get "$ctx_json" "schemaVersion")" || { echo "PROBE: schemaVersion missing from agent-context" >&2; return 1; }

  _version_allowed "$app_version" "$schema_version" || { echo "PROBE: unverified (appVersion=$app_version, schemaVersion=$schema_version) — widen the allow-list only with fresh fixtures" >&2; return 1; }

  local ws_canon
  ws_canon="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || { echo "PROBE: PROJECT_DIR not resolvable: $PROJECT_DIR" >&2; return 1; }

  local repo_json match repo_id
  if _call repo list --json; then repo_json="$REPLY"; else echo "PROBE: orca repo list --json failed" >&2; return 1; fi
  [ -n "$repo_json" ] || { echo "PROBE: orca repo list --json produced no output" >&2; return 1; }
  match="$(_match_repo "$repo_json" "$ws_canon")" || { echo "PROBE: zero or multiple repos match $ws_canon" >&2; return 1; }
  repo_id="${match%%$'\t'*}"

  printf '%s\t%s\n' "$repo_id" "$app_version"
}

# =============================================================================
# do_init: run-create -> task-create -> worker-start, fixed order. Writes
# STATE_FILE and returns; never waits (§3.1b — status/stop are separate
# invocations that re-find the identifiers via STATE_FILE).
# =============================================================================
do_init() {
  [ -d "$SEGMENT_DIR" ] || { echo "ERROR: SEGMENT_DIR not found: $SEGMENT_DIR" >&2; exit 3; }
  [ -f "${SEGMENT_DIR}/INPUT.md" ] || { echo "ERROR: ${SEGMENT_DIR}/INPUT.md required for init" >&2; exit 3; }
  [ -e "$STATE_FILE" ] && { echo "ERROR: dispatch already recorded ($STATE_FILE) — use status/stop, never re-init a segment" >&2; exit 6; }

  local rules_clause=""
  [ -n "$RULES_INCLUDE" ] && rules_clause=" Obey the project rules in: ${RULES_INCLUDE}."
  local task_title spec
  task_title="$(basename "$SEGMENT_DIR")"
  spec="$(_compose_spec "$rules_clause")"

  if [ -n "$DRYRUN" ]; then
    echo "DRYRUN ok"
    echo "  mode          : init"
    echo "  batch_dir     : $BATCH_DIR"
    echo "  segment_dir   : $SEGMENT_DIR"
    echo "  agent         : $ORCA_AGENT"
    echo "  model/effort  : ${ORCA_MODEL:-<default>}/${ORCA_EFFORT:-<default>}"
    echo "  task_title    : $task_title"
    echo "  timeout       : ${TIMEOUT_SECONDS}s"
    echo "  base_branch   : ${ORCA_BASE_BRANCH:-<repo default>}"
    echo "  state_file    : $STATE_FILE"
    echo "  spec_bytes    : $(printf '%s' "$spec" | wc -c | tr -d ' ')"
    echo "  note          : capability probe + all orca calls skipped under DRYRUN"
    exit 0
  fi

  local probe_out repo_id app_version
  probe_out="$(do_probe)" || { echo "ERROR: Orca capability probe failed — fall back to manual" >&2; exit 5; }
  repo_id="${probe_out%%$'\t'*}"; app_version="${probe_out#*$'\t'}"

  local start_epoch deadline_epoch
  start_epoch="$(date +%s)"; deadline_epoch=$((start_epoch + TIMEOUT_SECONDS))

  local run_json run_id
  if _call orchestration run-create --objective "SDP worktree-dispatch: $(basename "$BATCH_DIR")/$task_title" --json; then
    run_json="$REPLY"
  else
    echo "ERROR: orchestration run-create failed" >&2; exit 5
  fi
  run_id="$(_get "$run_json" "result.run.id")" || { echo "ERROR: result.run.id missing from run-create" >&2; exit 5; }

  local task_json task_ok task_id
  _call orchestration task-create --spec "$spec" --task-title "$task_title" --run "$run_id" --json || true
  task_json="$REPLY"
  task_ok="$(_get "$task_json" "ok")" || task_ok=false
  if [ "$task_ok" != "true" ]; then
    echo "ERROR: orchestration task-create failed: $(_get "$task_json" "error.code" || echo '<unparseable>')" >&2
    exit 5
  fi
  task_id="$(_get "$task_json" "result.task.id")" || { echo "ERROR: result.task.id missing from task-create" >&2; exit 5; }

  local start_args
  start_args=(orchestration worker-start --task "$task_id" --worktree new-child --agent "$ORCA_AGENT"
              --repo "id:$repo_id" --setup inherit --timeout-ms "$((TIMEOUT_SECONDS * 1000))" --json)
  [ -n "$ORCA_BASE_BRANCH" ] && start_args+=(--base-branch "$ORCA_BASE_BRANCH")
  [ -n "$ORCA_MODEL" ] && start_args+=(--model "$ORCA_MODEL")
  [ -n "$ORCA_MODEL" ] && [ -n "$ORCA_EFFORT" ] && start_args+=(--effort "$ORCA_EFFORT")

  local start_json
  _call "${start_args[@]}" || true
  start_json="$REPLY"

  local start_state
  start_state="$(_get "$start_json" "result.state")" || start_state=""
  if [ "$start_state" != "ready" ]; then
    _write_state "$task_id" "" "" "" "$start_epoch" "$deadline_epoch" "$app_version"
    echo "ERROR: worker-start did not reach ready (state=${start_state:-<none>})" >&2
    echo "  stage            : $(_get "$start_json" "result.stage" || echo '<unavailable>')" >&2
    echo "  effects          : $(_get "$start_json" "result.effects" || echo '<unavailable>')" >&2
    echo "  residualResources: $(_get "$start_json" "result.residualResources" || echo '<unavailable>')" >&2
    echo "  orphaned task_id : $task_id (recorded in $STATE_FILE — never auto-retried)" >&2
    exit 6
  fi

  local dispatch_id worktree_pair eff_repo_id worktree_path worktree_id
  dispatch_id="$(_get "$start_json" "result.dispatchId")" || { echo "ERROR: result.dispatchId missing from worker-start" >&2; exit 5; }
  worktree_pair="$(_worktree_from_effects "$start_json")" || { echo "ERROR: no unique worktree effect in worker-start response" >&2; exit 5; }
  eff_repo_id="${worktree_pair%%$'\t'*}"; worktree_path="${worktree_pair#*$'\t'}"
  worktree_id="${eff_repo_id}::${worktree_path}"

  _write_state "$task_id" "$dispatch_id" "$worktree_path" "$worktree_id" "$start_epoch" "$deadline_epoch" "$app_version"
  echo "dispatched: task=$task_id dispatch=$dispatch_id worktree=$worktree_path"
}

# =============================================================================
# do_status: worker-show against the recorded dispatch id. Reports only
# whether the WORKER settled — STATUS.md remains the SDP verdict (§3.3).
# =============================================================================
do_status() {
  [ -e "$STATE_FILE" ] || { echo "ERROR: no dispatch recorded for $SEGMENT_DIR ($STATE_FILE missing) — never guess/re-dispatch" >&2; exit 5; }

  local state_json v task_id dispatch_id worktree_path deadline_epoch
  state_json="$(cat "$STATE_FILE" 2>/dev/null)" || { echo "ERROR: cannot read $STATE_FILE" >&2; exit 5; }
  v="$(_get "$state_json" "v")" || { echo "ERROR: $STATE_FILE unreadable (no v)" >&2; exit 5; }
  [ "$v" = "1" ] || { echo "ERROR: $STATE_FILE has unrecognized schema v=$v" >&2; exit 5; }
  task_id="$(_get "$state_json" "task_id")" || { echo "ERROR: $STATE_FILE missing task_id" >&2; exit 5; }
  dispatch_id="$(_get "$state_json" "dispatch_id")" || { echo "ERROR: $STATE_FILE has no dispatch_id (orphaned partial dispatch, task_id=$task_id) — resolve manually, never guess" >&2; exit 5; }
  worktree_path="$(_get "$state_json" "worktree_path")" || { echo "ERROR: $STATE_FILE missing worktree_path" >&2; exit 5; }
  deadline_epoch="$(_get "$state_json" "deadline_epoch")" || { echo "ERROR: $STATE_FILE missing deadline_epoch" >&2; exit 5; }

  if [ -n "$DRYRUN" ]; then
    echo "DRYRUN ok"
    echo "  mode          : status"
    echo "  dispatch_id   : $dispatch_id"
    echo "  worktree_path : $worktree_path"
    echo "  note          : worker-show skipped under DRYRUN"
    exit 0
  fi

  local show_json
  if _call orchestration worker-show --dispatch "$dispatch_id" --json; then show_json="$REPLY"; else echo "ERROR: orchestration worker-show failed" >&2; exit 5; fi
  [ -n "$show_json" ] || { echo "ERROR: orchestration worker-show produced no output" >&2; exit 5; }

  local ok
  ok="$(_get "$show_json" "ok")" || ok=false
  if [ "$ok" != "true" ]; then
    echo "ERROR: worker-show: $(_get "$show_json" "error.code" || echo '<unrecognized>')" >&2
    exit 5
  fi

  local wstate wstage
  wstate="$(_get "$show_json" "result.worker.state")" || { echo "ERROR: result.worker.state missing" >&2; exit 5; }
  wstage="$(_get "$show_json" "result.worker.stage")" || { echo "ERROR: result.worker.stage missing" >&2; exit 5; }

  if [ "$wstage" = "settled" ]; then
    case "$wstate" in
      succeeded)
        if [ -s "${worktree_path}/STATUS.md" ]; then
          echo "settled: STATUS.md present at ${worktree_path}/STATUS.md"
          exit 0
        else
          echo "ERROR: worker settled (succeeded) but no STATUS.md at ${worktree_path}" >&2
          exit 125
        fi ;;
      failed|stopped)
        echo "ERROR: worker settled state=$wstate" >&2
        exit 7 ;;
      *)
        echo "ERROR: worker settled with unrecognized state=$wstate — outcome_unknown; operator must choose worker-stop/worker-abandon" >&2
        exit 126 ;;
    esac
  fi

  # Not settled: still running. Deadline is a REPORTING boundary, never a
  # kill trigger (§3.1b) — the adapter stops polling at 124 but never touches
  # the worker.
  local now
  now="$(date +%s)"
  if [ "$now" -ge "$deadline_epoch" ]; then
    echo "over budget (deadline_epoch=$deadline_epoch now=$now) — worker still alive, NOT stopped" >&2
    exit 124
  fi
  echo "running: stage=$wstage state=$wstate"
}

# =============================================================================
# do_stop: explicit operator action only. Identity-binds via worker-show
# before ever calling worker-stop; any mismatch refuses with no mutation.
# =============================================================================
do_stop() {
  [ -e "$STATE_FILE" ] || { echo "ERROR: no dispatch recorded for $SEGMENT_DIR ($STATE_FILE missing) — never guess/re-dispatch" >&2; exit 5; }

  local state_json v task_id dispatch_id worktree_id
  state_json="$(cat "$STATE_FILE" 2>/dev/null)" || { echo "ERROR: cannot read $STATE_FILE" >&2; exit 5; }
  v="$(_get "$state_json" "v")" || { echo "ERROR: $STATE_FILE unreadable (no v)" >&2; exit 5; }
  [ "$v" = "1" ] || { echo "ERROR: $STATE_FILE has unrecognized schema v=$v" >&2; exit 5; }
  dispatch_id="$(_get "$state_json" "dispatch_id")" || { echo "ERROR: $STATE_FILE has no dispatch_id — nothing to stop" >&2; exit 5; }
  task_id="$(_get "$state_json" "task_id")" || { echo "ERROR: $STATE_FILE missing task_id" >&2; exit 5; }
  worktree_id="$(_get "$state_json" "worktree_id")" || { echo "ERROR: $STATE_FILE missing worktree_id" >&2; exit 5; }

  if [ -n "$DRYRUN" ]; then
    echo "DRYRUN ok"
    echo "  mode        : stop"
    echo "  dispatch_id : $dispatch_id"
    echo "  note        : identity-bind + worker-stop skipped under DRYRUN"
    exit 0
  fi

  # Identity binding (§3.1b) — required before ANY mutation.
  local show_json
  if _call orchestration worker-show --dispatch "$dispatch_id" --json; then show_json="$REPLY"; else echo "ERROR: worker-show failed — refusing to stop (identity unverified)" >&2; exit 5; fi

  local ok
  ok="$(_get "$show_json" "ok")" || ok=false
  [ "$ok" = "true" ] || { echo "ERROR: worker-show: $(_get "$show_json" "error.code" || echo '<unrecognized>') — refusing to stop" >&2; exit 5; }

  local d_id d_task w_wtid
  d_id="$(_get "$show_json" "result.dispatch.id")" || { echo "ERROR: result.dispatch.id missing — refusing to stop" >&2; exit 5; }
  d_task="$(_get "$show_json" "result.dispatch.task_id")" || { echo "ERROR: result.dispatch.task_id missing — refusing to stop" >&2; exit 5; }
  w_wtid="$(_get "$show_json" "result.worker.worktree_id")" || { echo "ERROR: result.worker.worktree_id missing — refusing to stop" >&2; exit 5; }

  if [ "$d_id" != "$dispatch_id" ] || [ "$d_task" != "$task_id" ] || [ "$w_wtid" != "$worktree_id" ]; then
    echo "ERROR: identity mismatch — recorded(dispatch=$dispatch_id task=$task_id worktree_id=$worktree_id) vs observed(dispatch=$d_id task=$d_task worktree_id=$w_wtid); refusing to stop, no mutation attempted" >&2
    exit 5
  fi

  local stop_json
  if _call orchestration worker-stop --dispatch "$dispatch_id" --json; then stop_json="$REPLY"; else echo "ERROR: worker-stop failed" >&2; exit 5; fi

  local stop_ok
  stop_ok="$(_get "$stop_json" "ok")" || stop_ok=false
  [ "$stop_ok" = "true" ] || { echo "ERROR: worker-stop: $(_get "$stop_json" "error.code" || echo '<unrecognized>')" >&2; exit 5; }

  local stop_state stop_settled
  stop_state="$(_get "$stop_json" "result.state" || echo '<unknown>')"
  stop_settled="$(_get "$stop_json" "result.alreadySettled" || echo '<unknown>')"
  echo "stopped: dispatch=$dispatch_id state=$stop_state alreadySettled=$stop_settled"
}

# ---- MODE dispatch ----
case "$MODE" in
  probe)
    if [ -n "$DRYRUN" ]; then
      echo "DRYRUN ok"
      echo "  mode: probe (no live orca calls under DRYRUN)"
      exit 0
    fi
    probe_out=""
    if probe_out="$(do_probe)"; then
      echo "probe ok: repo_id=${probe_out%%$'\t'*} app_version=${probe_out#*$'\t'}"
      exit 0
    else
      exit 5
    fi
    ;;
  init)   do_init ;;
  status) do_status ;;
  stop)   do_stop ;;
  *) echo "ERROR: unknown MODE '$MODE' (probe|init|status|stop)" >&2; exit 4 ;;
esac
