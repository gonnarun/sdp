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

python3 - "$MANIFEST_CANONICAL" <<'PY' && ok "SessionStart is one unscoped hook that binds and resumes" || bad "SessionStart is not a single unscoped start hook"
import json, sys
entries = json.load(open(sys.argv[1]))["hooks"]["SessionStart"]
if len(entries) != 1 or entries[0].get("matcher") != "":
    sys.stderr.write("  expected one unscoped entry, got %r\n"
                     % [e.get("matcher") for e in entries])
    raise SystemExit(1)
cmds = [hk.get("command", "") for hk in entries[0].get("hooks", [])]
raise SystemExit(0 if all(c.rstrip().endswith(" start") for c in cmds) else 1)
PY

# ${CLAUDE_PLUGIN_ROOT} is the only path form that survives installation into
# the versioned plugin cache. A repo-relative command would resolve to whatever
# directory the user happens to be in.
python3 - "$MANIFEST_CANONICAL" <<'PY' && ok "every hook command is anchored to \${CLAUDE_PLUGIN_ROOT}" || bad "a hook command is not anchored to \${CLAUDE_PLUGIN_ROOT}"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
cmds = [h["command"] for entries in hooks.values() for e in entries for h in e["hooks"]]
# The hook is reached through scripts/precompact_launcher.sh now (Windows CPython
# does not guarantee a `python3` name), so the assertion is on the ANCHOR and the
# plugin-owned scripts dir, which is what this guard was always about -- not on one
# particular filename.
raise SystemExit(0 if cmds and all("${CLAUDE_PLUGIN_ROOT}/scripts/" in c for c in cmds) else 1)
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
out="$(printf '{"session_id":"unset-sdp-precompact-selftest-gate","transcript_path":"","cwd":""}' \
  | SDP_PRECOMPACT_MODE= python3 "$HOOK_CANONICAL" stop 2>/dev/null)"
[ -z "$out" ] && ok "unset mode does not block (fail-close)" || bad "unset mode produced output: $out"

out="$(printf '{"session_id":"manual-sdp-precompact-selftest-gate","transcript_path":"","cwd":""}' \
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

# The model-setting hint, isolated from the runner's real settings file. The
# fixture MUST live under $HOME: the seam refuses a path outside it, and a
# refused override falls back to the real ~/.claude/settings.json -- which on a
# developer machine may itself name [1m] and satisfy this for the wrong reason.
# CI has no such file, which is where that mistake surfaces.
# Both fixtures come from ONE variable so they cannot drift apart. If HINTDIR
# ever moves outside $HOME the seam refuses it and BOTH fall back to the real
# ~/.claude/settings.json -- the negative case below then contradicts the
# positive one, which is what makes the mistake visible instead of silent.
HINTDIR="$SELFTEST_HOME"
printf '{"model":"opus[1m]"}' > "$HINTDIR/settings-wide.json"
printf '{"model":"opus"}'     > "$HINTDIR/settings-narrow.json"
SID_HINT="hint-sdp-precompact-selftest-$$"; STATE_HINT="$(mkstate "$SID_HINT")"; drop "$STATE_HINT"
out="$(run_stop "$SID_HINT" "$TMP/transcript.jsonl" SDP_PRECOMPACT_SETTINGS="$HINTDIR/settings-wide.json")"
[ -z "$out" ] && ok "a [1m] model setting widens the window" || bad "the [1m] model setting was ignored"
drop "$STATE_HINT"

# The negative half. Without it the case above passes whenever the override is
# ignored and some other wide signal happens to be present.
SID_NH="narrowhint-sdp-precompact-selftest-$$"; STATE_NH="$(mkstate "$SID_NH")"; drop "$STATE_NH"
out="$(run_stop "$SID_NH" "$TMP/transcript.jsonl" SDP_PRECOMPACT_SETTINGS="$HINTDIR/settings-narrow.json")"
[ -n "$out" ] && ok "a settings file naming no wide model leaves the window narrow" \
  || bad "the window widened with no wide signal (the settings seam is not being read)"
drop "$STATE_NH"

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

# ---------------------------------------------------------- codex rollout --

# Codex writes a different transcript format, so the same measurement has to
# work against it. Shape captured from codex-cli 0.149.1; the numbers are
# synthetic. This is not a documented interface -- the fixture is here so a
# format change is caught as a test failure rather than as a hook that quietly
# never fires.
cat > "$TMP/codex.jsonl" <<'JSONL'
{"timestamp":"2026-08-25T03:00:00.000Z","type":"session_meta","payload":{"id":"01a03000-0000-7000-0000-000000000000"}}
{"timestamp":"2026-08-25T03:10:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000000,"cached_input_tokens":3900000,"output_tokens":18000,"total_tokens":4018000},"last_token_usage":{"input_tokens":90000,"cached_input_tokens":88000,"output_tokens":100,"total_tokens":90100},"model_context_window":258400}}}
{"timestamp":"2026-08-25T03:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4600000,"cached_input_tokens":4300000,"output_tokens":18370,"total_tokens":4618370},"last_token_usage":{"input_tokens":210000,"cached_input_tokens":209000,"output_tokens":101,"total_tokens":210101},"model_context_window":258400}}}
JSONL

SID_CX="codex-sdp-precompact-selftest-$$"; STATE_CX="$(mkstate "$SID_CX")"; drop "$STATE_CX"
# 210000 of a declared 258400 window is 81%, past the 78% threshold.
out="$(run_stop "$SID_CX" "$TMP/codex.jsonl")"
[ -n "$out" ] && ok "a Codex rollout is measured and blocks past the threshold" \
  || bad "the Codex transcript format was not measured (parser did not match)"
python3 - "$STATE_CX" <<'PY' && ok "Codex occupancy comes from last_token_usage, and the window is the declared one" || bad "Codex measurement used the wrong fields"
import json, sys
d = json.load(open(sys.argv[1]))
# total_token_usage is the cumulative session bill (millions) -- reading it
# would report every session as instantly full.
raise SystemExit(0 if d.get("used_tokens") == 210000 and d.get("context_limit") == 258400 else 1)
PY
drop "$STATE_CX"

# Below the threshold the same fixture must stay quiet, which pins that the
# window really is the declared 258400 and not an inferred default.
cat > "$TMP/codex-low.jsonl" <<'JSONL'
{"timestamp":"2026-08-25T03:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4600000,"cached_input_tokens":4300000,"output_tokens":18370,"total_tokens":4618370},"last_token_usage":{"input_tokens":170000,"cached_input_tokens":169000,"output_tokens":101,"total_tokens":170101},"model_context_window":258400}}}
JSONL
SID_CXL="codexlow-sdp-precompact-selftest-$$"; STATE_CXL="$(mkstate "$SID_CXL")"; drop "$STATE_CXL"
out="$(run_stop "$SID_CXL" "$TMP/codex-low.jsonl")"
[ -z "$out" ] && ok "170k of a declared 258400 window is under threshold" \
  || bad "blocked at 66% -- the declared window was ignored"
drop "$STATE_CXL"

# An unrecognisable transcript must measure nothing rather than something
# wrong: the hook then simply never fires on that host.
printf '{"type":"event_msg","payload":{"type":"agent_message","message":"hi"}}\n' > "$TMP/codex-unknown.jsonl"
SID_CXU="codexunk-sdp-precompact-selftest-$$"; STATE_CXU="$(mkstate "$SID_CXU")"; drop "$STATE_CXU"
out="$(run_stop "$SID_CXU" "$TMP/codex-unknown.jsonl")"
[ -z "$out" ] && ok "an unreadable transcript measures nothing instead of guessing" \
  || bad "an unreadable transcript produced a block"
drop "$STATE_CXU"

# A Codex session can change model mid-flight, and each token_count event
# states the window that applied to THAT request. Taking the widest window ever
# seen and dividing the newest usage by it is fail-open: 210k of a 258400
# window reads as 21%, the threshold is never crossed, and the snapshot is
# never requested. The pair has to come from one event.
cat > "$TMP/codex-switched.jsonl" <<'JSONL'
{"timestamp":"2026-08-25T03:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000000},"last_token_usage":{"input_tokens":300000},"model_context_window":1000000}}}
{"timestamp":"2026-08-25T03:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4600000},"last_token_usage":{"input_tokens":210000},"model_context_window":258400}}}
JSONL
SID_SW="cxswitch-sdp-precompact-selftest-$$"; STATE_SW="$(mkstate "$SID_SW")"; drop "$STATE_SW"
out="$(run_stop "$SID_SW" "$TMP/codex-switched.jsonl")"
[ -n "$out" ] && ok "after a switch to a narrower model the newest window is used (210k of 258400 blocks)" \
  || bad "an earlier wider window was reused -- 81% occupancy measured as 21%, snapshot missed"
python3 - "$STATE_SW" <<'PY' && ok "the recorded limit is the newest event's window, not the widest seen" || bad "the marker recorded a stale window"
import json, sys
d = json.load(open(sys.argv[1]))
raise SystemExit(0 if d.get("context_limit") == 258400 and d.get("used_tokens") == 210000 else 1)
PY
drop "$STATE_SW"

# The sticky window is a Claude-only device: it exists because Claude's window
# can only be inferred. A remembered wide value must not survive onto a host
# that states its window, or the same fail-open returns by another route.
SID_SWS="cxsticky-sdp-precompact-selftest-$$"; STATE_SWS="$(mkstate "$SID_SWS")"; drop "$STATE_SWS"
mkdir -p "$(dirname "$STATE_SWS")"
printf '{"limit":1000000,"at":%s}' "$(date +%s)" > "${STATE_SWS%.json}.window.json"
out="$(run_stop "$SID_SWS" "$TMP/codex-switched.jsonl")"
[ -n "$out" ] && ok "a remembered wide window does not override a host-stated one" \
  || bad "the sticky window overrode an exact window and suppressed the block"
drop "$STATE_SWS"

# CLAUDE_CODE_MAX_CONTEXT_TOKENS is the other host's override. Exported into a
# Codex session it must not overrule the window Codex just reported.
SID_CXE="cxenv-sdp-precompact-selftest-$$"; STATE_CXE="$(mkstate "$SID_CXE")"; drop "$STATE_CXE"
out="$(run_stop "$SID_CXE" "$TMP/codex-switched.jsonl" CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000)"
[ -n "$out" ] && ok "a Claude-only window override does not overrule a host-stated Codex window" \
  || bad "CLAUDE_CODE_MAX_CONTEXT_TOKENS overrode the exact Codex window"
drop "$STATE_CXE"

# The plugin's own override is the documented escape hatch and still outranks
# everything, including an exact window.
SID_CXO="cxover-sdp-precompact-selftest-$$"; STATE_CXO="$(mkstate "$SID_CXO")"; drop "$STATE_CXO"
out="$(run_stop "$SID_CXO" "$TMP/codex-switched.jsonl" SDP_PRECOMPACT_CONTEXT_TOKENS=1000000)"
[ -z "$out" ] && ok "SDP_PRECOMPACT_CONTEXT_TOKENS still outranks a host-stated window" \
  || bad "the documented cross-host override stopped working"
drop "$STATE_CXO"

# The reverse switch, so the rule reads as "newest" and not as "narrowest".
cat > "$TMP/codex-widened.jsonl" <<'JSONL'
{"timestamp":"2026-08-25T03:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200000},"model_context_window":258400}}}
{"timestamp":"2026-08-25T03:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":210000},"model_context_window":1000000}}}
JSONL
SID_WD="cxwiden-sdp-precompact-selftest-$$"; STATE_WD="$(mkstate "$SID_WD")"; drop "$STATE_WD"
out="$(run_stop "$SID_WD" "$TMP/codex-widened.jsonl")"
[ -z "$out" ] && ok "after a switch to a wider model the newest window is used (210k of 1M is quiet)" \
  || bad "an earlier narrower window was reused and produced a spurious block"
drop "$STATE_WD"

# ------------------------------------------------ compaction without a marker --

# Detection can be silent -- an unreadable transcript is exactly that case --
# and then an automatic compaction arrives with no marker. This session has no
# claim on anything in the directory, so binding the newest file would bind
# whatever another session happened to write.
SID_AN="autonomark-sdp-precompact-selftest-$$"; STATE_AN="$(mkstate "$SID_AN")"; drop "$STATE_AN"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true
printf 'someone elses\n' > "$PROJ/.private/precompact/$DAY/precompact_other_session.md"
printf '{"session_id":"%s","cwd":"%s","trigger":"auto"}' "$SID_AN" "$PROJ" \
  | SDP_PRECOMPACT_MODE=auto python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
if [ -f "$STATE_AN" ]; then
  python3 - "$STATE_AN" <<'PY' && ok "an automatic compaction with no marker binds nothing" || bad "auto compaction with no marker bound a foreign snapshot"
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1])).get("snapshot") else 1)
PY
else
  ok "an automatic compaction with no marker binds nothing"
fi
drop "$STATE_AN"

# The manual route is unchanged: the user ran /sdp:precompact themselves, so a
# single recent snapshot is theirs.
SID_MN="manualnomark-sdp-precompact-selftest-$$"; STATE_MN="$(mkstate "$SID_MN")"; drop "$STATE_MN"
printf '{"session_id":"%s","cwd":"%s","trigger":"manual"}' "$SID_MN" "$PROJ" \
  | SDP_PRECOMPACT_MODE=manual python3 "$HOOK_CANONICAL" precompact >/dev/null 2>&1
python3 - "$STATE_MN" <<'PY' && ok "a manual compaction with no marker still binds the one recent snapshot" || bad "the manual route stopped binding"
import json, os, sys
if not os.path.exists(sys.argv[1]):
    raise SystemExit(1)
raise SystemExit(0 if "precompact_other_session" in json.load(open(sys.argv[1])).get("snapshot", "") else 1)
PY
drop "$STATE_MN"
find "$PROJ/.private/precompact/$DAY" -maxdepth 1 -type f -delete 2>/dev/null || true

# --------------------------------------------------------- terminal driver --

# The one step neither a hook nor a skill can perform for itself: a hook cannot
# expand a slash command, and no host exposes a programmatic compaction
# trigger. Where a terminal driver is bound, the command queues `/compact` into
# the session's own composer; where it is not, every branch here is skipped and
# the chain still completes later on the host's own auto-compaction. That
# second case is the one most users are in, so it is pinned first.
out="$(env -u ORCA_PANE_KEY -u ORCA_CLI_COMMAND -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID \
       -u CODEX_THREAD_ID SDP_PRECOMPACT_SELFTEST=1 SDP_PRECOMPACT_STATE_DIR="$SELFTEST_HOME/nopane" \
       python3 "$HOOK_CANONICAL" compact 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "compact declines when no pane is bound to this session" \
  || bad "compact claimed success with no pane binding (got: $out)"
case "$out" in
  *"no terminal driver bound"*) ok "the decline says why" ;;
  *) bad "the decline gives no reason (got: $out)" ;;
esac

# The driver executable is chosen by the driver's own rule, once, with no
# fall-through. The Linux branch is the reason this matters: outside a managed
# terminal a bare `orca` is the GNOME screen reader, and sending it terminal
# commands starts speech on the user's machine. This ships to other people.
python3 - <<'PY' && ok "the driver executable follows the documented resolver" || bad "driver resolution is wrong (see stderr)"
import importlib, os, sys, pathlib
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h

def resolve(env, platform):
    saved_env = {k: os.environ.get(k) for k in
                 ("ORCA_CLI_COMMAND", "ORCA_DEV_REPO_ROOT", "ORCA_PANE_KEY")}
    saved_plat = sys.platform
    for k in saved_env:
        os.environ.pop(k, None)
    os.environ.update({k: v for k, v in env.items()})
    sys.platform = platform
    try:
        return h.orca_bin()
    finally:
        sys.platform = saved_plat
        for k, v in saved_env.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v

cases = [
    ({"ORCA_CLI_COMMAND": "/opt/x/orca"}, "linux",  "/opt/x/orca"),
    ({"ORCA_DEV_REPO_ROOT": "/repo"},     "darwin", "orca-dev"),
    ({},                                  "linux",  "orca-ide"),   # no pane key
    ({"ORCA_PANE_KEY": "t:l"},            "linux",  "orca"),       # managed terminal
    ({},                                  "darwin", "orca"),
]
bad = [(e, p, resolve(e, p), w) for e, p, w in cases if resolve(e, p) != w]
for e, p, got, want in bad:
    sys.stderr.write("  env=%r platform=%s -> %r, want %r\n" % (e, p, got, want))
# the screen-reader path must be unreachable
if resolve({}, "linux") == "orca":
    sys.stderr.write("  Linux outside a managed terminal resolved to bare orca\n"); bad.append(1)
sys.exit(1 if bad else 0)
PY

# A pane key binds only when exactly one live terminal matches. Guessing types
# into somebody else's session, so there is no most-recently-active fallback.
python3 - <<'PY' && ok "a pane key is bound only when exactly one live terminal matches" || bad "pane matching is not exact"
import sys, pathlib
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
live = lambda tab, leaf, handle, connected=True: {
    "tabId": tab, "leafId": leaf, "handle": handle, "connected": connected}
rows = [live("tab-A", "leaf-A", "term_1"), live("tab-B", "leaf-B", "term_2"),
        live("tab-C", "leaf-C", "term_dead", False)]
cases = [
    (rows, "tab-A:leaf-A", "term_1"), (rows, "tab-X:leaf-X", ""), (rows, "tab-C:leaf-C", ""),
    (rows + [live("tab-A", "leaf-A", "term_1b")], "tab-A:leaf-A", ""),
    (rows, "", ""), (rows, "no-colon", ""), (rows, ":leaf", ""), (rows, "tab:", ""),
    ([], "tab-A:leaf-A", ""), (None, "tab-A:leaf-A", ""),
    ([live("tab-A", "l:with:colon", "term_x")], "tab-A:l:with:colon", "term_x"),
]
bad = [(k, h.match_handle(r, k), w) for r, k, w in cases if h.match_handle(r, k) != w]
for k, got, want in bad:
    sys.stderr.write("  %r -> %r, want %r\n" % (k, got, want))
sys.exit(1 if bad else 0)
PY

# Idle is asked of the driver, never inferred from the screen. The host draws a
# composer for the whole of a running turn, so an empty-looking input box is
# not evidence the agent stopped -- typing on it steers the turn in progress.
# Judged on the JSON, because a timeout is ok:false and the exit status is not
# a dependable stand-in for that across hosts.
python3 - <<'PY' && ok "idle is decided by the driver's wait condition, on its JSON" || bad "idle detection does not follow the wait contract"
import sys, pathlib
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
calls = []
def fake(args, timeout_sec=None):
    calls.append(args)
    fake.timeout_sec = timeout_sec
    return fake.reply
h._orca_json = fake
problems = []

fake.reply = {"ok": True, "result": {"wait": {"handle": "term_1", "condition": "tui-idle", "satisfied": True}}}
if h.wait_tui_idle("term_1") is not True:
    problems.append("a satisfied wait was not accepted")
if calls and ("--for" not in calls[-1] or "tui-idle" not in calls[-1]):
    problems.append("the wait did not ask for tui-idle: %r" % (calls[-1],))
# Without --json the CLI prints for humans and the parse yields nothing, so the
# session reads as permanently busy and nothing is ever typed.
if calls and "--json" not in calls[-1]:
    problems.append("the wait did not request JSON: %r" % (calls[-1],))
# The subprocess must outlive the wait the CLI was asked for, or a two-minute
# contract is capped at the default and reported as unreadable.
if (fake.timeout_sec or 0) <= h.INJECT_IDLE_TIMEOUT_MS / 1000.0:
    problems.append("subprocess timeout %r does not outlast the requested wait"
                    % (fake.timeout_sec,))
fake.reply = {"ok": True, "result": {}}
if h.wait_tui_idle("term_1") is not False:
    problems.append("a reply with no wait block was treated as idle")
fake.reply = {"ok": True, "result": {"wait": {"handle": "term_1", "condition": "exit", "satisfied": True}}}
if h.wait_tui_idle("term_1") is not False:
    problems.append("a different wait condition was treated as idle")
fake.reply = {"ok": True}
if h.wait_tui_idle("term_1") is not False:
    problems.append("a bare ok:true was treated as idle")
# A success naming a different terminal must not read as this pane being idle.
fake.reply = {"ok": True, "result": {"wait": {"handle": "term_other",
                                              "condition": "tui-idle", "satisfied": True}}}
if h.wait_tui_idle("term_1") is not False:
    problems.append("a success for another handle was treated as idle")

fake.reply = {"ok": False, "error": {"code": "timeout", "message": "timeout"}}
if h.wait_tui_idle("term_1") is not False:
    problems.append("a timeout was treated as idle")

fake.reply = {"ok": True, "result": {"wait": {"handle": "term_1", "satisfied": False}}}
if h.wait_tui_idle("term_1") is not False:
    problems.append("an unsatisfied wait was treated as idle")

fake.reply = None
if h.wait_tui_idle("term_1") is not False:
    problems.append("an unreadable reply was treated as idle")
if h.wait_tui_idle("") is not False:
    problems.append("an empty handle was treated as idle")
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# Nothing may be typed before the session is idle, and the handle must be
# re-resolved after the wait -- it rotates across a compaction, and the wait
# can last minutes.
python3 - <<'PY' && ok "the waiter sends only after idle, and re-resolves the handle first" || bad "the waiter send ordering is wrong"
import sys, pathlib
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
order = []
h.orca_bin = lambda: "orca"
h.resolve_handle = lambda pane: (order.append("resolve"), "term_1")[1]
h.send_text = lambda handle, text: (order.append("send:" + text), True)[1]
h.peek_self_fire_intent = lambda sid, nonce="": "tab:leaf"
h.clear_self_fire_intent = lambda sid, nonce="": None
problems = []

h.wait_tui_idle = lambda handle, timeout_ms=0: (order.append("wait"), True)[1]
order.clear(); h.cmd_inject(["tab:leaf", "/compact", "sid"])
if order != ["resolve", "wait", "resolve", "send:/compact"]:
    problems.append("ordering was %r" % (order,))

h.wait_tui_idle = lambda handle, timeout_ms=0: (order.append("wait"), False)[1]
order.clear(); h.cmd_inject(["tab:leaf", "/compact", "sid"])
if any(o.startswith("send") for o in order):
    problems.append("sent despite a busy session: %r" % (order,))

h.wait_tui_idle = lambda handle, timeout_ms=0: True
h.peek_self_fire_intent = lambda sid, nonce="": ""
order.clear(); h.cmd_inject(["tab:leaf", "/compact", "sid"])
if any(o.startswith("send") for o in order):
    problems.append("sent after the intent was consumed elsewhere: %r" % (order,))
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# Every give-up path in the compact waiter must release its own intent, and
# only its own: an intent that outlives its failed compaction stays live for
# minutes and fires a resume prompt at whatever the user compacts next.
python3 - <<'PY' && ok "a failed compaction waiter releases its own intent and no other" || bad "intent release on give-up is wrong"
import sys, pathlib
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
cleared = []
h.clear_self_fire_intent = lambda sid, nonce="": cleared.append((sid, nonce))
h.peek_self_fire_intent = lambda sid, nonce="": "tab:leaf"
h.send_text = lambda handle, text: True
problems = []

def run(label, **stubs):
    cleared.clear()
    h.orca_bin = stubs.get("orca_bin", lambda: "orca")
    h.resolve_handle = stubs.get("resolve_handle", lambda pane: "term_1")
    h.wait_tui_idle = stubs.get("wait_tui_idle", lambda handle, timeout_ms=0: True)
    h.send_text = stubs.get("send_text", lambda handle, text: True)
    h.cmd_inject(["tab:leaf", "/compact", "sid", "n1"])
    return label, list(cleared)

for label, got in [
    run("no driver", orca_bin=lambda: ""),
    run("handle gone", resolve_handle=lambda pane: ""),
    run("never idle", wait_tui_idle=lambda handle, timeout_ms=0: False),
    run("send failed", send_text=lambda handle, text: False),
]:
    if got != [("sid", "n1")]:
        problems.append("%s cleared %r, want [('sid','n1')]" % (label, got))
# a successful send leaves the intent standing for the resume path to consume
label, got = run("success")
if got:
    problems.append("a successful send cleared the intent: %r" % (got,))
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# The clear is nonce-scoped, so a late waiter cannot disarm a newer cycle.
python3 - <<'PY' && ok "a late waiter cannot clear a newer cycle's intent" || bad "intent clearing is not nonce-scoped"
import os, sys, pathlib, tempfile
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
home = pathlib.Path(h.win_compat.passwd_home())
tmp = pathlib.Path(tempfile.mkdtemp(dir=str(home / ".sdp")))
os.environ["SDP_PRECOMPACT_SELFTEST"] = "1"
os.environ["SDP_PRECOMPACT_STATE_DIR"] = str(tmp)
problems = []
new_nonce = h.set_self_fire_intent("s", "tab:leaf")
h.clear_self_fire_intent("s", "stale-nonce")
if h.peek_self_fire_intent("s", new_nonce) != "tab:leaf":
    problems.append("a stale nonce deleted the current intent")
h.clear_self_fire_intent("s", new_nonce)
if h.peek_self_fire_intent("s", new_nonce) != "":
    problems.append("the matching nonce did not clear the intent")
if h.peek_self_fire_intent("s", "other") != "":
    problems.append("a mismatched nonce was accepted")
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# A hand-run snapshot carries no session tag, so the command states which file
# it wrote. That path is trusted only as far as membership in this project's
# own enumerated snapshots -- a substring test on the path would accept
# /tmp/x.private/precompact-evil/a, and the enumeration is what already
# refuses symlinks and non-regular files.
python3 - <<'PY' && ok "a stated snapshot is accepted only if it is one of this project's own" || bad "snapshot path validation is not membership-based"
import os, sys, pathlib, tempfile, time
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
root = pathlib.Path(tempfile.mkdtemp())
day = root / ".private" / "precompact" / time.strftime("%Y%m%d")
day.mkdir(parents=True)
real = day / "precompact_x.md"; real.write_text("x")
problems = []
if h._verified_snapshot(str(real), str(root)) != str(real.resolve()):
    problems.append("a real snapshot was rejected")
decoy_dir = root / "x.private" / "precompact-evil"; decoy_dir.mkdir(parents=True)
decoy = decoy_dir / "precompact_a.md"; decoy.write_text("x")
if h._verified_snapshot(str(decoy), str(root)) != "":
    problems.append("a look-alike path outside the snapshot tree was accepted")
outside = root / "passwd"; outside.write_text("x")
if h._verified_snapshot(str(outside), str(root)) != "":
    problems.append("an arbitrary file was accepted")
link = day / "precompact_link.md"
try:
    link.symlink_to(outside)
    if h._verified_snapshot(str(link), str(root)) != "":
        problems.append("a symlinked snapshot was accepted")
except OSError:
    pass
if h._verified_snapshot("", str(root)) != "" or h._verified_snapshot(str(real), "") != "":
    problems.append("empty arguments were not refused")
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# Only a LIVE intent speaks for the compaction that is happening now. A stale
# sidecar would otherwise bind an old snapshot to a much later manual compact.
python3 - <<'PY' && ok "an expired intent does not bind its snapshot to a later compaction" || bad "a stale intent still binds"
import os, sys, pathlib, tempfile, time
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
home = pathlib.Path(h.win_compat.passwd_home())
state = pathlib.Path(tempfile.mkdtemp(dir=str(home / ".sdp")))
os.environ["SDP_PRECOMPACT_SELFTEST"] = "1"
os.environ["SDP_PRECOMPACT_STATE_DIR"] = str(state)
h._write_json(h.intent_path("s"), {"pane_key": "tab:leaf", "nonce": "n",
                                   "snapshot": "/tmp/old.md",
                                   "at": time.time() - h.SELF_FIRE_INTENT_TTL_SEC - 60})
sys.exit(0 if h.peek_self_fire_intent("s") == "" else 1)
PY

# The waiter has to outlive the hook that started it, and the mechanism is not
# portable. On POSIX the Windows branch never executes, so it is asserted
# directly rather than left to a platform that does not run here.
python3 - <<'PY' && ok "the detached spawn uses the right mechanism on each platform" || bad "detach keywords are wrong for a platform"
import sys, pathlib, subprocess
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
problems = []

posix = h.detach_kwargs("posix")
if posix != {"start_new_session": True}:
    problems.append("posix: %r" % (posix,))

win = h.detach_kwargs("nt")
if "start_new_session" in win:
    problems.append("windows passes start_new_session, which it ignores: %r" % (win,))
flags = win.get("creationflags")
if not isinstance(flags, int) or flags == 0:
    problems.append("windows creationflags missing or zero: %r" % (win,))
else:
    detached = getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
    newgroup = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
    if not flags & detached:
        problems.append("windows flags lack DETACHED_PROCESS")
    if not flags & newgroup:
        problems.append("windows flags lack CREATE_NEW_PROCESS_GROUP")
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# And the spawn actually passes them through to Popen.
python3 - <<'PY' && ok "the spawn hands the platform detach keywords to Popen" || bad "the spawn does not apply the detach keywords"
import sys, os, pathlib, subprocess
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
seen = {}
class FakePopen:
    def __init__(self, argv, **kw):
        seen["argv"] = argv; seen["kw"] = kw
h.subprocess.Popen = FakePopen
os.environ.pop("SDP_PRECOMPACT_SELFTEST", None)
os.environ.pop("SDP_PRECOMPACT_DRYRUN", None)
ok = h.spawn_inject("tab:leaf", "/compact", "sid", "n1")
problems = []
if not ok:
    problems.append("spawn reported failure")
kw = seen.get("kw", {})
want = h.detach_kwargs()
if any(kw.get(k) != v for k, v in want.items()):
    problems.append("detach kwargs not forwarded: %r want superset of %r" % (kw, want))
if kw.get("stdin") != subprocess.DEVNULL:
    problems.append("stdio not detached: %r" % (kw,))
argv = seen.get("argv", [])
if argv[2:] != ["inject", "tab:leaf", "/compact", "sid", "n1"]:
    problems.append("argv wrong: %r" % (argv,))
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# The tool cannot read the pane key from its own environment on every host, so
# a hook writes it down and the tool looks it up. Stale or absent bindings must
# refuse rather than resolve to where the session used to be.
python3 - <<'PY' && ok "pane bindings are session-scoped, fresh-checked, and fail closed" || bad "pane binding does not fail closed"
import os, sys, time, pathlib, tempfile
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
home = pathlib.Path(h.win_compat.passwd_home())
tmp = pathlib.Path(tempfile.mkdtemp(dir=str(home / ".sdp")))
os.environ["SDP_PRECOMPACT_SELFTEST"] = "1"
os.environ["SDP_PRECOMPACT_STATE_DIR"] = str(tmp)
problems = []
if h.bound_pane("nosuch") != "":
    problems.append("absent binding returned a pane")
os.environ["ORCA_PANE_KEY"] = "tab:leaf"
h.bind_pane("s1")
if h.bound_pane("s1") != "tab:leaf":
    problems.append("a fresh binding was not returned")
if h.bound_pane("s2") != "":
    problems.append("a binding leaked across session ids")
h._write_json(h.pane_path("s3"), {"pane_key": "tab:leaf",
                                  "at": time.time() - h.PANE_BINDING_MAX_AGE_SEC - 60})
if h.bound_pane("s3") != "":
    problems.append("a stale binding was accepted")
h._write_json(h.pane_path("s4"), {"pane_key": "tab:leaf", "at": time.time() + 9999})
if h.bound_pane("s4") != "":
    problems.append("a future-dated binding was accepted")
os.environ.pop("ORCA_PANE_KEY")
if h.bind_pane("s5") is not False:
    problems.append("binding succeeded with no pane key in the environment")
for p in problems:
    sys.stderr.write("  " + p + "\n")
sys.exit(1 if problems else 0)
PY

# The resume injection is keyed to THIS cycle asking for the compaction, not to
# the global mode. Bound to the mode it gets both halves wrong: an automatic
# compaction already continues the turn, so injecting adds a second one, while
# a hand-run command in manual mode gets no injection at all.
python3 - <<'PY' && ok "the self-fire intent is one-shot, pane-carrying and expiring" || bad "self-fire intent semantics are wrong"
import os, sys, time, pathlib, tempfile
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
home = pathlib.Path(h.win_compat.passwd_home())
tmp = pathlib.Path(tempfile.mkdtemp(dir=str(home / ".sdp")))
os.environ["SDP_PRECOMPACT_SELFTEST"] = "1"
os.environ["SDP_PRECOMPACT_STATE_DIR"] = str(tmp)
problems = []
if h.take_self_fire_intent("i0") != "":
    problems.append("an absent intent returned a pane")
h.set_self_fire_intent("i1", "tab:leaf")
if h.take_self_fire_intent("i1") != "tab:leaf":
    problems.append("the intent did not carry its pane")
if h.take_self_fire_intent("i1") != "":
    problems.append("the intent was not one-shot")
h._write_json(h.intent_path("i2"), {"pane_key": "tab:leaf",
                                    "at": time.time() - h.PANE_BINDING_MAX_AGE_SEC - 60})
if h.take_self_fire_intent("i2") != "":
    problems.append("a stale intent was accepted")
for p in problems:
    sys.stderr.write("  " + p + "\n")
sys.exit(1 if problems else 0)
PY

# The suite drives `resume` against real session ids. On a machine that has a
# terminal driver the pane key resolves to the terminal the suite is RUNNING
# IN, so an ungated injector types into the developer's own session mid-test.
# That is not hypothetical -- it happened while this feature was being written.
python3 - <<'PY' && ok "the injector refuses to spawn while the suite is running" || bad "the suite can spawn an injector into the developer's own terminal"
import os, sys, pathlib
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
os.environ["SDP_PRECOMPACT_SELFTEST"] = "1"
os.environ.pop("SDP_PRECOMPACT_DRYRUN", None)
sys.exit(0 if h.spawn_inject("tab:leaf", "text") is False else 1)
PY

# The resolved driver may be a command line, not a bare name, and a name that
# is not installed must refuse rather than fall through to another one.
python3 - <<'PY' && ok "the driver argv handles a command string and refuses a missing binary" || bad "driver argv handling is wrong"
import os, sys, pathlib
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
problems = []
os.environ["ORCA_CLI_COMMAND"] = "/bin/echo --flag"
argv = h.driver_argv(["terminal", "list"])
if argv != ["/bin/echo", "--flag", "terminal", "list"]:
    problems.append("command string not split into argv: %r" % (argv,))
# A Windows path has backslashes; POSIX splitting would eat them.
if os.name == "nt":
    os.environ["ORCA_CLI_COMMAND"] = r"C:\Tools\orca.exe --flag"
    argv = h.driver_argv(["x"])
    if argv[:2] != [r"C:\Tools\orca.exe", "--flag"] and argv != []:
        problems.append("windows path mangled: %r" % (argv,))
else:
    import shlex as _s
    got = [w[1:-1] if len(w) > 1 and w[0] == w[-1] == '"' else w
           for w in _s.split(r"C:\Tools\orca.exe --flag", posix=False)]
    if got != [r"C:\Tools\orca.exe", "--flag"]:
        problems.append("non-posix split would mangle a windows path: %r" % (got,))
os.environ["ORCA_CLI_COMMAND"] = "/nonexistent/driver"
if h.driver_argv(["x"]) != []:
    problems.append("a missing binary did not refuse")
if h.send_text("term_1", "text") is not False:
    problems.append("send_text did not refuse a missing binary")
os.environ.pop("ORCA_CLI_COMMAND")
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# Sidecars are not markers. doctor listing them as pending snapshot requests
# is a false alarm, and a prune that skips them leaks one file per session.
python3 - <<'PY' && ok "sidecar records are excluded from markers and reached by the prune" || bad "sidecar handling is wrong"
import os, sys, time, pathlib, tempfile
sys.path.insert(0, str(pathlib.Path("plugins/sdp/scripts").resolve()))
import precompact_hook as h
home = pathlib.Path(h.win_compat.passwd_home())
tmp = pathlib.Path(tempfile.mkdtemp(dir=str(home / ".sdp")))
os.environ["SDP_PRECOMPACT_SELFTEST"] = "1"
os.environ["SDP_PRECOMPACT_STATE_DIR"] = str(tmp)
problems = []
for suffix in h.SIDECAR_SUFFIXES:
    if not suffix.endswith(".json"):
        problems.append("sidecar suffix %r is not a .json" % suffix)
old = time.time() - h.WINDOW_PRUNE_SEC - 60
for name in ("s.window.json", "s.pane.json", "s.selffire.json"):
    f = tmp / name
    h._write_json(f, {"x": 1})
    os.utime(f, (old, old))
h._write_json(tmp / "s.json", {"state": "pending", "at": time.time()})
h._prune_windows()
left = sorted(p.name for p in tmp.iterdir())
if left != ["s.json"]:
    problems.append("prune left %r; only the real marker should remain" % (left,))
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

# The command must carry the queue step, or the model never calls it.
# EVERY shipped copy, including the two that are hand-maintained rather than
# generated. Those two are the ones Codex actually reads, and a round that
# updated only the generated four left them describing the old, non-queueing
# flow while the suite stayed green -- which is exactly how this was missed.
for f in commands/precompact.md plugins/sdp/commands/precompact.md \
         skills/precompact/SKILL.md plugins/sdp/skills/precompact/SKILL.md \
         .agents/skills/precompact/SKILL.md .codex/prompts/precompact.md; do
  grep -qF 'precompact_hook.py" compact' "$f" \
    && ok "$f tells the command to queue the compaction" \
    || bad "$f omits the compact step"
  grep -qF 'compact "<snapshot path>"' "$f" \
    && ok "$f passes the snapshot path explicitly" \
    || bad "$f does not pass the snapshot path, so the binding is not deterministic"
  grep -qF 'queued, not submitted' "$f" \
    && ok "$f says exit 0 means queued, not submitted" \
    || bad "$f implies the compaction was already submitted"
  grep -qF 'walk UP its ancestors' "$f" \
    && ok "$f locates the plugin by walking up from its own path" \
    || bad "$f does not describe the ancestor walk"
  # Guessing a cache version picks the wrong host's copy on one host, and a
  # version this session never loaded on the other.
  grep -qF 'Do not pick a version out of the install cache' "$f" \
    && ok "$f forbids guessing a version out of the install cache" \
    || bad "$f does not forbid guessing a cache version"
  # CLAUDE_PLUGIN_ROOT is a hook variable. Measured absent from ordinary tool
  # calls on BOTH hosts, where it expands to nothing and the path becomes
  # /scripts/... -- so the step must not depend on it.
  grep -q 'CLAUDE_PLUGIN_ROOT}/scripts/precompact_hook.py" compact' "$f" \
    && bad "$f invokes the hook through CLAUDE_PLUGIN_ROOT, which tools do not have" \
    || ok "$f does not depend on CLAUDE_PLUGIN_ROOT for the tool call"
done

# The documented rule has to hold for every place this file ships, which is
# why it is a walk and not a fixed depth: the copies sit at four different
# depths and the installed cache adds a fifth.
python3 - <<'PY' && ok "every shipped command and skill copy resolves the plugin by the ancestor walk" || bad "a shipped copy cannot locate scripts/precompact_hook.py by walking up"
import pathlib, sys
copies = [
    "plugins/sdp/commands/precompact.md", "plugins/sdp/skills/precompact/SKILL.md",
    "commands/precompact.md", "skills/precompact/SKILL.md",
    ".agents/skills/precompact/SKILL.md", ".codex/prompts/precompact.md",
]
problems = []
for rel in copies:
    src = pathlib.Path(rel).resolve()
    if not src.is_file():
        problems.append("%s is missing" % rel); continue
    hit = next((a for a in src.parents if (a / "scripts" / "precompact_hook.py").is_file()), None)
    if hit is None:
        problems.append("%s: no ancestor has scripts/precompact_hook.py" % rel)
for m in problems:
    sys.stderr.write("  " + m + "\n")
sys.exit(1 if problems else 0)
PY

grep -qF 'Do not retry, and never guess a terminal.' plugins/sdp/commands/precompact.md \
  && ok "the command forbids retrying or guessing a terminal" \
  || bad "the command does not forbid guessing a terminal"

# The bind hook has to be registered on BOTH hosts, or the tool has no pane to
# look up on the host whose tool environment omits it.
python3 - <<'PY' && ok "both host manifests keep three hooks with the same three verbs" || bad "a host manifest drifted from the three-verb contract"
import json, sys
want = ["precompact", "start", "stop"]
for f in ("plugins/sdp/hooks/hooks.json", "plugins/sdp/hooks/hooks.codex.json"):
    d = json.load(open(f))["hooks"]
    verbs = sorted(hk["command"].rsplit(" ", 1)[-1]
                   for es in d.values() for e in es for hk in e["hooks"])
    if verbs != want:
        sys.stderr.write("  %s verbs %r, want %r\n" % (f, verbs, want)); sys.exit(1)
sys.exit(0)
PY

# ------------------------------------------------------------ config set --

# Reporting a saved mode that was not saved is how someone ends up believing
# the automation is armed while nothing is.
# The real ~/.sdp/precompact.json must be untouched by this case. An earlier
# revision of it wrote there for real and silently armed the developer's own
# machine, so its state is captured and asserted rather than assumed.
REAL_CFG="$(python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)')/.sdp/precompact.json"
REAL_CFG_BEFORE="absent"; [ -f "$REAL_CFG" ] && REAL_CFG_BEFORE="$(cat "$REAL_CFG")"
CFGGUARD="$SELFTEST_HOME/cfgguard"; mkdir -p "$CFGGUARD"
printf 'not a directory\n' > "$CFGGUARD/blocked"
if SDP_PRECOMPACT_SELFTEST=1 SDP_PRECOMPACT_STATE_DIR="$CFGGUARD/blocked" \
   SDP_PRECOMPACT_HOME="$CFGGUARD/blocked" python3 "$HOOK_CANONICAL" config set auto >/dev/null 2>&1; then
  bad "config set reported success although the mode could not be saved"
else
  ok "config set fails loudly when the mode cannot be saved"
fi
REAL_CFG_AFTER="absent"; [ -f "$REAL_CFG" ] && REAL_CFG_AFTER="$(cat "$REAL_CFG")"
[ "$REAL_CFG_BEFORE" = "$REAL_CFG_AFTER" ] \
  && ok "the failing config-set case never touches the real config file" \
  || bad "config set wrote the real ~/.sdp/precompact.json (fixture escaped the seam)"

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

# ------------------------------------------------------------ doc semantics --

# Codex supports Stop, PreCompact and SessionStart(compact) and auto-loads a
# plugin's hooks/hooks.json (codex-cli 0.149.1, feature `hooks` stable). The
# earlier claim that it did not was wrong, and it is the kind of statement that
# quietly stops people enabling the thing.
for f in commands/precompact.md plugins/sdp/commands/precompact.md \
         skills/precompact/SKILL.md plugins/sdp/skills/precompact/SKILL.md \
         .agents/skills/precompact/SKILL.md .codex/prompts/precompact.md \
         COMMAND_MANUAL.md COMMAND_MANUAL.ko.md; do
  if grep -qiE "Codex does not expose|Codex는 이 라이프사이클 훅을 제공하지 않" "$f"; then
    bad "$f still claims Codex has no lifecycle hooks"
  else
    ok "$f does not claim Codex lacks lifecycle hooks"
  fi
done

# Codex skips a plugin's hooks until they are trusted, so a reader who is told
# the automation works but not that it must be trusted is left with a silently
# inert install -- the exact failure this feature was written to end.
for f in .codex/prompts/precompact.md COMMAND_MANUAL.md; do
  grep -qF '/hooks' "$f" && ok "$f names the Codex trust step" || bad "$f omits the Codex trust step"
done
grep -qF '/hooks' COMMAND_MANUAL.ko.md && ok "COMMAND_MANUAL.ko.md names the Codex trust step" \
  || bad "COMMAND_MANUAL.ko.md omits the Codex trust step"

# The Codex measurement reads last_token_usage, never the cumulative bill.
# Saying so in the shipped docs is what stops the next reader "fixing" it.
grep -qF 'last_token_usage' COMMAND_MANUAL.md && ok "COMMAND_MANUAL.md names the Codex usage field" \
  || bad "COMMAND_MANUAL.md does not say which Codex field is read"
grep -qF 'total_token_usage' COMMAND_MANUAL.md && ok "COMMAND_MANUAL.md warns off the cumulative field" \
  || bad "COMMAND_MANUAL.md does not warn off total_token_usage"

# The pairing rule is the difference between measuring 81% and measuring 21%,
# so the docs must state it rather than implying the window is a session-wide
# constant.
for f in COMMAND_MANUAL.md .codex/prompts/precompact.md; do
  grep -qi 'newest' "$f" \
    && ok "$f says the usage and window come from the same newest event" \
    || bad "$f does not state the usage/window pairing rule"
done
grep -q '가장 최근' COMMAND_MANUAL.ko.md \
  && ok "COMMAND_MANUAL.ko.md states the usage/window pairing rule" \
  || bad "COMMAND_MANUAL.ko.md does not state the usage/window pairing rule"

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
