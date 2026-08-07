#!/usr/bin/env bash
# concurrency.sh — REWRITTEN for review_gate.py's fcntl.flock state layer (its
# old subject, codex-gate.sh's THREAD_FILE + mkdir/TTL/steal lock, is deleted).
#   C1  atomic primitive  — N parallel mkdir on one dir -> exactly 1 winner
#                           (bare primitive; the only property that survived)
#   C2  no missed max_block/no duplicate round — two REAL gates on ONE artifact,
#                           in parallel: each appends exactly one BLOCK_ATTEMPT,
#                           round ordinals are unique, counter is consistent
#   C3  kernel release    — a flock holder that is SIGKILLed releases immediately;
#                           the next acquirer proceeds (no TTL, no steal, no hang)
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
HARNESS="$SDP_ROOT/tests/lib/harness.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
TMP="$(mktemp -d -t sdp_conc.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

# ---- C1: bare mkdir atomicity (N parallel -> 1 winner) ----------------------
D="$TMP/lockdir"; WINS="$TMP/wins"; : > "$WINS"
for _ in 1 2 3 4 5 6 7 8; do ( mkdir "$D" 2>/dev/null && echo win >> "$WINS" ) & done
wait
w="$(wc -l < "$WINS" | tr -d ' ')"
[ "$w" -eq 1 ] && ok "C1: N parallel mkdir -> exactly 1 winner" || bad "C1: $w winners (want 1)"

# ---- C2: two concurrent gates on ONE artifact -------------------------------
PROJ="$TMP/proj"; BIN="$TMP/bin"; HOMEFIX="$TMP/home"
mkdir -p "$PROJ/.sdp" "$BIN" "$HOMEFIX/.sdp"
printf 'plan\n' > "$PROJ/plan.md"
printf 'halt:\n  max_block: 13\n' > "$PROJ/.sdp/gates.yaml"
# A slow-ish BLOCK stub so the two gates genuinely overlap on the KEY.
printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\nsleep 0.3\nprintf "BLOCK: no\\n"\n' > "$BIN/claude"; chmod +x "$BIN/claude"
printf '#!/usr/bin/env bash\nprintf "BLOCK: no\\n"; exit 1\n' > "$BIN/agy"; chmod +x "$BIN/agy"
RES="$TMP/res.json"; printf '{"claude":"%s","agy":"%s"}\n' "$BIN/claude" "$BIN/agy" > "$RES"
GATE() { python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" -- --cwd "$PROJ" --reviewer claude review "$PROJ/plan.md"; }
LOG="$(python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" -- --cwd "$PROJ" --print-state-path "$PROJ/plan.md")"

GATE >/dev/null 2>&1 & p1=$!
GATE >/dev/null 2>&1 & p2=$!
wait "$p1"; wait "$p2"
attempts="$(grep -c '^BLOCK_ATTEMPT ' "$LOG")"
ordinals="$(awk '/^BLOCK_ATTEMPT /{print $2}' "$LOG" | sort -n | tr '\n' ' ')"
uniq_ord="$(awk '/^BLOCK_ATTEMPT /{print $2}' "$LOG" | sort -n | uniq | wc -l | tr -d ' ')"
[ "$attempts" -eq 2 ] && ok "C2: two concurrent gates appended exactly 2 BLOCK_ATTEMPTs" || bad "C2: $attempts attempts (want 2)"
{ [ "$uniq_ord" -eq 2 ] && [ "$ordinals" = "1 2 " ]; } \
  && ok "C2: round ordinals are unique and consecutive (1 2), no duplicate/missed" \
  || bad "C2: ordinals '$ordinals' (want '1 2 ')"

# ---- C3: fcntl.flock releases on SIGKILL (no TTL, no steal, no hang) ---------
LK="$TMP/klock"
python3 - "$LK" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(30)
PY
holder=$!
sleep 0.5
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
# The next acquirer must get the lock immediately (kernel released it on death).
if python3 - "$LK" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)   # would raise if still held
    raise SystemExit(0)
except OSError:
    raise SystemExit(1)
PY
then ok "C3: flock released on holder SIGKILL; next acquirer proceeds immediately"
else bad "C3: lock still held after holder death (no kernel release)"; fi

# ---- T33: record_marker is a NEW holder of _state_lock ----------------------
# D-15, decided in design rev 15: SERIALIZE-AND-BOTH-SUCCEED. _state_lock is a
# non-blocking flock that SPINS to a deadline, so the second invocation waits,
# acquires and succeeds -- it does NOT raise. Both TEAM_* lines land, both are
# counter-neutral, and _parse_log keeps the LAST one, so the second marker wins.
# That is deliberate: a human who mistypes --marker-roster and re-runs relies on
# last-wins, and refusing the second would push them back to a raw log append.
P2="$TMP/marker"; B2="$TMP/mbin"; H2="$TMP/mhome"; V2="$TMP/mverdict.txt"
mkdir -p "$P2/.sdp" "$B2" "$H2/.sdp"
printf 'plan\n' > "$P2/plan.md"
printf 'sekret\n' > "$H2/.sdp/marker.token"; chmod 600 "$H2/.sdp/marker.token"
mstub() {
  printf '%s\n' "$1" > "$V2"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\ncat "%s"\n' "$V2" > "$B2/claude"
  chmod +x "$B2/claude"
}
printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\nprintf "BLOCK: agy down\\n"; exit 1\n' > "$B2/agy"; chmod +x "$B2/agy"
R2="$TMP/mres.json"; printf '{"claude":"%s","agy":"%s"}\n' "$B2/claude" "$B2/agy" > "$R2"
mgates() { printf 'halt:\n  max_block: 13\ncadence:\n  escalate_from: %s\n  review_on: even\nmode: unattended\n' "$1" > "$P2/.sdp/gates.yaml"; }
MH()  { python3 "$HARNESS" --binary-resolver "$R2" --passwd-home "$H2" -- "$@"; }
MRM() { SDP_MARKER_HUMAN=sekret python3 "$HARNESS" --binary-resolver "$R2" \
          --passwd-home "$H2" --isatty true -- "$@"; }

mgates 99
mstub "BLOCK: m1"; MH --cwd "$P2" --reviewer claude review "$P2/plan.md" >/dev/null 2>&1
mstub "BLOCK: m2"; MH --cwd "$P2" --reviewer claude review "$P2/plan.md" >/dev/null 2>&1
mgates 2
printf 'evidence\n' > "$P2/out1.md"
MLOG="$(MH --cwd "$P2" --print-state-path "$P2/plan.md")"

MRM --cwd "$P2" record-marker "$P2/plan.md" --marker-roster alice,bob \
    --marker-outputs out1.md --marker-rootcause first  > "$TMP/m1.out" 2>&1 & q1=$!
MRM --cwd "$P2" record-marker "$P2/plan.md" --marker-roster carol,dave \
    --marker-outputs out1.md --marker-rootcause second > "$TMP/m2.out" 2>&1 & q2=$!
wait "$q1"; r1=$?
wait "$q2"; r2=$?
markers="$(grep -c '^TEAM_REVIEW ' "$MLOG" || true)"
{ [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$markers" -eq 2 ]; } \
  && ok "T33: two concurrent record-marker invocations serialise and BOTH succeed" \
  || bad "T33: rc1=$r1 rc2=$r2 markers=$markers (want 0 0 2)"
# The last-marker assertion must NOT be able to pass vacuously. Against an engine
# with no record-marker verb (or with both writer calls forced to fail) the log
# holds zero TEAM_REVIEW rows, and comparing two empty strings would report
# success. Require exactly two non-empty rows FIRST, then compare.
second_line="$(grep '^TEAM_REVIEW ' "$MLOG" | sed -n '2p' || true)"
parsed="$(python3 - "$SDP_ROOT/scripts" "$MLOG" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import review_gate as rg
print(rg._parse_log(Path(sys.argv[2])).last_marker)
PY
)"
if [ "$markers" -ne 2 ]; then
  bad "T33: last_marker assertion is vacuous -- the log holds $markers TEAM_REVIEW row(s), want exactly 2"
elif [ -z "$second_line" ] || [ -z "$parsed" ]; then
  bad "T33: last_marker assertion is vacuous -- second row or parsed last_marker is empty"
elif [ "$parsed" = "$second_line" ]; then
  ok "T33: both lines are in the log in order and _parse_log reports the SECOND as last_marker"
else
  bad "T33: last_marker is not the second line"
fi

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
