#!/usr/bin/env bash
# =============================================================================
# SDP Orca Dispatch Adapter. Written by this project's maintainer; no
# third-party code. De-domained for release.
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
# status: worker-show against the recorded dispatch id, then the SDP verdict
#         from the CONTENT of STATUS.md at the created worktree's root (§3.3).
#         On any settled outcome it also writes SEGMENT_DIR/RESULT.json — the
#         verdict plus result_sha/base_sha/branch/ancestry/dirty — because the
#         worktree is disposable and `orca worktree rm` would otherwise take
#         the only record of the outcome with it.
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
#   9/10/11/12 the SDP verdict read from STATUS.md's CONTENT — 9 unrecognized,
#     10 FAIL_12X, 11 HALT_BLOCK, 12 PAUSE_USER_INPUT_REQUIRED. Same codes and
#     same meanings as run_segment_tmux.sh, deliberately, so a caller can treat
#     the two adapters alike. N3 (REQ-034): gate on CONTENT, never on presence —
#     Orca reports `state: succeeded` for a worker whose SDP verdict is
#     FAIL_12X, because it is answering "did the process end cleanly", not "did
#     the workflow pass" (§3.3). Measured 2026-08-09 on a live 5-worker run ·
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
#      Also: SDP_ORCA_BIN (orca executable, default "orca"),
#      SDP_ORCA_BASE_BRANCH (ref to branch FROM, default
#      HEAD; resolved to an immutable SHA before dispatch and recorded as
#      base_sha), SDP_CORE_FILE, SDP_RULES_INCLUDE, CLAUDE_PROJECT_DIR.
#
# Identity: the segment directory's basename becomes the Orca worktree --name,
# which Orca turns into both the worktree directory and the branch
# "<repo.gitUsername>/<name>". That is how N parallel dispatches stay
# distinguishable, so the name is validated and never silently rewritten, and
# init refuses when the branch it would produce already exists.
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
DEFAULTS="$(sdp_cfg_discover "$PROJECT_DIR" defaults.yaml)"
cfg() { { [ -n "$DEFAULTS" ] && command -v sdp_cfg_get >/dev/null 2>&1 && sdp_cfg_get "$DEFAULTS" "$1"; } || printf ''; }

CORE_FILE="${SDP_CORE_FILE:-$SDP_ROOT/core/SDP.md}"
RULES_INCLUDE="${SDP_RULES_INCLUDE:-$(cfg dispatch.rules_include)}"
DEF_TIMEOUT="$(cfg dispatch.default_timeout)"; : "${DEF_TIMEOUT:=14400}"
TIMEOUT_SECONDS="${TIMEOUT_ARG:-$DEF_TIMEOUT}"
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) TIMEOUT_SECONDS="$DEF_TIMEOUT" ;; esac
case "$DEF_TIMEOUT" in ''|*[!0-9]*) DEF_TIMEOUT=14400; TIMEOUT_SECONDS=14400 ;; esac

ORCA_BIN="${SDP_ORCA_BIN:-orca}"
ORCA_AGENT="codex"
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

# _match_repo JSON WORKSPACE_ROOT_CANON -> "<repoId>\t<repoPath>\t<gitUsername>"
# for the SOLE repo whose realpath equals WORKSPACE_ROOT_CANON. Zero or >1
# matches -> exit 1 (ambiguous or absent — never "pick the first", per §3.1's
# strict table).
# gitUsername is carried because Orca derives a new worktree's branch as
# "<gitUsername>/<--name>" (measured on two repos and confirmed by prediction
# on six live dispatches). It is what lets the adapter know the branch BEFORE
# the worker exists, instead of discovering it afterwards. Absent or empty is
# NOT fatal: the branch is then confirmed from worker-show rather than
# predicted, so an Orca that stops emitting the field degrades to observation
# instead of refusing to dispatch.
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
        gu = r.get("gitUsername")
        hits.append((rid, rp, gu if isinstance(gu, str) else ""))
if len(hits) != 1:
    sys.exit(1)
print("\t".join(hits[0]))
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
  local task_id="$1" dispatch_id="$2" worktree_path="$3" worktree_id="$4" start_epoch="$5" deadline_epoch="$6" orca_cli="$7" base_sha="${8:-}" branch="${9:-}"
  local tmp="${STATE_FILE}.tmp"
  python3 -c '
import json, sys, datetime
task_id, dispatch_id, worktree_path, worktree_id, start_epoch, deadline_epoch, orca_cli, base_sha, branch, out = sys.argv[1:11]
def rfc3339(e):
    return datetime.datetime.fromtimestamp(int(e), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rec = {
    "v": 1,
    "agent": "codex",
    "task_id": task_id,
    "dispatch_id": dispatch_id or None,
    "worktree_path": worktree_path or None,
    "worktree_id": worktree_id or None,
    "base_sha": base_sha or None,
    "branch": branch or None,
    "started_at": rfc3339(start_epoch),
    "deadline_at": rfc3339(deadline_epoch),
    "deadline_epoch": int(deadline_epoch),
    "orca_cli": orca_cli,
    "schema_version": 2,
}
with open(out, "w") as fh:
    json.dump(rec, fh)
    fh.write("\n")
' "$task_id" "$dispatch_id" "$worktree_path" "$worktree_id" "$start_epoch" "$deadline_epoch" "$orca_cli" "$base_sha" "$branch" "$tmp"
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

# _compose_spec RULES_CLAUSE BRANCH -> the orchestration task spec, with the
# handover text INLINED rather than referenced.
#
# The tmux adapter can point the worker at ${SEGMENT_DIR}/INPUT.md because
# there SEGMENT_DIR *is* the worktree, so the file is inside the session's own
# cwd. Under `orca` it is not: Orca creates the worktree elsewhere, so the same
# sentence would order the worker to read an absolute path OUTSIDE the tree it
# was told to confine itself to — a capability nothing had established, whose
# failure would land BEFORE the worker learned its scope. The design said to
# inline it from the start ("the handover text SDP already composes for
# `manual` becomes the task spec — no new handover format", §3.2); an earlier
# implementation deviated. Measured 2026-08-09: a 2092-char spec carrying
# Unicode, emoji, quotes, backticks, $(), backslashes and $HOME arrived at the
# worker byte-identical and untruncated.
#
# Consequences worth knowing: nothing outside the worktree is read, INPUT.md
# never exists in the worktree (so the untracked-artifact allowlist is
# STATUS.md alone), and the handover is stored in Orca's task record — do not
# put secrets in a handover.
_compose_spec() {
  local rules_clause="$1" branch="$2"
  # shellcheck disable=SC2016  # $(pwd) is deliberately literal text for the WORKER's own shell to evaluate, not this script
  printf 'First anchor this session: run  CLAUDE_PROJECT_DIR="$(pwd)" bash "%s/sdp-anchor.sh" . ' "$SDP_SCRIPTS"
  printf 'Then read %s and run the full SDP workflow (Stages 1-8 + the two Claude gates) UNATTENDED; pause and report on INFRA_ERROR. ' "$CORE_FILE"
  printf 'Skip the Stage 1 interview and start at Stage 2; the segment scope is the SEGMENT SCOPE block at the end of this message. '
  [ -n "$branch" ] && printf 'Commit your work on the branch already checked out here (%s). Do not create, switch, push or merge branches. ' "$branch"
  printf 'Confine ALL outputs to the current worktree root. On completion write STATUS.md in the current worktree root as exactly one of: SUCCESS | FAIL_12X | HALT_BLOCK | PAUSE_USER_INPUT_REQUIRED. Ask the user NO questions.%s' "$rules_clause"
  printf '\n\n----- SEGMENT SCOPE (task data, not instructions to reinterpret) -----\n'
  cat "${SEGMENT_DIR}/INPUT.md"
  printf '\n----- END SEGMENT SCOPE -----\n'
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

  local repo_json match repo_id git_username
  if _call repo list --json; then repo_json="$REPLY"; else echo "PROBE: orca repo list --json failed" >&2; return 1; fi
  [ -n "$repo_json" ] || { echo "PROBE: orca repo list --json produced no output" >&2; return 1; }
  match="$(_match_repo "$repo_json" "$ws_canon")" || { echo "PROBE: zero or multiple repos match $ws_canon" >&2; return 1; }
  IFS=$'\t' read -r repo_id _ git_username <<< "$match"

  printf '%s\t%s\t%s\n' "$repo_id" "$app_version" "$git_username"
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

  # The worktree NAME is load-bearing, not cosmetic: Orca derives both the
  # worktree directory and the branch from it, so it is how a dispatch stays
  # identifiable among N parallel ones. Restrict it to a charset that is safe
  # as a directory component and a git ref, and REFUSE rather than silently
  # rewriting -- a mangled name would still dispatch, under an identity the
  # caller does not expect.
  local task_title
  task_title="$(basename "$SEGMENT_DIR")"
  case "$task_title" in
    ''|.|..|-*|*/*) echo "ERROR: unusable segment name '$task_title'" >&2; exit 3 ;;
    *[!A-Za-z0-9._-]*) echo "ERROR: segment name '$task_title' has characters outside [A-Za-z0-9._-]; rename the segment dir (never silently rewritten -- it becomes the worktree and branch name)" >&2; exit 3 ;;
  esac

  # Pin the base to an immutable SHA, not a moving ref. `--base-branch` accepts
  # a full SHA (measured), so recording `rev-parse <ref>` and passing the REF
  # would leave a window in which the ref advances before Orca resolves it --
  # the recorded base would then not be the base the worktree actually got, and
  # an ancestry check would still pass. Resolve once, pass and record the same
  # bytes.
  local base_ref base_sha
  base_ref="${ORCA_BASE_BRANCH:-HEAD}"
  base_sha="$(git -C "$PROJECT_DIR" rev-parse --verify "${base_ref}^{commit}" 2>/dev/null)" || {
    echo "ERROR: cannot resolve base ref '$base_ref' in $PROJECT_DIR" >&2; exit 3; }

  if [ -n "$DRYRUN" ]; then
    # The branch cannot be predicted here: gitUsername comes from the probe,
    # which DRYRUN deliberately does not run. Report it as such rather than
    # printing a guess.
    local dry_spec
    dry_spec="$(_compose_spec "$rules_clause" "")"
    echo "DRYRUN ok"
    echo "  mode          : init"
    echo "  batch_dir     : $BATCH_DIR"
    echo "  segment_dir   : $SEGMENT_DIR"
    echo "  agent         : $ORCA_AGENT"
    echo "  worktree_name : $task_title"
    echo "  timeout       : ${TIMEOUT_SECONDS}s"
    echo "  base_ref      : $base_ref"
    echo "  base_sha      : $base_sha"
    echo "  expected_branch: <unknown under DRYRUN — needs gitUsername from the probe>"
    echo "  state_file    : $STATE_FILE"
    echo "  spec_bytes    : $(printf '%s' "$dry_spec" | wc -c | tr -d ' ')"
    echo "  note          : capability probe + all orca calls skipped under DRYRUN"
    exit 0
  fi

  local probe_out repo_id app_version git_username
  probe_out="$(do_probe)" || { echo "ERROR: Orca capability probe failed — fall back to manual" >&2; exit 5; }
  IFS=$'\t' read -r repo_id app_version git_username <<< "$probe_out"

  # Predict the branch, and refuse if that identity is already taken. Teardown
  # deliberately preserves a branch that carries work (measured), so re-running
  # a segment of the same name after a completed dispatch WOULD collide -- and
  # a collision is exactly the state in which "which worktree is this task's"
  # stops having one answer. Refuse; never adopt an existing branch.
  local expected_branch=""
  if [ -n "$git_username" ]; then
    expected_branch="${git_username}/${task_title}"
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/${expected_branch}"; then
      echo "ERROR: branch ${expected_branch} already exists — a previous dispatch of '${task_title}' left it behind (worktree removal preserves branches that carry commits). Integrate or delete it, or rename the segment. Refusing to dispatch into an ambiguous identity." >&2
      exit 6
    fi
  fi

  local spec
  spec="$(_compose_spec "$rules_clause" "$expected_branch")"

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

  # --name is not cosmetic: it is what makes the worktree path and the branch
  # predictable, and therefore what makes N parallel dispatches distinguishable.
  # --base-branch carries the pinned SHA, never the ref it came from.
  # --setup run rather than inherit: `inherit` can resolve to skip, and a worker
  # that starts before its repo's setup ran fails in a way that looks like a
  # task failure.
  local start_args
  start_args=(orchestration worker-start --task "$task_id" --worktree new-child --agent "$ORCA_AGENT"
              --name "$task_title" --repo "id:$repo_id" --base-branch "$base_sha"
              --setup run --timeout-ms "$((TIMEOUT_SECONDS * 1000))" --json)

  local start_json
  _call "${start_args[@]}" || true
  start_json="$REPLY"

  local start_state
  start_state="$(_get "$start_json" "result.state")" || start_state=""
  if [ "$start_state" != "ready" ]; then
    _write_state "$task_id" "" "" "" "$start_epoch" "$deadline_epoch" "$app_version" "$base_sha" ""
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

  # CONFIRM the branch, do not trust the prediction. worker-start carries no
  # branch field at all; worker-show does (result.terminal.branch). Recording an
  # unconfirmed guess would make the state file assert something never observed.
  # A prediction that disagrees with the observation is reported, not smoothed
  # over -- it would mean the naming rule this adapter relies on has changed.
  local branch=""
  if _call orchestration worker-show --dispatch "$dispatch_id" --json; then
    branch="$(_get "$REPLY" "result.terminal.branch" || echo "")"
    branch="${branch#refs/heads/}"
  fi
  if [ -n "$expected_branch" ] && [ -n "$branch" ] && [ "$branch" != "$expected_branch" ]; then
    echo "WARNING: branch is '$branch' but '<gitUsername>/<name>' predicted '$expected_branch' — recording the observed value; the derivation rule may have changed" >&2
  fi

  _write_state "$task_id" "$dispatch_id" "$worktree_path" "$worktree_id" "$start_epoch" "$deadline_epoch" "$app_version" "$base_sha" "$branch"
  echo "dispatched: task=$task_id dispatch=$dispatch_id worktree=$worktree_path branch=${branch:-<unconfirmed>} base=$base_sha"
}

# _report_result VERDICT WORKTREE_PATH BASE_SHA BRANCH TASK_ID DISPATCH_ID
# Prints what an integrator needs and cannot get from a verdict word -- the
# exact commit to merge, whether it descends from the base this dispatch
# pinned, the branch actually checked out, anything left dirty -- and PERSISTS
# the same facts to ${SEGMENT_DIR}/RESULT.json.
#
# Persisting matters because the verdict lives in the worktree, and the
# worktree is disposable: `orca worktree rm` deletes it, taking STATUS.md with
# it, so after ordinary cleanup nothing would record whether the segment
# passed. SEGMENT_DIR sits under the main repo's artifact root and survives.
# (The same class of loss was hit in production elsewhere when a completion
# record's real location drifted from its documented one.)
#
# INFORMATIONAL ONLY: neither the printing nor the persisting may change the
# exit code. The verdict answers "did the workflow pass"; this answers "what
# exactly would I be merging", and letting a failed *write* mark a task failed
# is the same confusion that produced the defect this file's header records.
# A write failure is therefore loud on stderr and nothing more.
#
# Integrate result_sha, never a branch name: a branch can move between this
# call and the merge.
_report_result() {
  local verdict="$1" wt="$2" base="$3" branch="$4" task_id="$5" dispatch_id="$6"
  local head="" cur="" dirty="" ancestry="unknown"

  if git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo '')"
    cur="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo '')"
    dirty="$(git -C "$wt" status --porcelain=v1 --untracked-files=all 2>/dev/null | tr '\n' ';')"
    if [ -n "$base" ] && [ -n "$head" ]; then
      if [ "$head" = "$base" ]; then ancestry="no_new_commit"
      elif git -C "$wt" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then ancestry="ok"
      else ancestry="not_descended"; fi
    fi
    echo "  result_sha : ${head:-<unknown>}"
    echo "  branch     : ${cur:-<detached>}${branch:+ (recorded: $branch)}"
    [ -n "$branch" ] && [ -n "$cur" ] && [ "$cur" != "$branch" ] && echo "  WARNING    : checked-out branch differs from the one recorded at dispatch"
    case "$ancestry" in
      no_new_commit) echo "  ancestry   : NO NEW COMMIT — HEAD is still the pinned base $base" ;;
      ok)            echo "  ancestry   : ok — descends from pinned base $base" ;;
      not_descended) echo "  ancestry   : WARNING — does NOT descend from the pinned base $base" ;;
    esac
    echo "  dirty      : ${dirty:-<clean>}"
  else
    echo "  result     : <$wt is not a git worktree — worktree already removed?>"
  fi

  # `mv -f file dir` moves the file INTO dir and reports success, so an
  # existing non-regular RESULT.json would leave the record unwritten while
  # this function claimed to have written it. Refuse up front instead.
  local out="${SEGMENT_DIR}/RESULT.json" tmp="${SEGMENT_DIR}/RESULT.json.tmp"
  if [ -e "$out" ] && [ ! -f "$out" ]; then
    echo "WARNING: $out exists and is not a regular file — refusing to write it; the verdict is reported but NOT durably recorded" >&2
    return 0
  fi
  if python3 -c '
import json, sys, datetime
verdict, wt, base, branch_rec, branch_obs, head, ancestry, dirty, task_id, dispatch_id, out = sys.argv[1:12]
rec = {
    "v": 1,
    "verdict": verdict,
    "task_id": task_id or None,
    "dispatch_id": dispatch_id or None,
    "worktree_path": wt or None,
    "base_sha": base or None,
    "result_sha": head or None,
    "branch_recorded": branch_rec or None,
    "branch_observed": branch_obs or None,
    "ancestry": ancestry,
    "dirty": [x for x in dirty.split(";") if x],
    "observed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(out, "w") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
' "$verdict" "$wt" "$base" "$branch" "$cur" "$head" "$ancestry" "$dirty" "$task_id" "$dispatch_id" "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null; then
    echo "  recorded   : $out"
  else
    rm -f "$tmp" 2>/dev/null || true
    echo "WARNING: could not write $out — the verdict is reported but NOT durably recorded; it will be lost when the worktree is removed" >&2
  fi
}

# =============================================================================
# do_status: worker-show against the recorded dispatch id. The WORKER's state
# answers only whether the process ended; STATUS.md's CONTENT is the SDP
# verdict (§3.3, N3/REQ-034).
# =============================================================================
do_status() {
  [ -e "$STATE_FILE" ] || { echo "ERROR: no dispatch recorded for $SEGMENT_DIR ($STATE_FILE missing) — never guess/re-dispatch" >&2; exit 5; }

  local state_json v task_id dispatch_id worktree_path deadline_epoch base_sha branch
  state_json="$(cat "$STATE_FILE" 2>/dev/null)" || { echo "ERROR: cannot read $STATE_FILE" >&2; exit 5; }
  v="$(_get "$state_json" "v")" || { echo "ERROR: $STATE_FILE unreadable (no v)" >&2; exit 5; }
  [ "$v" = "1" ] || { echo "ERROR: $STATE_FILE has unrecognized schema v=$v" >&2; exit 5; }
  task_id="$(_get "$state_json" "task_id")" || { echo "ERROR: $STATE_FILE missing task_id" >&2; exit 5; }
  dispatch_id="$(_get "$state_json" "dispatch_id")" || { echo "ERROR: $STATE_FILE has no dispatch_id (orphaned partial dispatch, task_id=$task_id) — resolve manually, never guess" >&2; exit 5; }
  worktree_path="$(_get "$state_json" "worktree_path")" || { echo "ERROR: $STATE_FILE missing worktree_path" >&2; exit 5; }
  deadline_epoch="$(_get "$state_json" "deadline_epoch")" || { echo "ERROR: $STATE_FILE missing deadline_epoch" >&2; exit 5; }
  # base_sha/branch are additive: a record written by an older adapter has
  # neither, and the ancestry check below simply does not run rather than the
  # whole call failing.
  base_sha="$(_get "$state_json" "base_sha" || echo "")"
  branch="$(_get "$state_json" "branch" || echo "")"

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
        # `succeeded` answers "did the PROCESS end cleanly", not "did the SDP
        # workflow pass" (§3.3). Measured 2026-08-09: a worker whose STATUS.md
        # said FAIL_12X still reported succeeded/settled/completed. Reading
        # presence alone therefore turns every failed segment into a success.
        # N3 (REQ-034) — gate on CONTENT, exactly as run_segment_tmux.sh does,
        # with the same exit codes so a caller can treat both adapters alike.
        [ -s "${worktree_path}/STATUS.md" ] || {
          echo "ERROR: worker settled (succeeded) but no STATUS.md at ${worktree_path}" >&2
          _report_result "NO_STATUS_MD" "$worktree_path" "$base_sha" "$branch" "$task_id" "$dispatch_id"
          exit 125; }
        [ -f "${worktree_path}/STATUS.md" ] || {
          echo "ERROR: ${worktree_path}/STATUS.md is not a regular file" >&2
          _report_result "STATUS_NOT_REGULAR_FILE" "$worktree_path" "$base_sha" "$branch" "$task_id" "$dispatch_id"
          exit 9; }
        local verdict
        verdict="$(head -n1 "${worktree_path}/STATUS.md" 2>/dev/null | tr -d '[:space:]')"
        case "$verdict" in
          SUCCESS|FAIL_12X|HALT_BLOCK|PAUSE_USER_INPUT_REQUIRED) : ;;
          *) verdict="UNRECOGNIZED:${verdict}" ;;
        esac
        _report_result "$verdict" "$worktree_path" "$base_sha" "$branch" "$task_id" "$dispatch_id"
        case "$verdict" in
          SUCCESS)                   echo "settled: SUCCESS"; exit 0 ;;
          FAIL_12X)                  echo "settled: FAIL_12X" >&2;  exit 10 ;;
          HALT_BLOCK)                echo "settled: HALT_BLOCK" >&2; exit 11 ;;
          PAUSE_USER_INPUT_REQUIRED) echo "settled: PAUSE_USER_INPUT_REQUIRED" >&2; exit 12 ;;
          *) echo "ERROR: STATUS.md content unrecognized: '${verdict#UNRECOGNIZED:}'" >&2; exit 9 ;;
        esac ;;
      failed|stopped)
        echo "ERROR: worker settled state=$wstate" >&2
        _report_result "WORKER_${wstate}" "$worktree_path" "$base_sha" "$branch" "$task_id" "$dispatch_id"
        exit 7 ;;
      *)
        echo "ERROR: worker settled with unrecognized state=$wstate — outcome_unknown; operator must choose worker-stop/worker-abandon" >&2
        _report_result "OUTCOME_UNKNOWN" "$worktree_path" "$base_sha" "$branch" "$task_id" "$dispatch_id"
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
      IFS=$'\t' read -r _p_repo _p_ver _p_user <<< "$probe_out"
      echo "probe ok: repo_id=$_p_repo app_version=$_p_ver git_username=${_p_user:-<absent>}"
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
