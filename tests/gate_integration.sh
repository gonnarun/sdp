#!/usr/bin/env bash
# gate_integration.sh — executable spec for the ported review_gate.py state
# machine (REQ-047 / ADR-007). Drives the REAL gate via tests/lib/harness.py with
# a stub provider; asserts the counter / max_block / sticky-halt / override /
# infra_flag / A4 / config_source / worktree(V6) controls against the state files
# the gate itself reports via --print-state-path (never a re-derived path).
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
HARNESS="$SDP_ROOT/tests/lib/harness.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d -t sdp_gate_test.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/proj"; BIN="$TMP/bin"; HOMEFIX="$TMP/home"
mkdir -p "$PROJ/.sdp" "$BIN" "$HOMEFIX/.sdp"
printf 'plan\n' > "$PROJ/plan.md"
# Low max_block so the halt path is fast; attended mode so the override is live.
printf 'halt:\n  max_block: 3\n  pivot_cap: 2\ncadence:\n  escalate_from: 6\nmode: attended\n' > "$PROJ/.sdp/gates.yaml"

VERD="$TMP/verdict.txt"
set_claude_verdict() {   # $1 = stub stdout (verdict), $2 = exit code (default 0)
  printf '%s\n' "$1" > "$VERD"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\ncat "%s"\nexit %s\n' "$VERD" "${2:-0}" > "$BIN/claude"
  chmod +x "$BIN/claude"
}
set_claude_verdict "BLOCK: same reason"
# §4.5 Q24: the agy stub used to hard-BLOCK, so the require_primary_verdict case
# (T27) had no way to produce an agy-fallback ALLOW. Mirror set_claude_verdict.
AGYV="$TMP/agy_verdict.txt"
set_agy_verdict() {   # $1 = stub stdout (verdict), $2 = exit code (default 0)
  printf '%s\n' "$1" > "$AGYV"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\ncat "%s"\nexit %s\n' "$AGYV" "${2:-0}" > "$BIN/agy"
  chmod +x "$BIN/agy"
}
printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\nprintf "BLOCK: agy down\\n"; exit 1\n' > "$BIN/agy"; chmod +x "$BIN/agy"
RES="$TMP/res.json"; printf '{"claude":"%s","agy":"%s"}\n' "$BIN/claude" "$BIN/agy" > "$RES"

H() { python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" -- "$@"; }
# This spec drives the CLAUDE-direction state machine (its stub is `claude`), so it
# pins --reviewer claude explicitly now that the CLI default is codex (directional).
GATE() { H --cwd "$PROJ" --reviewer claude review "$PROJ/plan.md"; }

LOG="$(H --cwd "$PROJ" --print-state-path "$PROJ/plan.md")"
HALT="${LOG%.log}.halt"; FLAG="${LOG%.log}.infra_flag"
AUD="$PROJ/.private/sdp-artifacts/gate-audit.ndjson"

# ---- ANCHOR assertion FIRST: no negative runs against an unanchored path -----
set_claude_verdict "BLOCK: reason A"
GATE >/dev/null 2>&1
if [ -f "$LOG" ] && grep -q '^BLOCK_ATTEMPT 1 ' "$LOG"; then
  ok "anchor: the gate-reported log exists and holds the appended BLOCK_ATTEMPT"
else
  bad "anchor: gate-reported state path is wrong -- ABORTING (negatives would be vacuous)"
  echo "-------- $PASS passed, $FAIL failed --------"; exit 1
fi

# ---- counter increments; max_block=3 halts on the 3rd BLOCK. DISTINCT reasons
# ---- so the identical-twice (stuck) guard does not pre-empt max_block --------
set_claude_verdict "BLOCK: reason B"
GATE >/dev/null 2>&1   # BLOCK_ATTEMPT 2
set_claude_verdict "BLOCK: reason C"
GATE >/dev/null 2>&1   # BLOCK_ATTEMPT 3 -> max_block halt (L5)
[ -f "$HALT" ] && ok "max_block=3 -> .halt set on the 3rd BLOCK" || bad "halt not set at max_block"
n="$(grep -c '^BLOCK_ATTEMPT ' "$LOG")"
[ "$n" -eq 3 ] && ok "counter recorded exactly 3 BLOCK_ATTEMPTs" || bad "counter=$n (want 3)"

# ---- sticky halt: the next call BLOCKs pre-provider even if it would ALLOW ---
set_claude_verdict "ALLOW: fine"
out="$(GATE 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'halted'; } \
  && ok "sticky halt: BLOCK pre-provider even when the provider would ALLOW" \
  || bad "sticky halt (rc=$rc $out)"

# ---- override (attended + token match at the passwd home) clears the halt ----
printf 'sekret\n' > "$HOMEFIX/.sdp/override.token"; chmod 600 "$HOMEFIX/.sdp/override.token"
out="$(SDP_GATE_OVERRIDE=sekret GATE 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW: override'; } \
  && ok "override: attended + token match clears the halt and ALLOWs" \
  || bad "override (rc=$rc $out)"
[ ! -f "$HALT" ] && ok "override cleared the .halt file" || bad "override did not clear .halt"
# unattended (default) refuses the override
printf 'mode: unattended\n' > "$PROJ/.sdp/gates.yaml"
GATE >/dev/null 2>&1   # re-halt not needed; just prove override is inert unattended
out="$(SDP_GATE_OVERRIDE=sekret GATE 2>&1)"
printf '%s' "$out" | grep -q '^ALLOW: override' \
  && bad "override fired in unattended mode (should be inert)" \
  || ok "override is inert in unattended mode (MODE from gates.yaml, not env)"
printf 'halt:\n  max_block: 3\nmode: attended\n' > "$PROJ/.sdp/gates.yaml"

# ---- infra_flag on INFRA_ERROR ----------------------------------------------
rm -f "$LOG" "$HALT" "$FLAG"
set_claude_verdict "garbage no verdict" 3
out="$(GATE 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'INFRA_ERROR'; } \
  && ok "provider infra -> INFRA_ERROR" || bad "infra (rc=$rc $out)"
[ -f "$FLAG" ] && ok "INFRA_ERROR sets the per-artifact infra_flag (Stage 8 refusal)" || bad "infra_flag not set"

# ---- M11: a clean ALLOW clears the infra_flag; a BLOCK leaves it -------------
# The flag is set from the INFRA_ERROR above. A clean content ALLOW must clear
# the KEY-namespaced .infra_flag so Stage 8 MERGE/PUSH is unblocked; a later
# content BLOCK must NOT clear it (SDP.md: refused until a clean ALLOW clears it).
set_claude_verdict "ALLOW: recovered"
GATE >/dev/null 2>&1
[ ! -f "$FLAG" ] && ok "M11: a clean ALLOW clears the infra_flag" || bad "clean ALLOW left the infra_flag set"
set_claude_verdict "garbage no verdict" 3
GATE >/dev/null 2>&1   # re-arm the flag with a fresh INFRA_ERROR
[ -f "$FLAG" ] && ok "M11: a fresh INFRA_ERROR re-arms the infra_flag" || bad "infra_flag not re-armed"
set_claude_verdict "BLOCK: still broken"
GATE >/dev/null 2>&1
[ -f "$FLAG" ] && ok "M11: a content BLOCK leaves the infra_flag set" || bad "BLOCK wrongly cleared the infra_flag"

# ---- A4: an unauditable ALLOW is converted to INFRA_ERROR --------------------
rm -f "$LOG" "$HALT" "$FLAG"
set_claude_verdict "ALLOW: ok"
mkdir -p "$(dirname "$AUD")"; : > "$AUD"; chmod 000 "$AUD"
out="$(GATE 2>&1)"; rc=$?
chmod 644 "$AUD"
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'INFRA_ERROR'; } \
  && ok "A4: unauditable ALLOW converted to INFRA_ERROR" || bad "A4 (rc=$rc $out)"

# ---- config_source is recorded in the audit row -----------------------------
rm -f "$AUD" "$LOG"
set_claude_verdict "ALLOW: ok"
GATE >/dev/null 2>&1
python3 -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
cs=rows[-1].get("config_source") or ""
sys.exit(0 if cs.endswith(".sdp/gates.yaml") else 1)' "$AUD" \
  && ok "audit row records config_source (the resolved gates.yaml)" || bad "config_source missing"

# ---- V6: a git worktree (.git is a FILE) resolves the worktree root ----------
WT="$TMP/wt"; mkdir -p "$WT"
printf 'gitdir: /elsewhere/.git/worktrees/wt\n' > "$WT/.git"; printf 'plan\n' > "$WT/plan.md"
wlog="$(H --print-state-path "$WT/plan.md")"
case "$wlog" in
  */wt/.private/sdp-artifacts/gate/*) ok "V6: git worktree (.git as a file) resolves the worktree root" ;;
  *) bad "V6 worktree root (got $wlog)" ;;
esac

# ---- REQ-047 D-07: stuck / escalation / team / pivot ------------------------
# Fresh state, high max_block so max_block does not mask stuck; escalate_from=6.
reset_state() { rm -f "$LOG" "$HALT" "$FLAG"; }

# (1) STUCK: identical BLOCK first-line twice in a row -> pre-provider halt.
reset_state
printf 'halt:\n  max_block: 13\n  pivot_cap: 2\ncadence:\n  escalate_from: 6\nmode: attended\n' > "$PROJ/.sdp/gates.yaml"
set_claude_verdict "BLOCK: identical dup"
GATE >/dev/null 2>&1   # BLOCK_ATTEMPT 1 (hash H)
GATE >/dev/null 2>&1   # BLOCK_ATTEMPT 2 (hash H)
out="$(GATE 2>&1)"; rc=$?   # L3 reads [H,H] -> stuck halt, no 3rd provider call
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'identical'; } \
  && ok "stuck: identical BLOCK reason twice -> pre-provider halt" || bad "stuck (rc=$rc $out)"
[ -f "$HALT" ] && ok "stuck set the .halt file" || bad "stuck did not set .halt"
n="$(grep -c '^BLOCK_ATTEMPT ' "$LOG")"
[ "$n" -eq 2 ] && ok "stuck pre-empted the 3rd provider call (counter stays 2)" || bad "stuck counter=$n (want 2)"

# (2) ESCALATION: planner-solo hard-blocked from escalate_from with no marker.
reset_state
printf 'halt:\n  max_block: 13\n  pivot_cap: 2\ncadence:\n  escalate_from: 2\n  review_on: even\nmode: attended\n' > "$PROJ/.sdp/gates.yaml"
set_claude_verdict "BLOCK: e1"; GATE >/dev/null 2>&1   # BLOCK_ATTEMPT 1
set_claude_verdict "BLOCK: e2"; GATE >/dev/null 2>&1   # BLOCK_ATTEMPT 2 -> count == escalate_from
set_claude_verdict "BLOCK: e3"                          # count>=2, no team marker -> BLOCK
out="$(GATE 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'planner-solo\|TEAM_REVIEW not performed'; } \
  && ok "escalation: planner-solo blocked at escalate_from (no marker)" || bad "escalation-solo (rc=$rc $out)"
[ ! -f "$HALT" ] && ok "escalation BLOCK is recoverable (no .halt written)" || bad "escalation wrongly halted"
n="$(grep -c '^BLOCK_ATTEMPT ' "$LOG")"
[ "$n" -eq 2 ] && ok "escalation BLOCK does not increment the counter (stays 2)" || bad "escalation counter=$n (want 2)"

# (2b) A valid TEAM_REVIEW marker (>=2 distinct members + a fresh output) passes.
printf 'evidence\n' > "$PROJ/out1.md"
printf 'TEAM_REVIEW %s roster=alice,bob outputs=out1.md\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
set_claude_verdict "ALLOW: team-approved"
out="$(GATE 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW:'; } \
  && ok "escalation: valid TEAM_REVIEW marker lets the review proceed" || bad "escalation-pass (rc=$rc $out)"

# (2c) An invalid roster (planner-solo) is rejected even if the provider would ALLOW.
reset_state
set_claude_verdict "BLOCK: r1"; GATE >/dev/null 2>&1
set_claude_verdict "BLOCK: r2"; GATE >/dev/null 2>&1   # count 2
printf 'evidence3\n' > "$PROJ/out3.md"
printf 'TEAM_REVIEW %s roster=planner outputs=out3.md\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
set_claude_verdict "ALLOW: should-not-run"
out="$(GATE 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'planner-solo\|TEAM_REVIEW not performed'; } \
  && ok "roster: a single-member (planner) roster is rejected pre-provider" || bad "roster-reject (rc=$rc $out)"

# (3) PIVOT: TEAM_REVIEW decision=pivot RESETs the counter (at most pivot_cap).
reset_state
set_claude_verdict "BLOCK: p1"; GATE >/dev/null 2>&1   # BLOCK_ATTEMPT 1
set_claude_verdict "BLOCK: p2"; GATE >/dev/null 2>&1   # BLOCK_ATTEMPT 2 -> count 2
printf 'evidence2\n' > "$PROJ/out2.md"
printf 'TEAM_REVIEW %s roster=alice,bob outputs=out2.md decision=pivot\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
set_claude_verdict "BLOCK: p3"
GATE >/dev/null 2>&1   # escalation -> PIVOT_RESET + RESET, count->0, then review BLOCK -> BA 1
grep -q '^PIVOT_RESET ' "$LOG" \
  && ok "pivot: TEAM_REVIEW decision=pivot appended PIVOT_RESET" || bad "pivot: no PIVOT_RESET"
tail_ba="$(grep '^BLOCK_ATTEMPT ' "$LOG" | tail -1 | awk '{print $2}')"
[ "$tail_ba" = "1" ] && ok "pivot reset the counter (next BLOCK_ATTEMPT restarts at 1)" || bad "pivot counter not reset (got $tail_ba)"

# =============================================================================
# P2 — the durable escalation-stall signal (ADR-G04 / G05 / G09 / G13 / G17) and
# P1's record-marker failure arms (§5c). T18-T32.
# =============================================================================
printf 'sekret\n' > "$HOMEFIX/.sdp/marker.token"; chmod 600 "$HOMEFIX/.sdp/marker.token"
RM() { SDP_MARKER_HUMAN=sekret python3 "$HARNESS" --binary-resolver "$RES" \
         --passwd-home "$HOMEFIX" --isatty true -- "$@"; }

gates2() {   # $1 = project dir, $2 = escalate_from, $3 = extra halt: lines (may be empty)
  { printf 'halt:\n  max_block: 13\n  pivot_cap: 2\n'
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf 'cadence:\n  escalate_from: %s\n  review_on: even\nmode: unattended\n' "$2"
  } > "$1/.sdp/gates.yaml"
}
mkproj2() {  # $1 = name, $2 = final escalate_from, $3 = BLOCK rounds, $4 = extra halt lines
  local p="$TMP/$1" i=1
  mkdir -p "$p/.sdp"
  printf 'plan\n' > "$p/plan.md"
  gates2 "$p" 99 ""
  while [ "$i" -le "$3" ]; do
    set_claude_verdict "BLOCK: $1 round $i"
    H --cwd "$p" --reviewer claude review "$p/plan.md" >/dev/null 2>&1
    i=$((i + 1))
  done
  gates2 "$p" "$2" "${4:-}"
  printf 'evidence\n' > "$p/out1.md"
}
plog2() { H --cwd "$1" --print-state-path "$1/plan.md"; }
gate2()  { H --cwd "$1" --reviewer claude review "$1/plan.md"; }
counts() {   # cumulative BLOCK_ATTEMPT count as _read_log_counts sees it
  python3 - "$SDP_ROOT/scripts" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import review_gate as rg
print(rg._read_log_counts(Path(sys.argv[2])))
PY
}
stallfields() {   # "<stall_run> <stall_trailing> <last_marker_present>"
  python3 - "$SDP_ROOT/scripts" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import review_gate as rg
s = rg._parse_log(Path(sys.argv[2]))
print(s.stall_run, "yes" if s.stall_trailing else "no", "yes" if s.last_marker else "no")
PY
}
valid_marker() {   # $1 = project dir, $2 = log, $3 = round, $4 = extra fields
  printf 'TEAM_REVIEW %s round=%s roster=alice,bob outputs=out1.md %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" "${4:-}" >> "$2"
}

# ---- T18 ★ the headline case: ONE escalation BLOCK, NO retry -> .needs_human --
mkproj2 stall 2 2
SP="$TMP/stall"; SLOG="$(plog2 "$SP")"; SNH="${SLOG%.log}.needs_human"; SHALT="${SLOG%.log}.halt"
set_claude_verdict "BLOCK: never reached"
out="$(gate2 "$SP" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -f "$SNH" ]; } \
  && ok "T18: a single escalation BLOCK with NO retry writes a durable .needs_human" \
  || bad "T18: no .needs_human after the first stall (rc=$rc) $out"
grep -q '^ESCALATION_STALL .* run=1 why=no_marker$' "$SLOG" \
  && ok "T18: the stall is durable in the log (ESCALATION_STALL run=1 why=no_marker)" \
  || bad "T18: no ESCALATION_STALL line"
[ ! -f "$SHALT" ] && ok "T18: the first stall NOTIFIes; it does not halt" || bad "T18: first stall halted"

# ---- T21: ESCALATION_STALL is counter-neutral in _read_log_counts ------------
gate2 "$SP" >/dev/null 2>&1
gate2 "$SP" >/dev/null 2>&1
n="$(counts "$SLOG")"
[ "$n" -eq 2 ] && ok "T21: ESCALATION_STALL is counter-neutral (count stays 2 after 3 stalls)" \
               || bad "T21: count=$n (want 2) -- a stall is pushing the artifact toward max_block"

# ---- T22: stall_run survives an intervening TEAM_* --------------------------
before_run="$(stallfields "$SLOG" | awk '{print $1}')"
printf 'TEAM_REVIEW %s round=2 roster=solo outputs=out1.md\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SLOG"
gate2 "$SP" >/dev/null 2>&1
after_run="$(stallfields "$SLOG" | awk '{print $1}')"
[ "$after_run" -eq $((before_run + 1)) ] \
  && ok "T22: stall_run survives an intervening TEAM_* (rejected markers do not reset the run)" \
  || bad "T22: stall_run $before_run -> $after_run (want +1)"

# ---- T29: doctor exits non-zero while stall_trailing, with no other flag -----
rm -f "$SNH"
trailing="$(stallfields "$SLOG" | awk '{print $2}')"
H --cwd "$SP" doctor >/dev/null 2>&1; drc=$?
{ [ "$trailing" = "yes" ] && [ "$drc" -ne 0 ]; } \
  && ok "T29: doctor exits non-zero while stall_trailing (no .needs_human, no .halt)" \
  || bad "T29: doctor rc=$drc with stall_trailing=$trailing"

# ---- T28 ★ BLOCKER-1: a successful recovery returns doctor to ZERO -----------
printf 'evidence\n' > "$SP/out1.md"
valid_marker "$SP" "$SLOG" 2
set_claude_verdict "ALLOW: recovered"
gate2 "$SP" >/dev/null 2>&1
run_after="$(stallfields "$SLOG" | awk '{print $1}')"
H --cwd "$SP" doctor >/dev/null 2>&1; drc=$?
{ [ "$drc" -eq 0 ] && [ "$run_after" -ge 1 ]; } \
  && ok "T28: a successful recovery returns doctor to 0 WHILE stall_run is still >=1" \
  || bad "T28: doctor rc=$drc, stall_run=$run_after (want rc 0 and stall_run>=1)"
[ ! -f "$SNH" ] && ok "T24: .needs_human is cleared when a review executes (ALLOW arm)" \
                || bad "T24: ALLOW did not clear .needs_human"

# ---- T24 (block arm) + T30: .needs_human survives INFRA_ERROR, ALLOW clears --
mkproj2 nh 2 2
NP="$TMP/nh"; NLOG="$(plog2 "$NP")"; NNH="${NLOG%.log}.needs_human"; NFLAG="${NLOG%.log}.infra_flag"
gate2 "$NP" >/dev/null 2>&1                      # stall -> .needs_human
[ -f "$NNH" ] || bad "T30: precondition -- no .needs_human"
valid_marker "$NP" "$NLOG" 2
set_claude_verdict "garbage no verdict" 3        # primary infra, agy stub BLOCKs -> INFRA_ERROR
gate2 "$NP" >/dev/null 2>&1
{ [ -f "$NNH" ] && [ -f "$NFLAG" ]; } \
  && ok "T30: .needs_human SURVIVES an INFRA_ERROR (no review executed); .infra_flag arms" \
  || bad "T30: INFRA_ERROR wrongly cleared .needs_human"
printf 'evidence\n' > "$NP/out1.md"
valid_marker "$NP" "$NLOG" 2
set_claude_verdict "BLOCK: reviewed and rejected"
gate2 "$NP" >/dev/null 2>&1
[ ! -f "$NNH" ] && ok "T24: .needs_human is cleared on L5's BLOCK arm too (a review executed)" \
                || bad "T24: the block arm did not clear .needs_human"

# ---- T23 ★ an interposed ALLOW does not prevent max_stall (S10) --------------
mkproj2 s10 2 2 "  max_stall: 2"
AP="$TMP/s10"; ALOG="$(plog2 "$AP")"; AHALT="${ALOG%.log}.halt"
gate2 "$AP" >/dev/null 2>&1                      # stall run=1
printf 'ALLOW %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ALOG"   # counter-neutral interposition
[ ! -f "$AHALT" ] || bad "T23: precondition -- halted too early"
gate2 "$AP" >/dev/null 2>&1                      # stall run=2 == max_stall -> .halt
[ -f "$AHALT" ] && ok "T23: an interposed ALLOW does not reset stall_run; max_stall still fires" \
                || bad "T23: the interposed ALLOW prevented max_stall"

# ---- T32: max_stall's ABSENT-KEY default is 5 (C6 / NC-14) ------------------
mkproj2 dflt 2 2 ""              # no halt.max_stall key at all
mkproj2 expl 2 2 "  max_stall: 5"
for name in dflt expl; do
  p="$TMP/$name"; l="$(plog2 "$p")"; h="${l%.log}.halt"; i=1
  while [ "$i" -le 4 ]; do gate2 "$p" >/dev/null 2>&1; i=$((i + 1)); done
  [ -f "$h" ] && bad "T32/$name: halted before the 5th stall"
  gate2 "$p" >/dev/null 2>&1
  [ -f "$h" ] && ok "T32/$name: .halt lands on the 5th stall" || bad "T32/$name: no .halt on the 5th stall"
done

# ---- T25 ⚠ an over-cap pivot BLOCKs (real behaviour change) ------------------
mkproj2 cap 2 2 "  pivot_cap: 1"
CP="$TMP/cap"; CLOG="$(plog2 "$CP")"
valid_marker "$CP" "$CLOG" 2 "decision=pivot"
set_claude_verdict "BLOCK: after the first pivot"
gate2 "$CP" >/dev/null 2>&1        # pivot 1 of 1 -> PIVOT_RESET, counter 0, then BA 1
set_claude_verdict "BLOCK: cap b2"
gate2 "$CP" >/dev/null 2>&1        # BA 2 -> back at escalate_from
printf 'evidence\n' > "$CP/out1.md"
valid_marker "$CP" "$CLOG" 2 "decision=pivot"
set_claude_verdict "ALLOW: must not run"
out="$(gate2 "$CP" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'pivot cap 1 exhausted'; } \
  && ok "T25: an over-cap decision=pivot BLOCKs instead of silently falling through" \
  || bad "T25: over-cap pivot did not BLOCK (rc=$rc) $out"
grep -q '^ESCALATION_STALL .*why=pivot_cap_exhausted$' "$CLOG" \
  && ok "T25: the over-cap pivot appends ESCALATION_STALL why=pivot_cap_exhausted" \
  || bad "T25: no pivot_cap_exhausted stall line"

# ---- T26: decision=pivot INSIDE summary= does not reset (ADR-G12) -----------
mkproj2 tok 2 2
TP="$TMP/tok"; TLOG="$(plog2 "$TP")"
printf 'TEAM_REVIEW %s round=2 roster=alice,bob outputs=out1.md decision=continue summary=we-rejected decision=pivot as-premature\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TLOG"
set_claude_verdict "ALLOW: reviewed"
gate2 "$TP" >/dev/null 2>&1
grep -q '^PIVOT_RESET ' "$TLOG" \
  && bad "T26: a decision=pivot inside summary= still reset the counter (raw substring test)" \
  || ok "T26: decision= is parsed as a KEYED TOKEN; a pivot inside summary= does not reset"

# ---- T27: require_primary_verdict converts an agy-fallback ALLOW ------------
mkproj2 rpv 99 1
RP="$TMP/rpv"; RLOG="$(plog2 "$RP")"; RFLAG="${RLOG%.log}.infra_flag"
printf 'halt:\n  max_block: 13\ncadence:\n  escalate_from: 99\nmode: unattended\nrequire_primary_verdict: true\n' \
  > "$RP/.sdp/gates.yaml"
set_claude_verdict "garbage no verdict" 3          # primary fails -> agy fallback
set_agy_verdict "ALLOW: agy says fine"
out="$(gate2 "$RP" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'agy fallback ALLOW refused'; } \
  && ok "T27: require_primary_verdict converts an agy-fallback ALLOW to INFRA_ERROR" \
  || bad "T27: agy fallback ALLOW not refused (rc=$rc) $out"
grep -q '^ALLOW ' "$RLOG" && bad "T27: an ALLOW line was written for a refused fallback" \
                          || ok "T27: no ALLOW line is written for a refused fallback"
[ -f "$RFLAG" ] && ok "T27: the refusal arms .infra_flag" || bad "T27: no .infra_flag"
set_agy_verdict "BLOCK: agy rejects"
out="$(gate2 "$RP" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'agy fallback'; } \
  && ok "T27: an agy fallback BLOCK is unaffected by require_primary_verdict" \
  || bad "T27: agy BLOCK path changed (rc=$rc) $out"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\nprintf "BLOCK: agy down\\n"; exit 1\n' > "$BIN/agy"; chmod +x "$BIN/agy"

# ---- T19: a _record audit failure after the TEAM_* append leaves it INERT ----
mkproj2 aud 2 2
UP="$TMP/aud"; ULOG="$(plog2 "$UP")"; UFLAG="${ULOG%.log}.infra_flag"; UAUD="$UP/.private/sdp-artifacts/gate-audit.ndjson"
mkdir -p "$(dirname "$UAUD")"; : > "$UAUD"; chmod 000 "$UAUD"
out="$(RM --cwd "$UP" record-marker "$UP/plan.md" --marker-roster alice,bob --marker-outputs out1.md 2>&1)"; rc=$?
chmod 644 "$UAUD"
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'INFRA_ERROR'; } \
  && ok "T19: an unauditable record-marker returns INFRA_ERROR" || bad "T19: (rc=$rc) $out"
grep -q '^MARKER_AUDIT_FAILED ' "$ULOG" \
  && ok "T19: the compensating MARKER_AUDIT_FAILED append landed" || bad "T19: no compensating append"
[ -f "$UFLAG" ] && ok "T19: the audit failure arms .infra_flag" || bad "T19: no .infra_flag"
[ "$(stallfields "$ULOG" | awk '{print $3}')" = "no" ] \
  && ok "T19: the appended marker is INERT (_parse_log can never return it as last_marker)" \
  || bad "T19: the unaudited marker is still live"
n="$(counts "$ULOG")"
[ "$n" -eq 2 ] && ok "T19: MARKER_AUDIT_FAILED is counter-neutral (count unchanged)" || bad "T19: count=$n (want 2)"
set_claude_verdict "ALLOW: must not run"
out="$(gate2 "$UP" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi 'TEAM_REVIEW not performed\|planner-solo'; } \
  && ok "T19: the next gate run still requires a TEAM_REVIEW (kind unchanged)" || bad "T19: marker was accepted (rc=$rc) $out"

# ---- T20 ★ the compensating append's OWN failure branch (D-2 seam) -----------
# --append-fail-after 1: the TEAM_* append succeeds and the COMPENSATING append
# is the first failing _APPEND_LINE call. No filesystem lever reaches this branch.
mkproj2 comp 2 2
MP="$TMP/comp"; MLOG="$(plog2 "$MP")"; MFLAG="${MLOG%.log}.infra_flag"; MAUD="$MP/.private/sdp-artifacts/gate-audit.ndjson"
mkdir -p "$(dirname "$MAUD")"; : > "$MAUD"; chmod 000 "$MAUD"
out="$(SDP_MARKER_HUMAN=sekret python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" \
        --isatty true --append-fail-after 1 -- --cwd "$MP" record-marker "$MP/plan.md" \
        --marker-roster alice,bob --marker-outputs out1.md 2>&1)"; rc=$?
chmod 644 "$MAUD"
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'STILL LIVE'; } \
  && ok "T20: a failed compensating append RAISES InfraError and never returns an INFRA_ERROR result" \
  || bad "T20: wrong failure shape (rc=$rc) $out"
grep -q '^MARKER_AUDIT_FAILED ' "$MLOG" \
  && bad "T20: precondition broken -- the compensating append did not actually fail" \
  || ok "T20: the compensating append did fail (no MARKER_AUDIT_FAILED line)"
[ -f "$MFLAG" ] && ok "T20: .infra_flag is attempted before the raise" || bad "T20: no .infra_flag"
[ "$(stallfields "$MLOG" | awk '{print $3}')" = "yes" ] \
  && ok "T20: the marker is STILL LIVE on this branch -- exactly what NC-23 records" \
  || bad "T20: the marker was invalidated, so the branch under test was not reached"

# ---- T31: _audit_base regression guard (A13) --------------------------------
# The --cwd state-directory hole is PRE-EXISTING and deliberately NOT closed here
# (approved deviation D2 / NC-12). Assert TODAY's behaviour so a future refactor
# cannot relocate the state directory silently.
mkdir -p "$TMP/anch/.sdp/deep"; printf 'plan\n' > "$TMP/anch/deep_plan.md"
mkdir -p "$TMP/anch/sub"; printf 'plan\n' > "$TMP/anch/sub/plan.md"
a_root="$(H --cwd "$TMP/anch" --print-state-path "$TMP/anch/sub/plan.md")"
a_sub="$(H --cwd "$TMP/anch/sub" --print-state-path "$TMP/anch/sub/plan.md")"
{ [ "$a_root" != "$a_sub" ] \
  && printf '%s' "$a_root" | grep -q '/anch/.private/sdp-artifacts/gate/' \
  && printf '%s' "$a_sub"  | grep -q '/anch/sub/.private/sdp-artifacts/gate/'; } \
  && ok "T31: _audit_base still follows the --cwd-derived root (unchanged; the hole stays open)" \
  || bad "T31: _audit_base anchoring changed (root=$a_root sub=$a_sub)"

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
