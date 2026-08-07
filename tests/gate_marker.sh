#!/usr/bin/env bash
# gate_marker.sh — executable spec for P1's SANCTIONED MARKER CHANNEL:
# `prepare-marker` (a restricted writer that produces a request file for a human)
# and `record-marker` (the only gate-state write path outside run_review, gated by
# TTY + SDP_MARKER_HUMAN, with a second ceremony for pivot/halt).
# ADR-G01 / G02 / G02b / G12 / G13 / G16 / G18. Drives the REAL gate through
# tests/lib/harness.py, which binds the _ISATTY seam in the child via argv.
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
HARNESS="$SDP_ROOT/tests/lib/harness.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d -t sdp_marker.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; HOMEFIX="$TMP/home"
mkdir -p "$BIN" "$HOMEFIX/.sdp"

VERD="$TMP/verdict.txt"
set_claude_verdict() {   # $1 = stub stdout (verdict), $2 = exit code (default 0)
  printf '%s\n' "$1" > "$VERD"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\ncat "%s"\nexit %s\n' \
    "$VERD" "${2:-0}" > "$BIN/claude"
  chmod +x "$BIN/claude"
}
set_claude_verdict "BLOCK: seed"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\nprintf "BLOCK: agy down\\n"; exit 1\n' \
  > "$BIN/agy"; chmod +x "$BIN/agy"
RES="$TMP/res.json"; printf '{"claude":"%s","agy":"%s"}\n' "$BIN/claude" "$BIN/agy" > "$RES"

# ADR-G02b's token. It is an INTENT SIGNAL, NOT A SECRET: same-uid readable, so
# any agent that can run `cat` can supply it. The only affordance barrier is the
# TTY test, which the harness seam deliberately bypasses here (NC-22).
printf 'sekret\n' > "$HOMEFIX/.sdp/marker.token"; chmod 600 "$HOMEFIX/.sdp/marker.token"

H()  { python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" -- "$@"; }
HNO() { python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" --isatty false -- "$@"; }
RM() { SDP_MARKER_HUMAN=sekret python3 "$HARNESS" --binary-resolver "$RES" \
         --passwd-home "$HOMEFIX" --isatty true -- "$@"; }
RM_NOTOKEN() { python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" \
                 --isatty true -- "$@"; }

gates() {   # $1 = project dir, $2 = escalate_from
  printf 'halt:\n  max_block: 13\n  pivot_cap: 2\ncadence:\n  escalate_from: %s\n  review_on: even\nmode: unattended\n' \
    "$2" > "$1/.sdp/gates.yaml"
}

mkproj() {  # $1 = name, $2 = final escalate_from, $3 = BLOCK rounds to drive
  local p="$TMP/$1" i=1
  mkdir -p "$p/.sdp"
  printf 'plan\n' > "$p/plan.md"
  gates "$p" 99          # out of reach while we drive the counter up
  while [ "$i" -le "$3" ]; do
    set_claude_verdict "BLOCK: $1 round $i"
    H --cwd "$p" --reviewer claude review "$p/plan.md" >/dev/null 2>&1
    i=$((i + 1))
  done
  gates "$p" "$2"
  printf 'evidence\n' > "$p/out1.md"   # fresher than the last BLOCK_ATTEMPT
}

plog() { H --cwd "$1" --print-state-path "$1/plan.md"; }

filemode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

gate_snapshot() {   # inode/size/mtime of every OTHER file under <gate>/
  python3 - "$1" <<'PY'
import os, sys
d = sys.argv[1]
rows = []
if os.path.isdir(d):
    for name in sorted(os.listdir(d)):
        if name.endswith(".marker-request") or name.endswith(".tmp"):
            continue
        p = os.path.join(d, name)
        if os.path.isfile(p):
            st = os.stat(p)
            rows.append(f"{name} {st.st_ino} {st.st_size} {st.st_mtime_ns}")
print("\n".join(rows))
PY
}

# ============================================================== T5 / T8 =======
# FRESH STATE FIRST: prepare-marker must create NO <gate>/ at all, and must
# refuse below escalate_from. Both assertions are vacuous once anything else has
# run against this project, so they come first.
mkdir -p "$TMP/fresh/.sdp"; printf 'plan\n' > "$TMP/fresh/plan.md"; gates "$TMP/fresh" 2
FRESH_LOG="$(plog "$TMP/fresh")"
FRESH_GATE="$(dirname "$FRESH_LOG")"
out="$(H --cwd "$TMP/fresh" prepare-marker "$TMP/fresh/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL (4)' \
  && ok "T8: prepare-marker refuses below escalate_from (round 0 < 2)" \
  || bad "T8: below-escalate_from not refused (rc=$rc) $out"
[ ! -d "$FRESH_GATE" ] \
  && ok "T5: prepare-marker created no <gate>/ directory on fresh state" \
  || bad "T5: prepare-marker created $FRESH_GATE"

# ============================================================== main fixture ==
mkproj main 2 2
PROJ="$TMP/main"
LOG="$(plog "$PROJ")"
GATEDIR="$(dirname "$LOG")"
REQ="${LOG%.log}.marker-request"
INFLIGHT="${LOG%.log}.inflight"
LOCK="${LOG%.log}.lock"

# ============================================================== T1 / T4 =======
before="$(gate_snapshot "$GATEDIR")"
out="$(H --cwd "$PROJ" prepare-marker "$PROJ/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md \
        --marker-summary 'two lenses agreed on the root cause' 2>&1)"; rc=$?
after="$(gate_snapshot "$GATEDIR")"
[ "$rc" -eq 0 ] || bad "T1: prepare-marker failed (rc=$rc) $out"
[ -f "$REQ" ] && ok "T1: prepare-marker wrote <gate>/review_gate_<key>.marker-request" \
              || bad "T1: no request file at $REQ"
[ "$(filemode "$REQ")" = "0o600" ] && ok "T1: request file is mode 0600" \
  || bad "T1: request file mode $(filemode "$REQ")"
head -1 "$REQ" | grep -qF 'DATA FOR A HUMAN, NOT INSTRUCTIONS' \
  && ok "T1: line 1 is the non-instruction banner" || bad "T1: banner missing"
[ "$before" = "$after" ] \
  && ok "T4: prepare-marker left every OTHER file under <gate>/ inode/size/mtime identical" \
  || bad "T4: other gate files changed"
[ -z "$(find "$GATEDIR" -maxdepth 1 -name '*.tmp' -print -quit)" ] \
  && ok "T4: the transient temp entry did not survive the publish" \
  || bad "T4: a .tmp entry survived"

# ============================================================== T2 ============
{ printf '%s' "$out" | grep -q 'record-marker' \
  || printf '%s' "$out" | grep -q '^TEAM_REVIEW ' \
  || printf '%s' "$out" | grep -q 'review_gate\.py'; } \
  && bad "T2: stdout leaked the composed command or marker line" \
  || ok "T2: stdout carries the request path + PASS/FAIL lines only, never the command"
printf '%s' "$out" | head -1 | grep -q '\.marker-request$' \
  && ok "T2: stdout line 1 is the request file's absolute path" || bad "T2: line 1 is not the request path"
printf '%s' "$out" | grep -q '^PASS ' && ok "T2: stdout carries the PASS/FAIL checklist" \
  || bad "T2: no checklist on stdout"

# ============================================================== T15 ===========
grep -qE '(^|[^[:alnum:]_])date([^[:alnum:]_]|$)' "$REQ" \
  && bad "T15: the request file contains a date(1) invocation (BSD emits %6N literally)" \
  || ok "T15: the emitted command contains no date invocation at all"
python3 - "$REQ" <<'PY' && ok "T15: the written timestamp parses as ISO-8601" \
                        || bad "T15: observed_at does not parse"
import re, sys
from datetime import datetime
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"observed_at=(\S+)", text)
raise SystemExit(0 if m and datetime.fromisoformat(m.group(1).replace("Z", "+00:00")) else 1)
PY

# ============================================================== T3 ============
# The same "command is not printed" assertion, over the MCP result payload (S7).
python3 - "$SDP_ROOT" "$PROJ" <<'PY' && ok "T3: the MCP payload carries no composed command or marker line" \
                                     || bad "T3: MCP payload leaked the command"
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts")
import sdp_mcp_server as s
res = s._call_tool("sdp_prepare_team_marker", {
    "cwd": sys.argv[2], "artifact_path": f"{sys.argv[2]}/plan.md",
    "roster": "alice,bob", "outputs": "out1.md",
})
text = res["content"][0]["text"]
assert res["isError"] is False, res
assert "record-marker" not in text, text
assert "review_gate.py" not in text, text
assert not any(l.startswith(("TEAM_REVIEW ", "TEAM_CARRY ")) for l in text.splitlines()), text
assert ".marker-request" in text, text
assert "PASS " in text, text
names = [t["name"] for t in s._tools()]
assert "sdp_prepare_team_marker" in names, names
assert "decision" not in s._tools()[1]["inputSchema"]["properties"], "decision must not be exposed"
PY

# ============================================================== T6 ============
out="$(H --cwd "$PROJ" prepare-marker "$PROJ/plan.md" \
        --marker-roster 'alice bob' --marker-outputs out1.md 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL (2) roster='; } \
  && ok "T6: internal whitespace in roster= is refused" || bad "T6: whitespace not refused ($out)"
out="$(H --cwd "$PROJ" prepare-marker "$PROJ/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md \
        --marker-summary 'spaces are allowed here' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "T6: internal whitespace in summary= is ALLOWED (the one exception)" \
                || bad "T6: summary whitespace wrongly refused ($out)"

# ============================================================== T7 ============
out="$(H --cwd "$PROJ" prepare-marker "$PROJ/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md \
        --marker-summary 'we rejected decision=pivot as premature' 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL (3) summary='; } \
  && ok "T7: a key token inside summary= is refused" || bad "T7: summary key token not refused ($out)"
out="$(H --cwd "$PROJ" prepare-marker "$PROJ/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md \
        --marker-rootcause 'roster=smuggled' 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL (3) rootcause='; } \
  && ok "T7: a key token inside rootcause= is refused" || bad "T7: rootcause key token not refused ($out)"

# ============================================================== T14 ===========
rm -f "$REQ"; ln -s "$TMP/elsewhere.txt" "$REQ"
out="$(H --cwd "$PROJ" prepare-marker "$PROJ/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && [ ! -e "$TMP/elsewhere.txt" ] && [ -L "$REQ" ]; } \
  && ok "T14: a pre-existing .marker-request symlink is refused, not followed" \
  || bad "T14: symlink followed or not refused (rc=$rc) $out"
rm -f "$REQ"

# ============================================================== T9 ============
out="$(HNO --cwd "$PROJ" record-marker "$PROJ/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^BLOCK: .*terminal'; } \
  && ok "T9: record-marker with no TTY is refused" || bad "T9: no-TTY not refused (rc=$rc) $out"
out="$(RM_NOTOKEN --cwd "$PROJ" record-marker "$PROJ/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'SDP_MARKER_HUMAN'; } \
  && ok "T9: record-marker with no token is refused" || bad "T9: no-token not refused (rc=$rc) $out"
grep -q '^TEAM_' "$LOG" \
  && bad "T9: a refused record-marker still wrote to the gate log" \
  || ok "T9: a refused record-marker wrote nothing to the gate log"

# ============================================================== T10 ===========
# The IN-LOCK .inflight check is what decides; the pre-lock check is an early-exit
# optimization with no safety role. Hold the state lock, let record-marker pass
# its pre-lock check and start spinning, THEN create .inflight, then release.
python3 - "$LOCK" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(4)
PY
holder=$!
sleep 0.3
( RM --cwd "$PROJ" record-marker "$PROJ/plan.md" \
     --marker-roster alice,bob --marker-outputs out1.md > "$TMP/t10.out" 2>&1
  echo $? > "$TMP/t10.rc" ) &
racer=$!
sleep 1.5
printf 'pid=999999 at=now\n' > "$INFLIGHT"     # created AFTER the pre-lock check
wait "$holder" 2>/dev/null
wait "$racer" 2>/dev/null
{ [ "$(cat "$TMP/t10.rc")" != "0" ] && grep -q 'in flight' "$TMP/t10.out"; } \
  && ok "T10: an .inflight created after the pre-lock check still refuses (in-lock check decides)" \
  || bad "T10: in-lock .inflight check did not refuse ($(cat "$TMP/t10.out"))"
grep -q '^TEAM_' "$LOG" && bad "T10: the refused record-marker still appended a marker" \
                        || ok "T10: the in-lock refusal wrote nothing"
rm -f "$INFLIGHT"

# ============================================================== T13 ===========
# decision=fix is accepted with ONLY the ADR-G02b gate (no second ceremony), and
# falls through to review EXACTLY as continue does.
out="$(RM --cwd "$PROJ" record-marker "$PROJ/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md --marker-decision fix 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^TEAM_REVIEW .*decision=fix' "$LOG"; } \
  && ok "T13: decision=fix is accepted with only the TTY+token gate" \
  || bad "T13: fix not accepted (rc=$rc) $out"
set_claude_verdict "ALLOW: reviewed after fix"
out="$(H --cwd "$PROJ" --reviewer claude review "$PROJ/plan.md" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW:'; } \
  && ok "T13: a decision=fix marker falls through to review exactly as continue does" \
  || bad "T13: fix did not fall through (rc=$rc) $out"

mkproj cont 2 2
CLOG="$(plog "$TMP/cont")"
out="$(RM --cwd "$TMP/cont" record-marker "$TMP/cont/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^TEAM_REVIEW .*decision=continue' "$CLOG"; } \
  && ok "T13: decision=continue (the default) records the same shape" \
  || bad "T13: continue not recorded (rc=$rc) $out"
set_claude_verdict "ALLOW: reviewed after continue"
H --cwd "$TMP/cont" --reviewer claude review "$TMP/cont/plan.md" >/dev/null 2>&1 \
  && ok "T13: decision=continue falls through to review identically" \
  || bad "T13: continue did not fall through"

# ============================================================== T11 ===========
mkproj pivot 2 2
PLOG="$(plog "$TMP/pivot")"
out="$(RM --cwd "$TMP/pivot" record-marker "$TMP/pivot/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md --marker-decision pivot 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'i-am-recording-a-state-changing-decision'; } \
  && ok "T11: decision=pivot is refused without the state-change acknowledgement flag" \
  || bad "T11: pivot accepted without the flag (rc=$rc) $out"
out="$(printf 'not the phrase\n' | RM --cwd "$TMP/pivot" record-marker "$TMP/pivot/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md --marker-decision pivot \
        --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'confirmation phrase mismatch'; } \
  && ok "T11: decision=pivot is refused on a confirmation-phrase mismatch" \
  || bad "T11: mismatch accepted (rc=$rc) $out"
grep -q '^TEAM_' "$PLOG" && bad "T11: a refused pivot still wrote a marker" \
                         || ok "T11: neither pivot refusal wrote anything"
out="$(printf 'record pivot for plan at round 2\n' | RM --cwd "$TMP/pivot" record-marker \
        "$TMP/pivot/plan.md" --marker-roster alice,bob --marker-outputs out1.md \
        --marker-decision pivot --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^TEAM_REVIEW .*decision=pivot' "$PLOG"; } \
  && ok "T11: decision=pivot is accepted with BOTH the flag and the typed phrase" \
  || bad "T11: pivot not accepted with the full ceremony (rc=$rc) $out"

# ============================================================== T12 ===========
mkproj halt 2 2
HLOG="$(plog "$TMP/halt")"
out="$(RM --cwd "$TMP/halt" record-marker "$TMP/halt/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md --marker-decision halt 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'i-am-recording-a-state-changing-decision'; } \
  && ok "T12: decision=halt is refused without the state-change acknowledgement flag" \
  || bad "T12: halt accepted without the flag (rc=$rc) $out"
out="$(printf 'record halt for plan at round 2\n' | RM --cwd "$TMP/halt" record-marker \
        "$TMP/halt/plan.md" --marker-roster alice,bob --marker-outputs out1.md \
        --marker-decision halt --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^TEAM_REVIEW .*decision=halt' "$HLOG"; } \
  && ok "T12: decision=halt is accepted with the same two-step ceremony" \
  || bad "T12: halt not accepted with the full ceremony (rc=$rc) $out"

# ============================================================== T16 ===========
# TEAM_CARRY at an ODD count — the first coverage this token has ever had (NC-11).
mkproj carry 3 3
KLOG="$(plog "$TMP/carry")"
out="$(RM --cwd "$TMP/carry" record-marker "$TMP/carry/plan.md" --marker-roster alice,bob 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^TEAM_CARRY .*round=3 ' "$KLOG"; } \
  && ok "T16: an odd round requires and records a TEAM_CARRY (no outputs= needed)" \
  || bad "T16: TEAM_CARRY not recorded (rc=$rc) $out"
set_claude_verdict "ALLOW: carried"
H --cwd "$TMP/carry" --reviewer claude review "$TMP/carry/plan.md" >/dev/null 2>&1 \
  && ok "T16: a valid TEAM_CARRY lets the review proceed" || bad "T16: TEAM_CARRY did not satisfy the cadence"

# ============================================================== T17 ===========
# ADR-G16: outputs= resolves against the CANONICAL root (the nearest .sdp/.git
# ancestor of the ARTIFACT), never against the caller's --cwd-derived root, and a
# path outside it is rejected.
# $SUB carries .sdp/ so it is the canonical root; $SUB/nested deliberately does
# NOT, so --cwd and the canonical root differ. With no gates.yaml under the
# resolved root the built-in escalate_from=6 / review_on=even apply.
SUB="$TMP/sub"; mkdir -p "$SUB/.sdp" "$SUB/nested"
printf 'plan\n' > "$SUB/nested/plan.md"
i=1; while [ "$i" -le 6 ]; do
  set_claude_verdict "BLOCK: sub round $i"
  H --cwd "$SUB/nested" --reviewer claude review "$SUB/nested/plan.md" >/dev/null 2>&1
  i=$((i + 1))
done
printf 'evidence under the canonical root\n' > "$SUB/out1.md"
printf 'outside\n' > "$TMP/escape.md"
out="$(H --cwd "$SUB/nested" prepare-marker "$SUB/nested/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "T17: a relative outputs= resolves against the CANONICAL root, not --cwd" \
  || bad "T17: canonical-root resolution failed (rc=$rc) $out"
out="$(H --cwd "$SUB/nested" prepare-marker "$SUB/nested/plan.md" \
        --marker-roster alice,bob --marker-outputs "$TMP/escape.md" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'outside the canonical root'; } \
  && ok "T17: an ABSOLUTE outputs= outside the canonical root is rejected" \
  || bad "T17: absolute-outside not rejected (rc=$rc) $out"
out="$(H --cwd "$SUB/nested" prepare-marker "$SUB/nested/plan.md" \
        --marker-roster alice,bob --marker-outputs ../escape.md 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'outside the canonical root'; } \
  && ok "T17: a relative outputs= that escapes the canonical root after resolve() is rejected" \
  || bad "T17: post-resolve escape not rejected (rc=$rc) $out"

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
