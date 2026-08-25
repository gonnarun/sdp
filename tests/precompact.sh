#!/usr/bin/env bash
# precompact.sh -- the precompact hook chain: packaging, gating, and the
# compact -> resume link end to end.
#
# The chain is: Stop hook detects the threshold and answers decision:block so
# the model gets a tool-capable turn to write the snapshot -> PreCompact binds
# that snapshot to this session_id -> SessionStart(compact) injects the path as
# additionalContext and clears the marker. Everything below drives those three
# entry points directly with fixture stdin; no model calls.
#
# HOME is redirected per case so the real ~/.sdp is never touched. The hook
# reads the passwd database rather than $HOME, so the redirect alone is not
# enough -- each case that needs isolated state also asserts against the real
# state dir only through markers keyed by a test-only session id.
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SDP_ROOT" || exit 1
# The hook reads the user's model setting as a window hint, and it resolves
# that path from the passwd database, so a HOME redirect cannot reach it. Point
# it at a nonexistent file so the runner's own settings never decide a fixture;
# the cases that are ABOUT the hint set it explicitly.
# The path seams below are inert in production; the suite opts into them, and
# they only resolve inside the user's own home, so every seam path used here
# lives under $HOME rather than $TMPDIR.
export SDP_PRECOMPACT_SELFTEST=1
SELFTEST_HOME="$(python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/selftest-$$"
mkdir -p "$SELFTEST_HOME"
export SDP_PRECOMPACT_SETTINGS="$SELFTEST_HOME/absent-settings.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

HOOK_CANONICAL="plugins/sdp/scripts/precompact_hook.py"
HOOK_MIRROR="scripts/precompact_hook.py"
MANIFEST_CANONICAL="plugins/sdp/hooks/hooks.json"
MANIFEST_MIRROR="hooks/hooks.json"

# ---------------------------------------------------------------- packaging --

[ -x "$HOOK_CANONICAL" ] && ok "canonical hook driver present and executable" \
  || bad "canonical hook driver missing or not executable: $HOOK_CANONICAL"
[ -x "$HOOK_MIRROR" ] && ok "root mirror hook driver present and executable" \
  || bad "root mirror hook driver missing or not executable: $HOOK_MIRROR"
cmp -s "$HOOK_CANONICAL" "$HOOK_MIRROR" && ok "hook driver: canonical and mirror are byte-identical" \
  || bad "hook driver drifted between canonical and mirror"
cmp -s "$MANIFEST_CANONICAL" "$MANIFEST_MIRROR" && ok "hooks manifest: canonical and mirror are byte-identical" \
  || bad "hooks manifest drifted between canonical and mirror"

python3 -m json.tool "$MANIFEST_CANONICAL" >/dev/null 2>&1 \
  && ok "hooks.json is valid JSON" || bad "hooks.json is not valid JSON"

# The three events are the whole contract. A missing one silently degrades the
# chain to "manual command" without any error surfacing, which is exactly the
# half-installed failure this test exists to catch.
for event in Stop PreCompact SessionStart; do
  python3 - "$MANIFEST_CANONICAL" "$event" <<'PY' && ok "hooks.json registers $event" || bad "hooks.json missing $event"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
raise SystemExit(0 if sys.argv[2] in hooks else 1)
PY
done

python3 - "$MANIFEST_CANONICAL" <<'PY' && ok "SessionStart is scoped to the compact matcher" || bad "SessionStart matcher is not 'compact'"
import json, sys
entries = json.load(open(sys.argv[1]))["hooks"]["SessionStart"]
raise SystemExit(0 if all(e.get("matcher") == "compact" for e in entries) else 1)
PY

# ${CLAUDE_PLUGIN_ROOT} is the only path form that survives installation into
# the versioned plugin cache. A repo-relative command would resolve to whatever
# directory the user happens to be in.
python3 - "$MANIFEST_CANONICAL" <<'PY' && ok "every hook command is anchored to \${CLAUDE_PLUGIN_ROOT}" || bad "a hook command is not anchored to \${CLAUDE_PLUGIN_ROOT}"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
cmds = [h["command"] for entries in hooks.values() for e in entries for h in e["hooks"]]
raise SystemExit(0 if cmds and all("${CLAUDE_PLUGIN_ROOT}/scripts/precompact_hook.py" in c for c in cmds) else 1)
PY

# The standard hooks/hooks.json is auto-loaded by the host. Naming it in the
# manifest as well registers the same file twice.
python3 - <<'PY' && ok "plugin.json does not re-declare the auto-loaded hooks file" || bad "plugin.json re-declares hooks/hooks.json (duplicate registration)"
import json
manifest = json.load(open("plugins/sdp/.claude-plugin/plugin.json"))
raise SystemExit(0 if "hooks" not in manifest else 1)
PY

# ------------------------------------------------------------------ gating --

# Fail-close: an unset mode must never behave as auto. This is the single gate
# that keeps the automation from firing for someone who never opted in.
out="$(printf '{"session_id":"t-unset","transcript_path":"","cwd":""}' \
  | SDP_PRECOMPACT_MODE= python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "unset mode does not block (fail-close)" || bad "unset mode produced output: $out"

out="$(printf '{"session_id":"t-manual","transcript_path":"","cwd":""}' \
  | SDP_PRECOMPACT_MODE=manual python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "manual mode does not block" || bad "manual mode produced output: $out"

# ---------------------------------------------------------------- end to end --

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sdp_precompact.XXXXXX")"

# Session ids below are keyed on $$, and PIDs are reused. One file leaked by an
# earlier run silently changes the outcome of a later one, so sweep the whole
# test namespace at both ends rather than relying on per-case cleanup.
SELFTEST_STATE="$(python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact-state"
sweep_selftest_state() { rm -f "$SELFTEST_STATE"/*sdp-precompact-selftest-*.json; }
sweep_selftest_state
trap 'rm -rf "$TMP" "$SELFTEST_HOME"; sweep_selftest_state' EXIT
PROJ="$TMP/proj"
DAY="$(date +%Y%m%d)"
mkdir -p "$PROJ/.private/precompact/$DAY"

# 90% of a 200k window: input + cache_creation + cache_read is what occupies
# context; output tokens are not resident and must not be counted.
cat > "$TMP/transcript.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":5000,"cache_read_input_tokens":175000,"output_tokens":9999}}}
JSONL

SID="main-sdp-precompact-selftest-$$"
STATE="$(python3 -c 'import os,pwd,sys;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact-state/$SID.json"
rm -f "$STATE" "${STATE%.json}.window.json"
cleanup_state() { rm -f "$STATE" "${STATE%.json}.window.json"; }
trap 'rm -rf "$TMP" "$SELFTEST_HOME"; cleanup_state; sweep_selftest_state' EXIT

# Every narrow-window fixture pins SDP_PRECOMPACT_CONTEXT_TOKENS=200000. Left
# unpinned, the runner's own model setting would widen the window and the
# 90%-of-200k fixture would read as 18%.
stop_in()   { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":%s}' "$SID" "$TMP/transcript.jsonl" "$PROJ" "$1"; }
pre_in()    { printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID" "$PROJ"; }
resume_in() { printf '{"session_id":"%s","cwd":"%s","source":"compact"}' "$SID" "$PROJ"; }

# 1. Stop past the threshold must block, and the reason must be actionable.
out="$(stop_in false | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
python3 - "$out" <<'PY' && ok "Stop past the threshold returns decision:block" || bad "Stop did not return decision:block (got: $out)"
import json, sys
try:
    payload = json.loads(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if payload.get("decision") == "block" and payload.get("reason") else 1)
PY
case "$out" in
  *".private/precompact/$DAY/precompact_"*) ok "block reason names today's snapshot path" ;;
  *) bad "block reason does not name today's snapshot path" ;;
esac
# continue:false would end the turn instead of granting one. Its absence is the
# difference between "the model writes the snapshot" and "the turn just stops".
case "$out" in
  *'"continue"'*) bad "block payload sets continue (ends the turn instead of granting one)" ;;
  *) ok "block payload leaves continue at its default so the turn proceeds" ;;
esac
[ -f "$STATE" ] && ok "Stop wrote the session marker" || bad "Stop did not write the session marker"

# 2. The host sets stop_hook_active on the Stop that follows a block. Ignoring
#    it would re-block up to the host cap on every turn. Asserted on a session
#    with NO marker, so the live-marker check cannot mask a missing guard.
SID_ACTIVE="active-sdp-precompact-selftest-$$"
STATE_ACTIVE="$(python3 -c 'import os,pwd,sys;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact-state/$SID_ACTIVE.json"
rm -f "$STATE_ACTIVE" "${STATE_ACTIVE%.json}.window.json"
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":true}' "$SID_ACTIVE" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "stop_hook_active suppresses the block with no marker present" \
  || bad "stop_hook_active did not suppress the block (got: $out)"
[ ! -f "$STATE_ACTIVE" ] && ok "stop_hook_active path writes no marker" || bad "stop_hook_active path wrote a marker"
rm -f "$STATE_ACTIVE" "${STATE_ACTIVE%.json}.window.json"

# A subagent must never be blocked: agent_id present means this is not the main
# thread, and blocking there would stall the parent turn.
SID_SUB="sub-sdp-precompact-selftest-$$"
STATE_SUB="$(python3 -c 'import os,pwd,sys;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact-state/$SID_SUB.json"
rm -f "$STATE_SUB" "${STATE_SUB%.json}.window.json"
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false,"agent_id":"a-1"}' "$SID_SUB" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "a subagent Stop is never blocked" || bad "a subagent Stop was blocked (got: $out)"
rm -f "$STATE_SUB" "${STATE_SUB%.json}.window.json"

# 3. A live marker suppresses re-blocking even without stop_hook_active.
out="$(stop_in false | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "a live marker suppresses repeat blocking" || bad "repeat block fired with a live marker"

# 3b. Window calibration. A wide-window session records the model id WITHOUT
#     any [1m] marker, so trusting the model string reads the window 5x too
#     small and fires on nearly every turn. Peak observed occupancy is what
#     settles it: 300k of context proves the window is not 200k.
cat > "$TMP/wide.jsonl" <<'JSONL'
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":300000}}}
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":309000}}}
JSONL
SID_WIDE="wide-sdp-precompact-selftest-$$"
STATE_WIDE="$(python3 -c 'import os,pwd,sys;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact-state/$SID_WIDE.json"
rm -f "$STATE_WIDE" "${STATE_WIDE%.json}.window.json"
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_WIDE" "$TMP/wide.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "310k of a wide window is under threshold (window calibrated from usage, not the model id)" \
  || bad "wide-window session blocked at 310k -- window mis-inferred as narrow"
rm -f "$STATE_WIDE" "${STATE_WIDE%.json}.window.json"

# An explicit window override must win over the calibration.
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_WIDE" "$TMP/wide.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=350000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -n "$out" ] && ok "SDP_PRECOMPACT_CONTEXT_TOKENS overrides the inferred window" \
  || bad "explicit window override was ignored"
rm -f "$STATE_WIDE" "${STATE_WIDE%.json}.window.json"

# A subagent's turns share the transcript. Counting them would measure the
# wrong conversation, so sidechain records must be skipped entirely.
cat > "$TMP/side.jsonl" <<'JSONL'
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":10000}}}
{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":5000,"cache_read_input_tokens":175000}}}
JSONL
SID_SIDE="side-sdp-precompact-selftest-$$"
STATE_SIDE="$(python3 -c 'import os,pwd,sys;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact-state/$SID_SIDE.json"
rm -f "$STATE_SIDE" "${STATE_SIDE%.json}.window.json"
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_SIDE" "$TMP/side.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "a subagent's usage is not counted as main-thread occupancy" \
  || bad "sidechain usage was measured as the main thread's (got: $out)"
rm -f "$STATE_SIDE" "${STATE_SIDE%.json}.window.json"

# 3c. The window must never narrow within a session. After a compaction the
#     surviving records are small, and once the pre-compact evidence scrolls out
#     of the scanned tail a genuinely wide session would read as narrow and
#     block at 156k on the way back up.
SID_STICKY="sticky-sdp-precompact-selftest-$$"
STATE_STICKY="$(python3 -c 'import os,pwd,sys;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact-state/$SID_STICKY.json"
rm -f "$STATE_STICKY" "${STATE_STICKY%.json}.window.json"
# first Stop sees wide evidence and records the window
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_STICKY" "$TMP/wide.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
[ -f "${STATE_STICKY%.json}.window.json" ] && ok "the calibrated window is remembered for the session" \
  || bad "no window record was written"
# second Stop sees only narrow evidence; the remembered window must still hold
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_STICKY" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "a remembered wide window is not narrowed by a small tail" \
  || bad "the window narrowed mid-session and fired a spurious block"
rm -f "$STATE_STICKY" "${STATE_STICKY%.json}.window.json"

# 4. PreCompact binds the snapshot the model just wrote.
printf '# Precompact Snapshot: selftest\n' > "$PROJ/.private/precompact/$DAY/precompact_selftest.md"
pre_in | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE" "$PROJ/.private/precompact/$DAY/precompact_selftest.md" <<'PY' && ok "PreCompact binds the snapshot to the session marker" || bad "PreCompact did not bind the snapshot"
import json, os, sys
state = json.load(open(sys.argv[1]))
raise SystemExit(0 if os.path.realpath(state.get("snapshot", "")) == os.path.realpath(sys.argv[2]) else 1)
PY

# 5. SessionStart(compact) injects the resume context and re-arms.
out="$(resume_in | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" resume 2>/dev/null)"
python3 - "$out" <<'PY' && ok "resume emits SessionStart additionalContext naming the snapshot" || bad "resume did not emit usable additionalContext (got: $out)"
import json, sys
try:
    payload = json.loads(sys.argv[1])
except ValueError:
    raise SystemExit(1)
block = payload.get("hookSpecificOutput", {})
ctx = block.get("additionalContext", "")
ok = block.get("hookEventName") == "SessionStart" and "precompact_selftest.md" in ctx
raise SystemExit(0 if ok else 1)
PY
[ ! -f "$STATE" ] && ok "resume clears the marker so the cycle re-arms" || bad "resume left the marker in place (cycle cannot re-arm)"

# 6. A snapshot older than the session's request must not be adopted. This is
#    what stops a second session in the same directory from resuming the wrong
#    work -- the failure mode is silent and confident, so it is pinned here.
SID2="other-sdp-precompact-selftest-$$"
STATE2="$(python3 -c 'import os,pwd,sys;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact-state/$SID2.json"
rm -f "$STATE2" "${STATE2%.json}.window.json"
touch -t 200001010000 "$PROJ/.private/precompact/$DAY/precompact_selftest.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"manual"}' "$SID2" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
if [ -f "$STATE2" ]; then
  python3 - "$STATE2" <<'PY' && ok "a stale snapshot is not adopted by an unbound session" || bad "a stale snapshot was adopted (cross-session resume risk)"
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("snapshot") else 1)
PY
else
  ok "a stale snapshot is not adopted by an unbound session"
fi
rm -f "$STATE2" "${STATE2%.json}.window.json"

# ------------------------------------------------- window inference detail --

mkstate() { printf '%s/.sdp/precompact-state/%s.json' "$(python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)')" "$1"; }
drop()    { rm -f "$1" "${1%.json}.window.json"; }
run_stop() {
  # $1 = session id, $2 = transcript, rest = env assignments
  local sid="$1" tr="$2"; shift 2
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$sid" "$tr" "$PROJ" \
    | env "$@" SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null
}

# A recorded compaction states the occupancy that was actually reached. It is
# the only window evidence that survives the compaction, and it is what closes
# the band between the 156k threshold and the 196k calibration point: without
# it a 1M session reads as narrow on its first ramp and blocks at 16%.
cat > "$TMP/precompacted.jsonl" <<'JSONL'
{"type":"system","compactMetadata":{"trigger":"auto","preTokens":900000,"postTokens":14000}}
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":169000}}}
JSONL
SID_PRE="pre-sdp-precompact-selftest-$$"; STATE_PRE="$(mkstate "$SID_PRE")"; drop "$STATE_PRE"
out="$(run_stop "$SID_PRE" "$TMP/precompacted.jsonl")"
[ -z "$out" ] && ok "a recorded compaction's preTokens widens the window (no block at 170k of 1M)" \
  || bad "170k of a proven 1M window blocked -- preTokens evidence ignored"
drop "$STATE_PRE"

# Peak, not latest. After a compaction the newest record is small; calibrating
# from it alone reads the window 5x too small and blocks immediately.
cat > "$TMP/peakthenlow.jsonl" <<'JSONL'
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":900000}}}
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":14000}}}
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":1000,"cache_read_input_tokens":169000}}}
JSONL
SID_PEAK="peak-sdp-precompact-selftest-$$"; STATE_PEAK="$(mkstate "$SID_PEAK")"; drop "$STATE_PEAK"
out="$(run_stop "$SID_PEAK" "$TMP/peakthenlow.jsonl")"
[ -z "$out" ] && ok "the window is calibrated from peak occupancy, not the newest record" \
  || bad "calibrated from the newest record -- a post-compaction session blocks at 17%"
drop "$STATE_PEAK"

# The calibration point must stay just under the narrow window. Slide it far
# down and a plainly narrow session would be misread as wide and never block.
SID_NARROW="narrow-sdp-precompact-selftest-$$"; STATE_NARROW="$(mkstate "$SID_NARROW")"; drop "$STATE_NARROW"
out="$(run_stop "$SID_NARROW" "$TMP/transcript.jsonl")"
[ -n "$out" ] && ok "180k with no wide evidence still reads as a narrow window and blocks" \
  || bad "a narrow session did not block -- the calibration point is too low"
drop "$STATE_NARROW"

# The two override variables are separate contracts; one is the host's.
SID_HOSTENV="hostenv-sdp-precompact-selftest-$$"; STATE_HOSTENV="$(mkstate "$SID_HOSTENV")"; drop "$STATE_HOSTENV"
out="$(run_stop "$SID_HOSTENV" "$TMP/transcript.jsonl" CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000)"
[ -z "$out" ] && ok "CLAUDE_CODE_MAX_CONTEXT_TOKENS widens the window" \
  || bad "CLAUDE_CODE_MAX_CONTEXT_TOKENS was ignored"
drop "$STATE_HOSTENV"

# The model-setting hint, isolated from the runner's real settings file.
printf '{"model":"opus[1m]"}' > "$TMP/settings-wide.json"
SID_HINT="hint-sdp-precompact-selftest-$$"; STATE_HINT="$(mkstate "$SID_HINT")"; drop "$STATE_HINT"
out="$(run_stop "$SID_HINT" "$TMP/transcript.jsonl" SDP_PRECOMPACT_SETTINGS="$TMP/settings-wide.json")"
[ -z "$out" ] && ok "a [1m] model setting widens the window" || bad "the [1m] model setting was ignored"
drop "$STATE_HINT"

# ANTHROPIC_MODEL is one of the ways a wide window gets selected without any
# settings file naming it, and a session that has never compacted has no
# occupancy evidence to fall back on.
SID_AM="am-sdp-precompact-selftest-$$"; STATE_AM="$(mkstate "$SID_AM")"; drop "$STATE_AM"
out="$(run_stop "$SID_AM" "$TMP/transcript.jsonl" ANTHROPIC_MODEL=claude-opus-5\[1m\])"
[ -z "$out" ] && ok "ANTHROPIC_MODEL naming a wide variant widens the window" \
  || bad "ANTHROPIC_MODEL was ignored as a window hint"
drop "$STATE_AM"

# A [1m] model id in the transcript, which the host does not currently emit but
# which must still be honoured if it ever appears.
cat > "$TMP/wideid.jsonl" <<'JSONL'
{"type":"assistant","message":{"model":"claude-opus-5[1m]","usage":{"input_tokens":10,"cache_creation_input_tokens":5000,"cache_read_input_tokens":175000}}}
JSONL
SID_ID="id-sdp-precompact-selftest-$$"; STATE_ID="$(mkstate "$SID_ID")"; drop "$STATE_ID"
out="$(run_stop "$SID_ID" "$TMP/wideid.jsonl")"
[ -z "$out" ] && ok "a [1m] model id widens the window" || bad "the [1m] model id was ignored"
drop "$STATE_ID"

# API errors and interrupts are assistant turns with a <synthetic> model and
# zero usage. Reading one as current occupancy reports an empty context.
cat > "$TMP/synthetic.jsonl" <<'JSONL'
{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":5000,"cache_read_input_tokens":175000}}}
{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JSONL
SID_SYN="syn-sdp-precompact-selftest-$$"; STATE_SYN="$(mkstate "$SID_SYN")"; drop "$STATE_SYN"
out="$(run_stop "$SID_SYN" "$TMP/synthetic.jsonl" SDP_PRECOMPACT_CONTEXT_TOKENS=200000)"
[ -n "$out" ] && ok "a <synthetic> error record does not zero the measurement" \
  || bad "a <synthetic> record was read as the current occupancy"
drop "$STATE_SYN"

# --------------------------------------------------------- snapshot binding --

# Two sessions writing into one directory is the case the binding exists for.
# The other session's file is NEWER, so recency alone picks the wrong one.
SID_A="binda-sdp-precompact-selftest-$$"; STATE_A="$(mkstate "$SID_A")"; drop "$STATE_A"
TAG_A="$(printf '%s' "$SID_A" | cut -c1-8)"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_A" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
case "$out" in
  *"_${TAG_A}.md"*) ok "the block reason asks for a session-tagged snapshot filename" ;;
  *) bad "the block reason does not carry the session tag" ;;
esac
printf 'mine
'  > "$PROJ/.private/precompact/$DAY/precompact_auth_${TAG_A}.md"
sleep 1
printf 'theirs
' > "$PROJ/.private/precompact/$DAY/precompact_billing_other.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_A" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_A" <<'PY' && ok "binding prefers this session's tagged snapshot over a newer foreign one" || bad "bound a concurrent session's snapshot (wrong-work resume)"
import json, sys
snap = json.load(open(sys.argv[1])).get("snapshot", "")
raise SystemExit(0 if snap.endswith(".md") and "precompact_auth_" in snap else 1)
PY
drop "$STATE_A"

# Untagged fallback: a file that did not exist when the block fired is this
# session's; a file that did exist is not, however recently it was touched.
SID_C="bindc-sdp-precompact-selftest-$$"; STATE_C="$(mkstate "$SID_C")"; drop "$STATE_C"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true
printf 'older
' > "$PROJ/.private/precompact/$DAY/precompact_preexisting.md"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_C" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
sleep 1
touch "$PROJ/.private/precompact/$DAY/precompact_preexisting.md"   # bumped, still not ours
printf 'ours
' > "$PROJ/.private/precompact/$DAY/precompact_untagged_new.md"
touch -t 197001020000 "$PROJ/.private/precompact/$DAY/precompact_untagged_new.md" 2>/dev/null
touch "$PROJ/.private/precompact/$DAY/precompact_untagged_new.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_C" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_C" <<'PY' && ok "an mtime-bumped pre-existing file is never bound" || bad "a touched pre-existing snapshot was bound"
import json, sys
snap = json.load(open(sys.argv[1])).get("snapshot", "")
raise SystemExit(0 if "precompact_untagged_new" in snap else 1)
PY
drop "$STATE_C"

# Nothing new and nothing tagged means the snapshot was never written. Guessing
# here resumes the wrong work silently; admitting it is missing does not.
SID_D="bindd-sdp-precompact-selftest-$$"; STATE_D="$(mkstate "$SID_D")"; drop "$STATE_D"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true
printf 'foreign
' > "$PROJ/.private/precompact/$DAY/precompact_foreign.md"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_D" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
sleep 1
touch "$PROJ/.private/precompact/$DAY/precompact_foreign.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_D" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_D" <<'PY' && ok "no snapshot is bound when none is this session's" || bad "bound a foreign snapshot rather than reporting none"
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("snapshot") else 1)
PY
out="$(printf '{"session_id":"%s","cwd":"%s","source":"compact"}' "$SID_D" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" resume 2>/dev/null)"
case "$out" in
  *"no snapshot file was found"*) ok "resume says the snapshot is missing instead of naming a foreign one" ;;
  *) bad "resume did not report the missing snapshot (got: $out)" ;;
esac
drop "$STATE_D"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true

# The manual route has no inventory and usually no tag, so it can only fall
# back to recency -- and recency cannot tell two sessions apart. With more than
# one candidate it must decline rather than pick.
SID_M="manual-sdp-precompact-selftest-$$"; STATE_M="$(mkstate "$SID_M")"; drop "$STATE_M"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true
printf 'one\n' > "$PROJ/.private/precompact/$DAY/precompact_one.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"manual"}' "$SID_M" "$PROJ" \
  | SDP_PRECOMPACT_MODE=manual python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_M" <<'PY' && ok "manual route binds a single unambiguous snapshot" || bad "manual route did not bind the only candidate"
import json, os, sys
if not os.path.exists(sys.argv[1]):
    raise SystemExit(1)
raise SystemExit(0 if "precompact_one" in json.load(open(sys.argv[1])).get("snapshot", "") else 1)
PY
drop "$STATE_M"
sleep 1
printf 'two\n' > "$PROJ/.private/precompact/$DAY/precompact_two.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"manual"}' "$SID_M" "$PROJ" \
  | SDP_PRECOMPACT_MODE=manual python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
if [ -f "$STATE_M" ]; then
  python3 - "$STATE_M" <<'PY' && ok "manual route declines to guess between two candidates" || bad "manual route guessed the newest of two candidates"
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("snapshot") else 1)
PY
else
  ok "manual route declines to guess between two candidates"
fi
drop "$STATE_M"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true

# A snapshot directory large enough to overflow the marker would make the
# marker unreadable, and an unreadable marker means every turn blocks again.
# The inventory is therefore capped -- and a capped inventory cannot prove
# novelty, because an unlisted file may simply be one that did not fit.
SID_BIG="big-sdp-precompact-selftest-$$"; STATE_BIG="$(mkstate "$SID_BIG")"; drop "$STATE_BIG"
BIGDIR="$PROJ/.private/precompact/$DAY"
find "$BIGDIR" -maxdepth 1 -type f -delete 2>/dev/null || true
python3 - "$BIGDIR" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1]); d.mkdir(parents=True, exist_ok=True)
for i in range(1200):
    (d / ("precompact_bulk_%04d_%s.md" % (i, "x" * 60))).write_text("x")
# sorts last, so it falls outside the retained head of the inventory
(d / "precompact_zzz_outside_inventory.md").write_text("x")
PY
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_BIG" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
python3 - "$STATE_BIG" <<'PY' && ok "the stored inventory is capped and the marker stays readable" || bad "the inventory is unbounded -- the marker can outgrow the read cap"
import json, os, sys
size = os.path.getsize(sys.argv[1])
data = json.load(open(sys.argv[1]))
listed = data.get("pre_existing") or []
ok = (
    size < (1 << 20)
    and data.get("state") == "pending"
    and data.get("inventory_complete") is False
    and len(listed) <= 500
)
raise SystemExit(0 if ok else 1)
PY
# A file the cap left out is still pre-existing. Novelty must be unavailable,
# not merely vacuous, or that file gets bound as if this session had written it.
sleep 1
touch "$BIGDIR/precompact_zzz_outside_inventory.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_BIG" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_BIG" <<'PY' && ok "a truncated inventory disables novelty instead of trusting it" || bad "bound a pre-existing file the inventory cap had omitted"
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("snapshot") else 1)
PY
drop "$STATE_BIG"
find "$BIGDIR" -maxdepth 1 -type f -delete 2>/dev/null || true

# Novelty alone is not enough. Two sessions that each write a NEW file are both
# novel with respect to this session's inventory, and breaking that tie by
# recency is the same wrong-work resume the tag exists to prevent. The tag is a
# filename instruction to a model, so the untagged case must fail safe.
SID_E="ambig-sdp-precompact-selftest-$$"; STATE_E="$(mkstate "$SID_E")"; drop "$STATE_E"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_E" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
printf 'mine, untagged\n'  > "$PROJ/.private/precompact/$DAY/precompact_auth.md"
sleep 1
printf 'theirs\n'          > "$PROJ/.private/precompact/$DAY/precompact_billing.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_E" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_E" <<'PY' && ok "two equally novel snapshots bind nothing rather than the newer" || bad "picked the newer of two novel snapshots (concurrent-session resume)"
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("snapshot") else 1)
PY
drop "$STATE_E"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true

# A pending marker expires in 20 minutes, so one session blocks several times.
# Re-taking the inventory each time would fold this session's own earlier
# snapshot into "pre-existing" and make an in-place update unbindable.
SID_R="recycle-sdp-precompact-selftest-$$"; STATE_R="$(mkstate "$SID_R")"; drop "$STATE_R"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true
printf 'foreign\n' > "$PROJ/.private/precompact/$DAY/precompact_foreign_old.md"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_R" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
printf 'cycle one\n' > "$PROJ/.private/precompact/$DAY/precompact_work.md"
# age the marker past PENDING_EXPIRY so the next Stop blocks again
python3 - "$STATE_R" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p)); d["at"] = time.time() - 3600
json.dump(d, open(p, "w"))
PY
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_R" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
python3 - "$STATE_R" <<'PY' && ok "the pre-session inventory is carried across repeated blocks" || bad "the inventory was re-taken and swallowed this session's own snapshot"
import json, sys
listed = json.load(open(sys.argv[1])).get("pre_existing") or []
raise SystemExit(0 if listed == ["precompact_foreign_old.md"] else 1)
PY
printf 'cycle two, updated in place\n' > "$PROJ/.private/precompact/$DAY/precompact_work.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_R" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_R" <<'PY' && ok "a snapshot updated in place on a later cycle is still bound" || bad "an in-place update on a second block cycle was not bound"
import json, sys
raise SystemExit(0 if "precompact_work" in json.load(open(sys.argv[1])).get("snapshot", "") else 1)
PY
drop "$STATE_R"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true

# Letter case must not make a written snapshot invisible.
SID_CASE="case-sdp-precompact-selftest-$$"; STATE_CASE="$(mkstate "$SID_CASE")"; drop "$STATE_CASE"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true
TAG_CASE="$(printf '%s' "$SID_CASE" | cut -c1-8)"
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_CASE" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
printf 'cased\n' > "$PROJ/.private/precompact/$DAY/Precompact_Auth_${TAG_CASE}.MD"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_CASE" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_CASE" <<'PY' && ok "a snapshot written with different letter case is still found" || bad "letter case made a written snapshot invisible"
import json, sys
raise SystemExit(0 if json.load(open(sys.argv[1])).get("snapshot") else 1)
PY
drop "$STATE_CASE"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true

# The path seams are test scaffolding. Left live in production they would hand
# a hostile environment the state directory -- including the prune that deletes
# from it -- which is the capability passwd-home resolution exists to deny.
SEAMDIR="$SELFTEST_HOME/seam"
mkdir -p "$SEAMDIR"
out="$(SDP_PRECOMPACT_SELFTEST= SDP_PRECOMPACT_STATE_DIR="$SEAMDIR" python3 "$HOOK_CANONICAL" doctor 2>&1 | grep -c "$SEAMDIR" || true)"
[ "$out" = "0" ] && ok "SDP_PRECOMPACT_STATE_DIR is inert without the selftest flag" \
  || bad "the state-dir seam is live in production"
out="$(SDP_PRECOMPACT_SELFTEST=1 SDP_PRECOMPACT_STATE_DIR="$SEAMDIR" python3 "$HOOK_CANONICAL" doctor 2>&1 | grep -c "$SEAMDIR" || true)"
[ "$out" != "0" ] && ok "SDP_PRECOMPACT_STATE_DIR works with the selftest flag" \
  || bad "the state-dir seam does not work even when enabled"

# The flag alone is only hygiene -- whoever can set the path can set the flag.
# The binding constraint is that the override must resolve inside the user's own
# home, which is what keeps the prune-driven delete out of arbitrary directories.
OUTSIDE="$TMP/outside-home"; mkdir -p "$OUTSIDE"
# The hook prints the RESOLVED override, and on macOS $TMPDIR resolves through
# /private. Compare against the resolved form or the grep can never match and
# the assertion passes for the wrong reason.
OUTSIDE_REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OUTSIDE")"
out="$(SDP_PRECOMPACT_SELFTEST=1 SDP_PRECOMPACT_STATE_DIR="$OUTSIDE" python3 "$HOOK_CANONICAL" doctor 2>&1 | grep -cE "$OUTSIDE|$OUTSIDE_REAL" || true)"
[ "$out" = "0" ] && ok "a seam path outside the user's home is refused even with the flag" \
  || bad "the seam accepted a path outside the user's home"

# The truncated-inventory and unambiguity rules mask each other whenever many
# files are in play: an empty exclude set makes everything novel, and "many
# novel" already refuses. The gap they leave open is ONE candidate -- a single
# pre-existing file the cap omitted, which a vacuous novelty test or a leaked
# recency fallback would bind as this session's work.
SID_ONE="oneold-sdp-precompact-selftest-$$"; STATE_ONE="$(mkstate "$SID_ONE")"; drop "$STATE_ONE"
ONEDIR="$PROJ/.private/precompact/$DAY"
find "$ONEDIR" -maxdepth 1 -type f -delete 2>/dev/null || true
python3 - "$ONEDIR" <<'PY'
import os, pathlib, sys, time
d = pathlib.Path(sys.argv[1]); d.mkdir(parents=True, exist_ok=True)
old = time.time() - 7200
for i in range(1200):
    f = d / ("precompact_bulk_%04d_%s.md" % (i, "x" * 60))
    f.write_text("x")
    os.utime(f, (old, old))          # below the binding floor, so not candidates
v = d / "precompact_zzz_foreign_recent.md"
v.write_text("x")                    # pre-existing, recent: the only candidate
PY
printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_ONE" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop >/dev/null 2>&1
python3 - "$STATE_ONE" <<'PY' && ok "the single-candidate case still records a truncated inventory" || bad "fixture did not produce a truncated inventory"
import json, sys
d = json.load(open(sys.argv[1]))
raise SystemExit(0 if d.get("inventory_complete") is False else 1)
PY
sleep 1
touch "$ONEDIR/precompact_zzz_foreign_recent.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_ONE" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_ONE" <<'PY' && ok "a lone pre-existing candidate is not bound under a truncated inventory" || bad "bound the only candidate although it pre-dated this session"
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("snapshot") else 1)
PY
drop "$STATE_ONE"
find "$ONEDIR" -maxdepth 1 -type f -delete 2>/dev/null || true

# ------------------------------------------------------- marker robustness --

# A clock step backwards leaves a marker dated in the future. Subtracting from
# it never exceeds any expiry, so detection would be suppressed forever.
SID_F="future-sdp-precompact-selftest-$$"; STATE_F="$(mkstate "$SID_F")"; drop "$STATE_F"
mkdir -p "$(dirname "$STATE_F")"
printf '{"state":"pending","at":1.0e18,"cwd":"%s"}' "$PROJ" > "$STATE_F"
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_F" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -n "$out" ] && ok "a marker dated in the future does not suppress detection" \
  || bad "a future-dated marker permanently suppressed detection"
drop "$STATE_F"

# If the marker cannot be persisted, nothing suppresses the next detection, so
# blocking would repeat every turn. Staying silent is the safe answer.
SID_G="nowrite-sdp-precompact-selftest-$$"
# Must sit under $HOME or the seam refuses the override and the case would
# silently exercise the real state directory instead.
GUARD="$SELFTEST_HOME/guard"; mkdir -p "$GUARD"
printf 'not a directory
' > "$GUARD/blocked"
out="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$SID_G" "$TMP/transcript.jsonl" "$PROJ" \
  | SDP_PRECOMPACT_STATE_DIR="$GUARD/blocked" SDP_PRECOMPACT_CONTEXT_TOKENS=200000 SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "no block is emitted when the marker cannot be persisted" \
  || bad "blocked without a persisted marker (would repeat every turn)"

# ------------------------------------------------------------------ doctor --

# doctor must be non-zero when the automation is not armed. A health check that
# reports success on a half-install is how this class of bug survives for weeks.
SDP_PRECOMPACT_MODE=manual python3 "$HOOK_CANONICAL" doctor >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "doctor exits non-zero when automation is not armed" \
  || bad "doctor reported success while automation was off"

SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" doctor >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "doctor exits zero when armed and the manifest resolves" \
  || bad "doctor failed while armed with a resolvable manifest"

mode="$(SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" config get 2>/dev/null)"
[ "$mode" = "auto" ] && ok "config get reports the resolved mode" || bad "config get reported '$mode'"

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
