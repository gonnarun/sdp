#!/usr/bin/env bash
# orca_dispatch.sh — tests for plugins/sdp/scripts/orca_dispatch.sh (the `orca`
# worktree-dispatch adapter, §3.1a/§3.1b of
# .private/sdp-artifacts/2026-08-09/orca-worktree-mode/design_orca_worktree_mode.md).
# Style matched to its siblings: tests/run_segment.sh (DRYRUN-driven dry run of
# the other adapter) and tests/review_gate.sh (fake-binary-as-stub technique) —
# same ok()/bad() helpers, PASS/FAIL counters, "-------- N passed, M failed --------"
# summary line.
#
# NEVER makes a live `orca` call. Two seams from the adapter's own header do
# the work:
#   SDP_ORCA_DRYRUN=1   — validates args/config, resolves the plan, prints it,
#                         and calls `orca` not at all (not even the PATH probe).
#   SDP_ORCA_BIN=<stub> — a fake `orca`, generated below, that plays back
#                         canned/fixture JSON per subcommand and logs every
#                         invocation, so the probe + response-parsing paths are
#                         exercised with no real Orca installed.
#
# Fixtures: tests/fixtures/orca/ (see its README) — captured live from Orca app
# 1.4.176 / agent-context schemaVersion 1 on 2026-08-09. This suite reads only
# from that tracked directory, never from the gitignored .private/ capture.
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
ADAPTER="$PLUGIN_ROOT/scripts/orca_dispatch.sh"   # canonical tree only (ADR-005)
FIXDIR="$SDP_ROOT/tests/fixtures/orca"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d -t sdp_orca_dispatch.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$SDP_ROOT"   # resolve .sdp/defaults.yaml by default
BATCH="$TMP/batch"; mkdir -p "$BATCH"
NOORCA="$TMP/definitely/nonexistent/orca"   # `command -v` fails regardless of real PATH

# ==============================================================================
# Fake `orca`. Every invocation is logged (one line = full argv) to
# $CTRL/calls.log so tests can assert what was called -- and, more importantly,
# what was NOT (no worker-stop on a deadline, no orchestration reset, ever).
# Per-subcommand response body/exit-code are staged with set_resp() before each
# call and read back from $CTRL/<key>.{body,rc}.
# ==============================================================================
STUBDIR="$TMP/bin"; mkdir -p "$STUBDIR"
CTRL="$TMP/ctrl"; mkdir -p "$CTRL"
: > "$CTRL/calls.log"

cat > "$STUBDIR/orca" <<STUB
#!/usr/bin/env bash
CTRL="$CTRL"
printf '%s\n' "\$*" >> "\$CTRL/calls.log"
key="unknown"
case "\${1:-} \${2:-}" in
  "status --json")              key=status ;;
  "agent-context --json")       key=agent_context ;;
  "repo list")                  key=repo_list ;;
  "orchestration run-create")   key=run_create ;;
  "orchestration task-create")  key=task_create ;;
  "orchestration worker-start") key=worker_start ;;
  "orchestration worker-show")  key=worker_show ;;
  "orchestration worker-stop")  key=worker_stop ;;
  "orchestration reset")        key=orchestration_reset ;;
esac
[ -f "\$CTRL/\$key.body" ] && cat "\$CTRL/\$key.body"
rc=0
[ -f "\$CTRL/\$key.rc" ] && rc="\$(cat "\$CTRL/\$key.rc")"
exit "\$rc"
STUB
chmod +x "$STUBDIR/orca"
STUB_BIN="$STUBDIR/orca"

set_resp()   { printf '%s' "$2" > "$CTRL/$1.body"; printf '%s' "${3:-0}" > "$CTRL/$1.rc"; }
reset_resp() { rm -f "$CTRL"/*.body "$CTRL"/*.rc 2>/dev/null; true; }
log_lines()  { wc -l < "$CTRL/calls.log" | tr -d ' '; }
log_since()  { tail -n "+$(($1 + 1))" "$CTRL/calls.log"; }
sha()        { python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }
canon()      { ( cd "$1" 2>/dev/null && pwd -P ); }

# ---- JSON builders (field names confirmed against the real fixtures in
# tests/fixtures/orca/ -- never invented) --------------------------------------
status_json() { # reachable(true|false|MISSING) state(str|MISSING) appver(str|MISSING)
  python3 -c '
import json, sys
reachable, state, appver = sys.argv[1:4]
runtime = {}
if reachable != "MISSING": runtime["reachable"] = (reachable == "true")
if state != "MISSING": runtime["state"] = state
if appver != "MISSING": runtime["appVersion"] = appver
print(json.dumps({"id": "x", "ok": True, "result": {"runtime": runtime}}))
' "$1" "$2" "$3"
}
schema_json() { # schemaVersion(str|MISSING)
  python3 -c '
import json, sys
sv = sys.argv[1]
d = {"commandCount": 223}
if sv != "MISSING":
    d["schemaVersion"] = int(sv) if sv.isdigit() else sv
print(json.dumps(d))
' "$1"
}
repo_list_json() { # matching_path count_matches
  python3 -c '
import json, sys
path, n = sys.argv[1], int(sys.argv[2])
repos = [{"id": f"repo-{i}", "path": path} for i in range(n)]
repos.append({"id": "repo-other", "path": "/nonexistent/unrelated/path"})
print(json.dumps({"ok": True, "result": {"repos": repos}}))
' "$1" "$2"
}
worker_show_state_json() { # state stage
  python3 -c '
import json, sys
state, stage = sys.argv[1:3]
print(json.dumps({"ok": True, "result": {"worker": {"state": state, "stage": stage}}}))
' "$1" "$2"
}
write_state() { # seg_dir task_id dispatch_id_or_empty worktree_path worktree_id deadline_epoch
  python3 -c '
import json, sys
seg, task_id, dispatch_id, wt_path, wt_id, deadline = sys.argv[1:7]
rec = {
    "v": 1, "task_id": task_id,
    "dispatch_id": dispatch_id or None,
    "worktree_path": wt_path or None,
    "worktree_id": wt_id or None,
    "started_at": "2026-08-09T00:00:00Z", "deadline_at": "2026-08-09T04:00:00Z",
    "deadline_epoch": int(deadline),
    "orca_cli": "1.4.176", "schema_version": 1,
}
with open(seg + "/.orca_dispatch.json", "w") as fh:
    json.dump(rec, fh); fh.write("\n")
' "$1" "$2" "$3" "$4" "$5" "$6"
}

# ==============================================================================
# 1. Arg / MODE validation
# ==============================================================================
echo "== arg/MODE validation =="
run() { SDP_ORCA_DRYRUN=1 bash "$ADAPTER" "$@" >/dev/null 2>&1; echo $?; }

[ "$(run)" = 1 ]                                    && ok "no args -> exit 1" || bad "usage exit 1 (no args)"
[ "$(run "$BATCH")" = 1 ]                            && ok "1 arg -> exit 1" || bad "usage exit 1 (1 arg)"
[ "$(run "$BATCH" "$TMP/seg")" = 1 ]                 && ok "2 args (no MODE) -> exit 1" || bad "usage exit 1 (2 args)"
[ "$(run "$BATCH" "$TMP/seg" bogus)" = 4 ]           && ok "unknown MODE -> exit 4" || bad "bad MODE exit 4"
[ "$(run "$TMP/nope-batch" "$TMP/seg" probe)" = 2 ]  && ok "BATCH_DIR missing -> exit 2" || bad "BATCH_DIR exit 2"
[ "$(run "$BATCH" "$TMP/nope-seg" init)" = 3 ]       && ok "init w/o SEGMENT_DIR -> exit 3" || bad "init no-segdir exit 3"
mkdir -p "$TMP/seg-noinput"
[ "$(run "$BATCH" "$TMP/seg-noinput" init)" = 3 ]    && ok "init w/o INPUT.md -> exit 3" || bad "init no-INPUT.md exit 3"

# ==============================================================================
# 2. DRYRUN plan printing, all 4 modes -- exit 0, no orca call (SDP_ORCA_BIN
#    points nowhere on purpose: if DRYRUN ever tried to invoke orca, this would
#    surface as a wrong exit code / garbled output instead of a clean plan).
# ==============================================================================
echo "== DRYRUN plan printing (all 4 modes) =="
SEG_INIT="$TMP/seg-dryrun-init"; mkdir -p "$SEG_INIT"; printf 'scope\n' > "$SEG_INIT/INPUT.md"
out="$(SDP_ORCA_DRYRUN=1 SDP_ORCA_BIN="$NOORCA" bash "$ADAPTER" "$BATCH" "$SEG_INIT" init 777 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "DRYRUN ok" \
    && printf '%s' "$out" | grep -qF "  timeout       : 777s" \
    && printf '%s' "$out" | grep -qF "  state_file    : ${SEG_INIT}/.orca_dispatch.json"; } \
  && ok "DRYRUN init -> 0, prints timeout + state_file plan lines" \
  || bad "DRYRUN init (rc=$rc): $out"

SEG_STATUS="$TMP/seg-dryrun-status"; mkdir -p "$SEG_STATUS"
write_state "$SEG_STATUS" "task_dr" "ctx_dr_123" "$TMP/wt-dryrun" "repoid::$TMP/wt-dryrun" "9999999999"
out="$(SDP_ORCA_DRYRUN=1 SDP_ORCA_BIN="$NOORCA" bash "$ADAPTER" "$BATCH" "$SEG_STATUS" status 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "DRYRUN ok" \
    && printf '%s' "$out" | grep -qF "  dispatch_id   : ctx_dr_123" \
    && printf '%s' "$out" | grep -qF "  worktree_path : $TMP/wt-dryrun"; } \
  && ok "DRYRUN status -> 0, prints dispatch_id + worktree_path plan lines" \
  || bad "DRYRUN status (rc=$rc): $out"

SEG_STOP="$TMP/seg-dryrun-stop"; mkdir -p "$SEG_STOP"
write_state "$SEG_STOP" "task_dr2" "ctx_dr_456" "$TMP/wt-dryrun2" "repoid::$TMP/wt-dryrun2" "9999999999"
out="$(SDP_ORCA_DRYRUN=1 SDP_ORCA_BIN="$NOORCA" bash "$ADAPTER" "$BATCH" "$SEG_STOP" stop 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "DRYRUN ok" \
    && printf '%s' "$out" | grep -qF "  dispatch_id : ctx_dr_456"; } \
  && ok "DRYRUN stop -> 0, prints dispatch_id plan line" \
  || bad "DRYRUN stop (rc=$rc): $out"

out="$(SDP_ORCA_DRYRUN=1 SDP_ORCA_BIN="$NOORCA" bash "$ADAPTER" "$BATCH" "$TMP/seg-dryrun-probe" probe 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "DRYRUN ok" \
    && printf '%s' "$out" | grep -qF "  mode: probe (no live orca calls under DRYRUN)"; } \
  && ok "DRYRUN probe -> 0, no-live-calls note" \
  || bad "DRYRUN probe (rc=$rc): $out"

# ==============================================================================
# 3. Strict probe: catch-all -> 5. "Recognise success, not failure" is the
#    load-bearing property, so each route is exercised and asserted separately.
# ==============================================================================
echo "== strict probe: catch-all -> 5 =="
PROJ="$TMP/proj"; mkdir -p "$PROJ"
WS="$(canon "$PROJ")"
SEG_PROBE="$TMP/seg-probe"   # probe mode never touches SEGMENT_DIR; need not exist

probe_rc() { CLAUDE_PROJECT_DIR="$PROJ" bash "$ADAPTER" "$BATCH" "$SEG_PROBE" probe >/dev/null 2>&1; echo $?; }

[ "$(SDP_ORCA_BIN="$NOORCA" probe_rc)" = 5 ] && ok "probe: orca absent from PATH -> 5" || bad "orca-absent -> 5"

set_probe_defaults() {
  set_resp status "$(cat "$FIXDIR/status.json")" 0            # real: reachable/ready/1.4.176
  set_resp agent_context "$(cat "$FIXDIR/schema-version.json")" 0  # real: schemaVersion 1
  set_resp repo_list "$(repo_list_json "$WS" 1)" 0             # synthetic: exactly one match
}
assert_probe5() { local rc; rc="$(SDP_ORCA_BIN="$STUB_BIN" probe_rc)"; [ "$rc" = 5 ] && ok "probe: $1 -> 5" || bad "probe: $1 (got rc=$rc, want 5)"; }

# positive sanity first (non-vacuity): proves the failures below are real,
# not an artifact of a broken stub.
set_probe_defaults
out="$(SDP_ORCA_BIN="$STUB_BIN" CLAUDE_PROJECT_DIR="$PROJ" bash "$ADAPTER" "$BATCH" "$SEG_PROBE" probe 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "probe ok: repo_id=repo-0 app_version=1.4.176"; } \
  && ok "probe: fully-correct responses -> 0 (sanity check for the catch-all tests below)" \
  || bad "probe positive sanity (rc=$rc): $out"

set_probe_defaults; set_resp status "junk-output" 1
assert_probe5 "orca status --json exits nonzero"

set_probe_defaults; set_resp status "" 0
assert_probe5 "orca status --json prints empty output"

set_probe_defaults; set_resp status "{not valid json" 0
assert_probe5 "orca status --json prints unparseable JSON"

set_probe_defaults; set_resp status "$(status_json MISSING ready 1.4.176)" 0
assert_probe5 "result.runtime.reachable missing entirely (not merely false)"

set_probe_defaults; set_resp status "$(status_json false ready 1.4.176)" 0
assert_probe5 "result.runtime.reachable present but false"

set_probe_defaults; set_resp status "$(status_json true starting 1.4.176)" 0
assert_probe5 "runtime.state present but not exactly ready"

set_probe_defaults; set_resp status "$(status_json true ready 1.4.177)" 0
assert_probe5 "newer appVersion 1.4.177 (schemaVersion still 1) is deliberately still rejected"

set_probe_defaults; set_resp agent_context "$(schema_json 2)" 0
assert_probe5 "correct appVersion but schemaVersion 2 (unverified pair)"

set_probe_defaults; set_resp agent_context "$(schema_json MISSING)" 0
assert_probe5 "agent-context schemaVersion missing"

set_probe_defaults; set_resp repo_list "$(repo_list_json "$WS" 0)" 0
assert_probe5 "repo list matches ZERO repos"

set_probe_defaults; set_resp repo_list "$(repo_list_json "$WS" 2)" 0
assert_probe5 "repo list matches MORE THAN ONE repo (never pick the first)"

set_probe_defaults; set_resp repo_list "not json{{{" 0
assert_probe5 "repo list unparseable JSON"

set_probe_defaults; set_resp repo_list "$(cat "$FIXDIR/repo-list.json")" 0
assert_probe5 "repo list: REAL captured fixture, none of its repos match a fresh temp dir"

# ==============================================================================
# 4. State-file rules (§3.1b)
# ==============================================================================
echo "== state-file rules (status/stop) =="

SEG_NOSTATE="$TMP/seg-nostate"; mkdir -p "$SEG_NOSTATE"
base=$(log_lines)
rc="$(SDP_ORCA_BIN="$STUB_BIN" bash "$ADAPTER" "$BATCH" "$SEG_NOSTATE" status >/dev/null 2>&1; echo $?)"
newcalls="$(log_since "$base")"
{ [ "$rc" = 5 ] && [ -z "$newcalls" ]; } && ok "status: no state file -> 5, no orca call (never re-dispatch)" || bad "status no-state (rc=$rc, calls='$newcalls')"

base=$(log_lines)
rc="$(SDP_ORCA_BIN="$STUB_BIN" bash "$ADAPTER" "$BATCH" "$SEG_NOSTATE" stop >/dev/null 2>&1; echo $?)"
newcalls="$(log_since "$base")"
{ [ "$rc" = 5 ] && [ -z "$newcalls" ]; } && ok "stop: no state file -> 5, no orca call (never re-dispatch)" || bad "stop no-state (rc=$rc, calls='$newcalls')"

SEG_VBAD="$TMP/seg-vbad"; mkdir -p "$SEG_VBAD"
printf '{"v":2,"task_id":"t","dispatch_id":"d","worktree_path":"/x","worktree_id":"r::/x","deadline_epoch":9999999999}' > "$SEG_VBAD/.orca_dispatch.json"
[ "$(bash "$ADAPTER" "$BATCH" "$SEG_VBAD" status >/dev/null 2>&1; echo $?)" = 5 ] && ok "status: state file v!=1 -> 5" || bad "status v-mismatch"
[ "$(bash "$ADAPTER" "$BATCH" "$SEG_VBAD" stop >/dev/null 2>&1; echo $?)" = 5 ]   && ok "stop: state file v!=1 -> 5"   || bad "stop v-mismatch"

SEG_CORRUPT="$TMP/seg-corrupt"; mkdir -p "$SEG_CORRUPT"
printf '{not json at all' > "$SEG_CORRUPT/.orca_dispatch.json"
before="$(sha "$SEG_CORRUPT/.orca_dispatch.json")"
rc="$(bash "$ADAPTER" "$BATCH" "$SEG_CORRUPT" status >/dev/null 2>&1; echo $?)"
after="$(sha "$SEG_CORRUPT/.orca_dispatch.json")"
{ [ "$rc" = 5 ] && [ "$before" = "$after" ]; } && ok "status: corrupt state file -> 5, file unchanged" || bad "status corrupt (rc=$rc, before=$before after=$after)"

before="$(sha "$SEG_CORRUPT/.orca_dispatch.json")"
rc="$(bash "$ADAPTER" "$BATCH" "$SEG_CORRUPT" stop >/dev/null 2>&1; echo $?)"
after="$(sha "$SEG_CORRUPT/.orca_dispatch.json")"
{ [ "$rc" = 5 ] && [ "$before" = "$after" ]; } && ok "stop: corrupt state file -> 5, file unchanged" || bad "stop corrupt (rc=$rc)"

SEG_ORPHAN="$TMP/seg-orphan"; mkdir -p "$SEG_ORPHAN"
write_state "$SEG_ORPHAN" "task_orphan_777" "" "" "" "9999999999"
err="$(bash "$ADAPTER" "$BATCH" "$SEG_ORPHAN" status 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" = 5 ] && printf '%s' "$err" | grep -qF "task_orphan_777"; } \
  && ok "status: orphaned record (dispatch_id null) -> 5, names task_orphan_777" \
  || bad "status orphan (rc=$rc): $err"
rc="$(bash "$ADAPTER" "$BATCH" "$SEG_ORPHAN" stop >/dev/null 2>&1; echo $?)"
[ "$rc" = 5 ] && ok "stop: orphaned record (dispatch_id null) -> 5, nothing to stop" || bad "stop orphan (rc=$rc)"

# ==============================================================================
# 5. init refuses re-dispatch when a state file already exists -> 6
# ==============================================================================
echo "== init: refuses when a state file already exists =="
SEG_EXIST="$TMP/seg-exists"; mkdir -p "$SEG_EXIST"; printf 'scope\n' > "$SEG_EXIST/INPUT.md"
printf 'PRE-EXISTING-MARKER' > "$SEG_EXIST/.orca_dispatch.json"
before="$(sha "$SEG_EXIST/.orca_dispatch.json")"
rc="$(bash "$ADAPTER" "$BATCH" "$SEG_EXIST" init >/dev/null 2>&1; echo $?)"
after="$(sha "$SEG_EXIST/.orca_dispatch.json")"
content="$(cat "$SEG_EXIST/.orca_dispatch.json")"
{ [ "$rc" = 6 ] && [ "$before" = "$after" ] && [ "$content" = "PRE-EXISTING-MARKER" ]; } \
  && ok "init: existing state file -> 6, file NOT overwritten" \
  || bad "init existing-state (rc=$rc, before=$before after=$after)"

# ==============================================================================
# 6. status outcomes (live, driven by stub worker-show responses)
# ==============================================================================
echo "== status outcomes (live, via stub worker-show) =="
SEG_ST="$TMP/seg-status-live"; mkdir -p "$SEG_ST"
WT="$TMP/wt-status"; mkdir -p "$WT"
status_run() { SDP_ORCA_BIN="$STUB_BIN" bash "$ADAPTER" "$BATCH" "$SEG_ST" status; }

write_state "$SEG_ST" "task_st" "ctx_st_1" "$WT" "repo1::$WT" "9999999999"
reset_resp; set_resp worker_show "$(cat "$FIXDIR/worker-show-settled.json")" 0
printf 'SUCCESS\n' > "$WT/STATUS.md"
out="$(status_run 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "STATUS.md present"; } \
  && ok "status: settled+succeeded + STATUS.md present -> 0" || bad "status succeeded+STATUS.md (rc=$rc): $out"

rm -f "$WT/STATUS.md"
rc="$(status_run >/dev/null 2>&1; echo $?)"
[ "$rc" = 125 ] && ok "status: settled+succeeded, no STATUS.md -> 125" || bad "status succeeded-no-STATUS.md (rc=$rc)"

set_resp worker_show "$(worker_show_state_json failed settled)" 0
rc="$(status_run >/dev/null 2>&1; echo $?)"
[ "$rc" = 7 ] && ok "status: settled+failed -> 7" || bad "status failed (rc=$rc)"

set_resp worker_show "$(worker_show_state_json stopped settled)" 0
rc="$(status_run >/dev/null 2>&1; echo $?)"
[ "$rc" = 7 ] && ok "status: settled+stopped -> 7" || bad "status stopped (rc=$rc)"

set_resp worker_show "$(worker_show_state_json outcome_unknown_xyz settled)" 0
rc="$(status_run >/dev/null 2>&1; echo $?)"
[ "$rc" = 126 ] && ok "status: settled+unrecognised state -> 126" || bad "status unrecognised (rc=$rc)"

write_state "$SEG_ST" "task_st" "ctx_st_1" "$WT" "repo1::$WT" "9999999999"
set_resp worker_show "$(worker_show_state_json running dispatched)" 0
out="$(status_run 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "running:"; } \
  && ok "status: not settled, before deadline -> 0, reports running" || bad "status running (rc=$rc): $out"

write_state "$SEG_ST" "task_st" "ctx_st_1" "$WT" "repo1::$WT" "1"   # epoch 1: long past
set_resp worker_show "$(worker_show_state_json running dispatched)" 0
base=$(log_lines)
rc="$(status_run >/dev/null 2>&1; echo $?)"
newcalls="$(log_since "$base")"
{ [ "$rc" = 124 ] && ! printf '%s' "$newcalls" | grep -q "worker-stop"; } \
  && ok "status: not settled, past deadline -> 124, worker NEVER stopped" \
  || bad "status deadline (rc=$rc, calls='$newcalls')"

write_state "$SEG_ST" "task_st" "ctx_st_1" "$WT" "repo1::$WT" "9999999999"
set_resp worker_show "$(cat "$FIXDIR/worker-show-invalid.json")" 0
rc="$(status_run >/dev/null 2>&1; echo $?)"
[ "$rc" = 5 ] && ok "status: worker-show reports dispatch_not_found (real fixture) -> 5" || bad "status dispatch_not_found (rc=$rc)"

# ==============================================================================
# 7. stop: identity binding via worker-show before ANY mutation (§3.1b)
# ==============================================================================
echo "== stop: identity binding =="
SEG_SP="$TMP/seg-stop-live"; mkdir -p "$SEG_SP"
# Full-match case is driven entirely by the REAL worker-show-settled.json
# fixture's own identity fields, not synthesized ids.
# Bound once and reused everywhere below (section 8 too) so a future redaction
# only has one place to touch instead of re-finding every copy.
REAL_DID="ctx_be002dcfc6c8"; REAL_TID="task_a96c3d9ffaad"
REAL_WT_PATH="/Users/dev/orca/workspaces/orca-probe-repo/sdp-orca-probe"
REAL_WTID="fafb5f5a-a0ab-4441-ab50-84c951abaed2::${REAL_WT_PATH}"
stop_run() { SDP_ORCA_BIN="$STUB_BIN" bash "$ADAPTER" "$BATCH" "$SEG_SP" stop; }

write_state "$SEG_SP" "$REAL_TID" "$REAL_DID" "$TMP/wt-stop" "$REAL_WTID" "9999999999"
reset_resp
set_resp worker_show "$(cat "$FIXDIR/worker-show-settled.json")" 0
set_resp worker_stop "$(cat "$FIXDIR/worker-stop-settled.json")" 0
base=$(log_lines)
out="$(stop_run 2>&1)"; rc=$?
newcalls="$(log_since "$base")"
{ [ "$rc" = 0 ] && printf '%s' "$newcalls" | grep -q "worker-stop" && printf '%s' "$out" | grep -qF "stopped: dispatch=$REAL_DID"; } \
  && ok "stop: full identity match (real fixture) -> worker-stop called, exit 0" \
  || bad "stop full match (rc=$rc, out=$out, calls='$newcalls')"

write_state "$SEG_SP" "$REAL_TID" "ctx_WRONG_DISPATCH" "$TMP/wt-stop" "$REAL_WTID" "9999999999"
base=$(log_lines)
rc="$(stop_run >/dev/null 2>&1; echo $?)"
newcalls="$(log_since "$base")"
{ [ "$rc" = 5 ] && ! printf '%s' "$newcalls" | grep -q "worker-stop"; } \
  && ok "stop: dispatch_id mismatch -> 5, no worker-stop call" || bad "stop dispatch mismatch (rc=$rc, calls='$newcalls')"

write_state "$SEG_SP" "task_WRONG" "$REAL_DID" "$TMP/wt-stop" "$REAL_WTID" "9999999999"
base=$(log_lines)
rc="$(stop_run >/dev/null 2>&1; echo $?)"
newcalls="$(log_since "$base")"
{ [ "$rc" = 5 ] && ! printf '%s' "$newcalls" | grep -q "worker-stop"; } \
  && ok "stop: task_id mismatch -> 5, no worker-stop call" || bad "stop task mismatch (rc=$rc, calls='$newcalls')"

write_state "$SEG_SP" "$REAL_TID" "$REAL_DID" "$TMP/wt-stop" "otherrepo::/some/other/path" "9999999999"
base=$(log_lines)
rc="$(stop_run >/dev/null 2>&1; echo $?)"
newcalls="$(log_since "$base")"
{ [ "$rc" = 5 ] && ! printf '%s' "$newcalls" | grep -q "worker-stop"; } \
  && ok "stop: worktree_id mismatch -> 5, no worker-stop call" || bad "stop worktree mismatch (rc=$rc, calls='$newcalls')"

write_state "$SEG_SP" "$REAL_TID" "$REAL_DID" "$TMP/wt-stop" "$REAL_WTID" "9999999999"
set_resp worker_show "$(cat "$FIXDIR/worker-show-invalid.json")" 0
base=$(log_lines)
rc="$(stop_run >/dev/null 2>&1; echo $?)"
newcalls="$(log_since "$base")"
{ [ "$rc" = 5 ] && ! printf '%s' "$newcalls" | grep -q "worker-stop"; } \
  && ok "stop: worker-show dispatch_not_found (real fixture) -> 5, no worker-stop call" \
  || bad "stop worker-show fails (rc=$rc, calls='$newcalls')"

# ==============================================================================
# 8. Bonus: full do_init dispatch chain, driven end-to-end by real fixtures
#    (beyond the checklist minimum -- not required, but exercises run-create /
#    task-create / worker-start / _write_state together with captured data).
# ==============================================================================
echo "== bonus: do_init full dispatch chain (real captured fixtures) =="
SEG_FULL="$TMP/seg-init-full"; mkdir -p "$SEG_FULL"; printf 'scope\n' > "$SEG_FULL/INPUT.md"
reset_resp
set_resp status "$(cat "$FIXDIR/status.json")" 0
set_resp agent_context "$(cat "$FIXDIR/schema-version.json")" 0
set_resp repo_list "$(repo_list_json "$WS" 1)" 0
set_resp run_create "$(cat "$FIXDIR/run-create.json")" 0
set_resp task_create "$(cat "$FIXDIR/task-create-ok.json")" 0
set_resp worker_start "$(cat "$FIXDIR/worker-start.json")" 0

out="$(SDP_ORCA_BIN="$STUB_BIN" CLAUDE_PROJECT_DIR="$PROJ" bash "$ADAPTER" "$BATCH" "$SEG_FULL" init 300 2>&1)"; rc=$?
statefile="$SEG_FULL/.orca_dispatch.json"
sf_ok=0
if [ -f "$statefile" ]; then
  sf_ok="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
task_id, dispatch_id, wt_path, wt_id = sys.argv[2:6]
print(1 if (d["v"] == 1 and d["task_id"] == task_id and d["dispatch_id"] == dispatch_id
            and d["worktree_path"] == wt_path
            and d["worktree_id"] == wt_id)
        else 0)
' "$statefile" "$REAL_TID" "$REAL_DID" "$REAL_WT_PATH" "$REAL_WTID")"
fi
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "dispatched: task=$REAL_TID dispatch=$REAL_DID" && [ "$sf_ok" = 1 ]; } \
  && ok "init: full chain (real status/schema/run-create/task-create/worker-start) -> 0, state file correct" \
  || bad "init full chain (rc=$rc, sf_ok=$sf_ok): $out"

SEG_TCFAIL="$TMP/seg-init-tcfail"; mkdir -p "$SEG_TCFAIL"; printf 'scope\n' > "$SEG_TCFAIL/INPUT.md"
set_resp task_create "$(cat "$FIXDIR/task-create.json")" 0   # real ok:false / run_required
rc="$(SDP_ORCA_BIN="$STUB_BIN" CLAUDE_PROJECT_DIR="$PROJ" bash "$ADAPTER" "$BATCH" "$SEG_TCFAIL" init 300 >/dev/null 2>&1; echo $?)"
{ [ "$rc" = 5 ] && [ ! -e "$SEG_TCFAIL/.orca_dispatch.json" ]; } \
  && ok "init: task-create fails (real ok:false fixture) -> 5, no state file written" \
  || bad "init task-create-fail (rc=$rc)"
set_resp task_create "$(cat "$FIXDIR/task-create-ok.json")" 0   # restore

SEG_PARTIAL="$TMP/seg-init-partial"; mkdir -p "$SEG_PARTIAL"; printf 'scope\n' > "$SEG_PARTIAL/INPUT.md"
set_resp worker_start '{"id":"x","ok":true,"result":{"state":"failed","stage":"input_rejected","effects":[],"residualResources":[]}}' 0
rc="$(SDP_ORCA_BIN="$STUB_BIN" CLAUDE_PROJECT_DIR="$PROJ" bash "$ADAPTER" "$BATCH" "$SEG_PARTIAL" init 300 >/dev/null 2>&1; echo $?)"
pf="$SEG_PARTIAL/.orca_dispatch.json"
pf_ok=0
if [ -f "$pf" ]; then
  pf_ok="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
task_id = sys.argv[2]
print(1 if (d["task_id"] == task_id and d["dispatch_id"] is None) else 0)
' "$pf" "$REAL_TID")"
fi
{ [ "$rc" = 6 ] && [ "$pf_ok" = 1 ]; } \
  && ok "init: worker-start fails -> 6, orphaned task_id recorded with dispatch_id null" \
  || bad "init worker-start-fail (rc=$rc, pf_ok=$pf_ok)"

# ==============================================================================
# 8b. Optional/bonus: SDP_ORCA_AGENT/MODEL/EFFORT/BASE_BRANCH reach the real
#     worker-start argv, read back from the stub's invocation log (same
#     technique tests/review_gate.sh uses for its H1/H3 argv assertions).
#     Specifically covers the untested conditional: the adapter passes
#     --effort only when --model was also passed (`[ -n "$ORCA_MODEL" ] &&
#     [ -n "$ORCA_EFFORT" ]`), so a model-less --effort must never leak.
# ==============================================================================
echo "== bonus: worker-start argv reflects SDP_ORCA_AGENT/MODEL/EFFORT/BASE_BRANCH =="
reset_resp
set_resp status "$(cat "$FIXDIR/status.json")" 0
set_resp agent_context "$(cat "$FIXDIR/schema-version.json")" 0
set_resp repo_list "$(repo_list_json "$WS" 1)" 0
set_resp run_create "$(cat "$FIXDIR/run-create.json")" 0
set_resp task_create "$(cat "$FIXDIR/task-create-ok.json")" 0
set_resp worker_start "$(cat "$FIXDIR/worker-start.json")" 0

SEG_ARGV="$TMP/seg-argv"; mkdir -p "$SEG_ARGV"; printf 'scope\n' > "$SEG_ARGV/INPUT.md"
base=$(log_lines)
SDP_ORCA_BIN="$STUB_BIN" CLAUDE_PROJECT_DIR="$PROJ" SDP_ORCA_AGENT="codex" \
  SDP_ORCA_MODEL="gpt-hypothetical" SDP_ORCA_EFFORT="high" SDP_ORCA_BASE_BRANCH="develop" \
  bash "$ADAPTER" "$BATCH" "$SEG_ARGV" init 300 >/dev/null 2>&1
argv_line="$(log_since "$base" | grep "orchestration worker-start" | head -1)"
{ printf '%s' "$argv_line" | grep -q -- "--agent codex" \
    && printf '%s' "$argv_line" | grep -q -- "--model gpt-hypothetical" \
    && printf '%s' "$argv_line" | grep -q -- "--effort high" \
    && printf '%s' "$argv_line" | grep -q -- "--base-branch develop"; } \
  && ok "worker-start argv: SDP_ORCA_AGENT/MODEL/EFFORT/BASE_BRANCH all reach the CLI" \
  || bad "worker-start argv missing expected flags: $argv_line"

SEG_ARGV2="$TMP/seg-argv2"; mkdir -p "$SEG_ARGV2"; printf 'scope\n' > "$SEG_ARGV2/INPUT.md"
base=$(log_lines)
SDP_ORCA_BIN="$STUB_BIN" CLAUDE_PROJECT_DIR="$PROJ" SDP_ORCA_EFFORT="high" \
  bash "$ADAPTER" "$BATCH" "$SEG_ARGV2" init 300 >/dev/null 2>&1   # SDP_ORCA_MODEL left unset
argv_line2="$(log_since "$base" | grep "orchestration worker-start" | head -1)"
{ printf '%s' "$argv_line2" | grep -q -- "--agent claude" \
    && ! printf '%s' "$argv_line2" | grep -q -- "--model" \
    && ! printf '%s' "$argv_line2" | grep -q -- "--effort" \
    && ! printf '%s' "$argv_line2" | grep -q -- "--base-branch"; } \
  && ok "worker-start argv: --effort omitted when SDP_ORCA_MODEL is unset (gated correctly, default agent=claude)" \
  || bad "worker-start argv: --effort leaked without a model, or default agent wrong: $argv_line2"

# ==============================================================================
# 9. orchestration reset: never called, anywhere in this suite
# ==============================================================================
echo "== orchestration reset: never called =="
if grep -q "orchestration reset" "$CTRL/calls.log"; then
  bad "orchestration reset WAS invoked at least once across the suite (see $CTRL/calls.log)"
else
  ok "orchestration reset: zero invocations across the entire suite ($(log_lines) total stub calls)"
fi

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
