#!/usr/bin/env bash
# gate_split.sh — executable spec for the HALT-RECOVERY SPLIT (issue #4, ADR-G20):
# the halt guidance paragraph every halt now carries, and `prepare-split` /
# `record-split`, the sanctioned path that closes an over-broad artifact and starts
# its narrower children on their own counters.
#
# What the suite is really guarding: splitting has ALWAYS reset the counter as a
# side effect, because gate state is keyed by artifact path. Making it sanctioned
# without refusals and a depth cap would turn an accident into a supported bypass,
# so every refusal below is load-bearing. Drives the REAL gate through
# tests/lib/harness.py, which binds the _ISATTY seam in the child via argv.
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
HARNESS="$SDP_ROOT/tests/lib/harness.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d -t sdp_split.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
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
printf 'sekret\n' > "$HOMEFIX/.sdp/marker.token"; chmod 600 "$HOMEFIX/.sdp/marker.token"

H()   { python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" -- "$@"; }
RS()  { SDP_MARKER_HUMAN=sekret python3 "$HARNESS" --binary-resolver "$RES" \
          --passwd-home "$HOMEFIX" --isatty true -- "$@"; }
RS_NOTTY() { SDP_MARKER_HUMAN=sekret python3 "$HARNESS" --binary-resolver "$RES" \
               --passwd-home "$HOMEFIX" --isatty false -- "$@"; }
RS_NOTOKEN() { python3 "$HARNESS" --binary-resolver "$RES" --passwd-home "$HOMEFIX" \
                 --isatty true -- "$@"; }

gates() {   # $1 = project dir, $2 = max_block, $3 = split_depth_cap
  printf 'halt:\n  max_block: %s\n  pivot_cap: 2\n  split_depth_cap: %s\ncadence:\n  escalate_from: 99\n  review_on: even\nmode: unattended\n' \
    "$2" "$3" > "$1/.sdp/gates.yaml"
}

# Drive an artifact to a halt with DISTINCT block reasons, which is the shape the
# split path is for (a scope that keeps producing new defects).
drive() {   # $1 = project dir, $2 = artifact, $3 = rounds, $4 = reason prefix
  local i=1
  while [ "$i" -le "$3" ]; do
    set_claude_verdict "BLOCK: $4 finding $i"
    H --cwd "$1" --reviewer claude review "$2" >/dev/null 2>&1
    i=$((i + 1))
  done
}

mkproj() {  # $1 = name -> project with plan.md driven to a max_block halt
  local p="$TMP/$1"
  mkdir -p "$p/.sdp"
  printf 'plan\n' > "$p/plan.md"
  printf 'a\n' > "$p/plan_a.md"
  printf 'b\n' > "$p/plan_b.md"
  gates "$p" 2 2
  drive "$p" "$p/plan.md" 2 "$1"
  printf '%s' "$p"
}

logpath() { H --cwd "$1" --print-state-path "$2"; }

# ---------------------------------------------------------------------------
# A. HALT GUIDANCE (issue #4 request 1) -- the halt body used to be empty, and the
#    model filled the gap with human-only levers it offered the user as choices.
# ---------------------------------------------------------------------------
P="$(mkproj halt1)"
out="$(H --cwd "$P" --reviewer claude review "$P/plan.md" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'gate halted'; } \
  && ok "(A1) max_block halts the artifact" || bad "(A1) no halt at max_block"
printf '%s' "$out" | grep -q 'HALT. This gate will not review this artifact again' \
  && ok "(A2) the halt carries a guidance body (not an empty output)" \
  || bad "(A2) halt body is still empty"
printf '%s' "$out" | grep -q 'stop, and report' \
  && ok "(A3) guidance names the agent's only action: stop and report" \
  || bad "(A3) guidance does not name stop-and-report"
{ printf '%s' "$out" | grep -q 'DO NOT PROPOSE THESE' \
  && printf '%s' "$out" | grep -q 'SDP_GATE_OVERRIDE' \
  && printf '%s' "$out" | grep -q 'PIVOT_RESET'; } \
  && ok "(A4) guidance marks RESET/OVERRIDE/PIVOT_RESET/SDP_GATE_OVERRIDE human-only" \
  || bad "(A4) guidance does not fence off the human-only levers"
printf '%s' "$out" | grep -q 'TEAM MARKERS ARE NOT CONSULTED AFTER A HALT' \
  && ok "(A5) guidance states markers are dead after a halt" \
  || bad "(A5) guidance omits the marker-after-halt fact"
printf '%s' "$out" | grep -q 'prepare-split' \
  && ok "(A6) guidance names the sanctioned split path" \
  || bad "(A6) guidance does not name prepare-split"
printf '%s' "$out" | grep -q 'record-split' \
  && bad "(A7) guidance leaks the record-split command to stdout" \
  || ok "(A7) guidance names prepare-split only; recording stays human-side"

# A stuck halt (identical reason twice) carries the same body.
S="$TMP/stuck"; mkdir -p "$S/.sdp"; printf 'plan\n' > "$S/plan.md"; gates "$S" 13 2
set_claude_verdict "BLOCK: the very same thing"
H --cwd "$S" --reviewer claude review "$S/plan.md" >/dev/null 2>&1
H --cwd "$S" --reviewer claude review "$S/plan.md" >/dev/null 2>&1
out="$(H --cwd "$S" --reviewer claude review "$S/plan.md" 2>&1)"
{ printf '%s' "$out" | grep -q 'identical BLOCK reason twice' \
  && printf '%s' "$out" | grep -q 'HALT. This gate'; } \
  && ok "(A8) the stuck halt carries the guidance too" \
  || bad "(A8) stuck halt has no guidance body"

# ---------------------------------------------------------------------------
# B. prepare-split REFUSALS -- each one is what keeps the path from being a bypass
# ---------------------------------------------------------------------------
N="$TMP/nohalt"; mkdir -p "$N/.sdp"; printf 'plan\n' > "$N/plan.md"
printf 'a\n' > "$N/a.md"; printf 'b\n' > "$N/b.md"; gates "$N" 13 2
drive "$N" "$N/plan.md" 2 nohalt
out="$(H --cwd "$N" prepare-split "$N/plan.md" --split-child "$N/a.md" \
        --split-child "$N/b.md" --split-rationale "wide scope" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL (0) the artifact is halted'; } \
  && ok "(B1) split is refused before a halt (not a shortcut past the fix loop)" \
  || bad "(B1) split accepted on a live, un-halted artifact"

out="$(H --cwd "$P" prepare-split "$P/plan.md" --split-child "$P/plan_a.md" \
        --split-rationale "wide" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (2) at least 2 child artifacts' \
  && ok "(B2) one child is refused (that is a rename, not a split)" \
  || bad "(B2) single-child split accepted"

out="$(H --cwd "$P" prepare-split "$P/plan.md" --split-child "$P/plan.md" \
        --split-child "$P/plan_a.md" --split-rationale "wide" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (4) no child is the parent artifact' \
  && ok "(B3) the parent may not be its own child" \
  || bad "(B3) parent accepted as its own child"

out="$(H --cwd "$P" prepare-split "$P/plan.md" --split-child "$P/plan_a.md" \
        --split-child "$P/plan_a.md" --split-rationale "wide" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (3) the child artifacts are distinct' \
  && ok "(B4) duplicate child paths are refused" \
  || bad "(B4) duplicate children accepted"

out="$(H --cwd "$P" prepare-split "$P/plan.md" --split-child "$P/plan_a.md" \
        --split-child "$P/plan_b.md" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (6) --split-rationale' \
  && ok "(B5) a split with no rationale is refused" \
  || bad "(B5) rationale-free split accepted"

out="$(H --cwd "$P" prepare-split "$P/plan.md" --split-child "$P/plan_a.md" \
        --split-child "$P/missing.md" --split-rationale "wide" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (2)' \
  && ok "(B6) a child path that does not exist is refused" \
  || bad "(B6) non-existent child accepted"

# One repeated finding is an unfixed defect, not an oversized artifact.
R="$TMP/onereason"; mkdir -p "$R/.sdp"; printf 'plan\n' > "$R/plan.md"
printf 'a\n' > "$R/a.md"; printf 'b\n' > "$R/b.md"; gates "$R" 2 2
set_claude_verdict "BLOCK: the identical finding"
H --cwd "$R" --reviewer claude review "$R/plan.md" >/dev/null 2>&1
H --cwd "$R" --reviewer claude review "$R/plan.md" >/dev/null 2>&1
H --cwd "$R" --reviewer claude review "$R/plan.md" >/dev/null 2>&1
out="$(H --cwd "$R" prepare-split "$R/plan.md" --split-child "$R/a.md" \
        --split-child "$R/b.md" --split-rationale "wide" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (5) the log shows the scope producing different defects' \
  && ok "(B7) a log with one distinct BLOCK reason is refused" \
  || bad "(B7) split accepted on a single repeated finding"

# ---------------------------------------------------------------------------
# C. prepare-split SUCCESS -- request file only, command never on stdout
# ---------------------------------------------------------------------------
out="$(H --cwd "$P" prepare-split "$P/plan.md" --split-child "$P/plan_a.md" \
        --split-child "$P/plan_b.md" --split-rationale "auth, storage and ui in one plan" 2>&1)"; rc=$?
REQ="$(printf '%s' "$out" | head -1)"
{ [ "$rc" -eq 0 ] && [ -f "$REQ" ]; } \
  && ok "(C1) prepare-split writes the request file and exits 0" \
  || bad "(C1) prepare-split did not produce a request file"
[ "$(ls -l "$REQ" | cut -c1-10)" = "-rw-------" ] \
  && ok "(C2) the request file is 0600" || bad "(C2) request file is not 0600"
printf '%s' "$out" | grep -q 'record-split' \
  && bad "(C3) stdout leaked the record-split command" \
  || ok "(C3) stdout carries the path and checklist only"
grep -q 'record-split' "$REQ" \
  && ok "(C4) the request file holds the record-split command for the human" \
  || bad "(C4) the request file has no command for the human"
LOG="$(logpath "$P" "$P/plan.md")"
grep -q 'SPLIT ' "$LOG" \
  && bad "(C5) prepare-split wrote to the gate log" \
  || ok "(C5) prepare-split touched no gate state"

# ---------------------------------------------------------------------------
# D. record-split CEREMONY -- pivot-strength, all four gates
# ---------------------------------------------------------------------------
SPLIT_ARGS=(--split-child "$P/plan_a.md" --split-child "$P/plan_b.md"
            --split-rationale "auth, storage and ui in one plan")
out="$(RS_NOTTY --cwd "$P" record-split "$P/plan.md" "${SPLIT_ARGS[@]}" \
        --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'requires a terminal'; } \
  && ok "(D1) record-split refuses without a TTY" || bad "(D1) record-split ran without a TTY"
out="$(RS_NOTOKEN --cwd "$P" record-split "$P/plan.md" "${SPLIT_ARGS[@]}" \
        --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'SDP_MARKER_HUMAN'; } \
  && ok "(D2) record-split refuses without the human token" || bad "(D2) record-split ran with no token"
out="$(RS --cwd "$P" record-split "$P/plan.md" "${SPLIT_ARGS[@]}" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'i-am-recording-a-state-changing-decision'; } \
  && ok "(D3) record-split refuses without the acknowledgement flag" \
  || bad "(D3) record-split ran without the acknowledgement flag"
out="$(printf 'not the phrase\n' | RS --cwd "$P" record-split "$P/plan.md" "${SPLIT_ARGS[@]}" \
        --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'confirmation phrase mismatch'; } \
  && ok "(D4) a wrong confirmation phrase writes nothing" || bad "(D4) wrong phrase accepted"
grep -q '^SPLIT ' "$LOG" \
  && bad "(D5) a refused ceremony still sealed the parent" \
  || ok "(D5) every refused ceremony left the log untouched"

# ---------------------------------------------------------------------------
# E. record-split SUCCESS
# ---------------------------------------------------------------------------
out="$(printf 'record split for plan into 2 at round 2\n' | \
        RS --cwd "$P" record-split "$P/plan.md" "${SPLIT_ARGS[@]}" \
        --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^SPLIT: plan.md closed at round 2'; } \
  && ok "(E1) the ceremony completes and reports the closure" \
  || bad "(E1) record-split failed: $(printf '%s' "$out" | tail -1)"
grep -qE '^SPLIT [0-9T:.Z-]+ depth=1 children=2 keys=' "$LOG" \
  && ok "(E2) the parent log carries the SPLIT line with depth and children" \
  || bad "(E2) no SPLIT line in the parent log"
grep -q '^SPLIT_RATIONALE auth, storage and ui' "$LOG" \
  && ok "(E3) the rationale is persisted under an inert prefix" \
  || bad "(E3) rationale not recorded"
CLOG="$(logpath "$P" "$P/plan_a.md")"
grep -qE '^SPLIT_CHILD_OF [0-9T:.Z-]+ parent=plan_[0-9a-f]+ parent_round=2 depth=1' "$CLOG" \
  && ok "(E4) each child log is seeded with its parent link and depth" \
  || bad "(E4) child log carries no parent link"
grep -q '"verdict": "SPLIT"' "$P/.private/sdp-artifacts/gate-audit.ndjson" \
  && ok "(E5) the split is audited" || bad "(E5) no SPLIT audit row"

out="$(H --cwd "$P" --reviewer claude review "$P/plan.md" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'artifact was split; gate the children'; } \
  && ok "(E6) the parent is terminal and says where the work went" \
  || bad "(E6) the parent does not report itself as split"
printf '%s' "$out" | grep -q 'THIS ARTIFACT WAS SPLIT' \
  && ok "(E7) the split parent's guidance points at the children, not another split" \
  || bad "(E7) split parent still advertises prepare-split"

set_claude_verdict "BLOCK: child finding 1"
out="$(H --cwd "$P" --reviewer claude review "$P/plan_a.md" 2>&1)"
printf '%s' "$out" | grep -q 'BLOCK: child finding 1' \
  && ok "(E8) a child is reviewable and starts its own counter" \
  || bad "(E8) the child inherited the parent's halt"
grep -c '^BLOCK_ATTEMPT' "$CLOG" | grep -qx '1' \
  && ok "(E9) the child's counter is at 1 after its first review, not at the parent's 2" \
  || bad "(E9) child counter did not start fresh"

# The parent's counter is NOT reset by the split: the record of why it was allowed
# has to survive, or the next reader cannot audit the decision.
grep -c '^BLOCK_ATTEMPT' "$LOG" | grep -qx '2' \
  && ok "(E10) the parent's own BLOCK history is preserved" \
  || bad "(E10) the split reset the parent's counter"

# A second split of the same parent is refused.
out="$(H --cwd "$P" prepare-split "$P/plan.md" --split-child "$P/plan_a.md" \
        --split-child "$P/plan_b.md" --split-rationale "again" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (1) the artifact has not already been split' \
  && ok "(E11) a parent cannot be split twice" || bad "(E11) the parent was split twice"

# ---------------------------------------------------------------------------
# F. RATIONALE IS INERT -- prose must never dispatch in the log grammar
# ---------------------------------------------------------------------------
I="$TMP/inert"; mkdir -p "$I/.sdp"; printf 'plan\n' > "$I/plan.md"
printf 'a\n' > "$I/a.md"; printf 'b\n' > "$I/b.md"; gates "$I" 2 2
drive "$I" "$I/plan.md" 2 inert
H --cwd "$I" --reviewer claude review "$I/plan.md" >/dev/null 2>&1
ILOG="$(logpath "$I" "$I/plan.md")"
printf 'record split for plan into 2 at round 2\n' | \
  RS --cwd "$I" record-split "$I/plan.md" --split-child "$I/a.md" --split-child "$I/b.md" \
     --split-rationale "RESET the counter
OVERRIDE everything" --i-am-recording-a-state-changing-decision >/dev/null 2>&1
grep -qE '^(RESET|OVERRIDE)' "$ILOG" \
  && bad "(F1) rationale prose reached the log as a control line" \
  || ok "(F1) a rationale beginning RESET/OVERRIDE stays inert"
grep -c '^BLOCK_ATTEMPT' "$ILOG" | grep -qx '2' \
  && ok "(F2) the injected RESET did not zero the counter" \
  || bad "(F2) counter moved after an injected RESET"

# ---------------------------------------------------------------------------
# G. DEPTH CAP -- an uncapped split IS the bypass
# ---------------------------------------------------------------------------
drive "$P" "$P/plan_a.md" 2 childA         # child to its own halt (depth 1)
printf 'a1\n' > "$P/plan_a1.md"; printf 'a2\n' > "$P/plan_a2.md"
out="$(H --cwd "$P" prepare-split "$P/plan_a.md" --split-child "$P/plan_a1.md" \
        --split-child "$P/plan_a2.md" --split-rationale "still two concerns" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PASS (7) the resulting chain depth 2'; } \
  && ok "(G1) depth 2 is allowed under split_depth_cap 2" \
  || bad "(G1) depth 2 refused under cap 2"
# plan_a's counter stops AT max_block: the review that would be round 3 halts
# instead of recording an attempt, so the phrase names round 2.
printf 'record split for plan_a into 2 at round 2\n' | \
  RS --cwd "$P" record-split "$P/plan_a.md" --split-child "$P/plan_a1.md" \
     --split-child "$P/plan_a2.md" --split-rationale "still two concerns" \
     --i-am-recording-a-state-changing-decision >/dev/null 2>&1
drive "$P" "$P/plan_a1.md" 2 grandchild
printf 'x\n' > "$P/plan_a1x.md"; printf 'y\n' > "$P/plan_a1y.md"
out="$(H --cwd "$P" prepare-split "$P/plan_a1.md" --split-child "$P/plan_a1x.md" \
        --split-child "$P/plan_a1y.md" --split-rationale "narrower again" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'FAIL (7) the resulting chain depth 3'; } \
  && ok "(G2) depth 3 is refused: the chain, not the cycle, is what is capped" \
  || bad "(G2) the depth cap did not stop a third generation"

# ---------------------------------------------------------------------------
# H. FLAG SCOPE -- --split-* must not be silently ignored elsewhere
# ---------------------------------------------------------------------------
out="$(H --cwd "$P" --reviewer claude review "$P/plan_b.md" --split-child "$P/plan_a.md" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'only valid with prepare-split or record-split'; } \
  && ok "(H1) --split-* on a review call is rejected, not ignored" \
  || bad "(H1) --split-* silently accepted on a review call"
out="$(H --cwd "$P" prepare-marker "$P/plan_b.md" --split-child "$P/plan_a.md" 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'only valid with prepare-split or record-split'; } \
  && ok "(H2) --split-* on a marker verb is rejected" \
  || bad "(H2) --split-* accepted on a marker verb"

# ---------------------------------------------------------------------------
# I. UNAUDITABLE SPLIT -- the compensating append, and what it restores
# ---------------------------------------------------------------------------
A="$TMP/audit"; mkdir -p "$A/.sdp"; printf 'plan\n' > "$A/plan.md"
printf 'a\n' > "$A/a.md"; printf 'b\n' > "$A/b.md"; gates "$A" 2 2
drive "$A" "$A/plan.md" 2 audit
H --cwd "$A" --reviewer claude review "$A/plan.md" >/dev/null 2>&1
ALOG="$(logpath "$A" "$A/plan.md")"
rm -f "$A/.private/sdp-artifacts/gate-audit.ndjson"
mkdir -p "$A/.private/sdp-artifacts/gate-audit.ndjson"   # a directory: the append must fail
out="$(printf 'record split for plan into 2 at round 2\n' | \
        RS --cwd "$A" record-split "$A/plan.md" --split-child "$A/a.md" --split-child "$A/b.md" \
           --split-rationale "two concerns" --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'SPLIT_AUDIT_FAILED'; } \
  && ok "(I1) an unauditable split reports INFRA_ERROR, not success" \
  || bad "(I1) unauditable split did not surface as INFRA_ERROR"
grep -q '^SPLIT_AUDIT_FAILED' "$ALOG" \
  && ok "(I2) the compensating line is appended" || bad "(I2) no SPLIT_AUDIT_FAILED line"
out="$(H --cwd "$A" --reviewer claude review "$A/plan.md" 2>&1)"
printf '%s' "$out" | grep -q 'artifact was split' \
  && bad "(I3) the parent stayed sealed by a split nothing audited" \
  || ok "(I3) the invalidated split leaves the parent halted, not sealed"

# ---------------------------------------------------------------------------
# J. WHAT THE CODEX REVIEW OF THIS CHANGE FOUND (F1-F4)
#    Freshness is decided under the child's own lock and over the WHOLE log, a
#    split that does not commit retracts its seeds, and a byte-identical child is
#    refused.
# ---------------------------------------------------------------------------
J="$TMP/fresh"; mkdir -p "$J/.sdp"; printf 'plan\n' > "$J/plan.md"
printf 'child a\n' > "$J/a.md"; printf 'child b\n' > "$J/b.md"; gates "$J" 2 2
drive "$J" "$J/plan.md" 2 fresh
H --cwd "$J" --reviewer claude review "$J/plan.md" >/dev/null 2>&1

# (F2) an ALLOWed child carries state that never moves the counter.
set_claude_verdict "ALLOW: fine"
H --cwd "$J" --reviewer claude review "$J/a.md" >/dev/null 2>&1
# The dirty child is listed SECOND on purpose: the first child is seeded, then the
# refusal lands, so this also proves the retraction of an already-written seed.
out="$(printf 'record split for plan into 2 at round 2\n' | \
        RS --cwd "$J" record-split "$J/plan.md" --split-child "$J/b.md" --split-child "$J/a.md" \
           --split-rationale "two concerns" --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'already carries gate state'; } \
  && ok "(J1) a child that already passed a gate is refused (count==0 is not fresh)" \
  || bad "(J1) an ALLOWed child was adopted as a split child"
JLOG="$(logpath "$J" "$J/plan.md")"
grep -q '^SPLIT ' "$JLOG" && bad "(J2) the parent closed despite a refused child" \
  || ok "(J2) a refused child leaves the parent open"
grep -q '^SPLIT_CHILD_ABANDONED' "$(logpath "$J" "$J/b.md")" 2>/dev/null \
  && ok "(J3) seeds written before the refusal are retracted" \
  || bad "(J3) a seed survived a refused split"

# (F4) byte-identical children are the names-only split the refusals exist for.
K="$TMP/copy"; mkdir -p "$K/.sdp"; printf 'the whole plan\n' > "$K/plan.md"
cp "$K/plan.md" "$K/copy1.md"; cp "$K/plan.md" "$K/copy2.md"; gates "$K" 2 2
set_claude_verdict "BLOCK: seed"
drive "$K" "$K/plan.md" 2 copy
H --cwd "$K" --reviewer claude review "$K/plan.md" >/dev/null 2>&1
out="$(H --cwd "$K" prepare-split "$K/plan.md" --split-child "$K/copy1.md" \
        --split-child "$K/copy2.md" --split-rationale "not really a split" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (8) no child is a byte-identical copy' \
  && ok "(J4) a child that is a copy of the parent is refused" \
  || bad "(J4) copies of the parent accepted as children"
printf 'genuinely narrower\n' > "$K/copy1.md"
out="$(H --cwd "$K" prepare-split "$K/plan.md" --split-child "$K/copy1.md" \
        --split-child "$K/copy2.md" --split-rationale "still a copy" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (8)' \
  && ok "(J5) one copy of the parent among the children is still refused" \
  || bad "(J5) a parent copy slipped through as a sibling"

# (F3) a split invalidated by an unauditable write must be RETRYABLE with the
#      same artifacts: the seeds are retracted, so the children are fresh again.
rmdir "$A/.private/sdp-artifacts/gate-audit.ndjson" 2>/dev/null
ACHILD="$(logpath "$A" "$A/a.md")"
grep -q '^SPLIT_CHILD_ABANDONED' "$ACHILD" \
  && ok "(J6) the invalidated split retracted its child seeds" \
  || bad "(J6) child seeds survived an invalidated split"
out="$(printf 'record split for plan into 2 at round 2\n' | \
        RS --cwd "$A" record-split "$A/plan.md" --split-child "$A/a.md" --split-child "$A/b.md" \
           --split-rationale "two concerns" --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^SPLIT: plan.md closed'; } \
  && ok "(J7) the same split can be retried after the failure is cleared" \
  || bad "(J7) an invalidated split left the artifacts permanently unsplittable"
grep -qE '^SPLIT_CHILD_OF .* depth=1' "$ACHILD" \
  && ok "(J8) the retry seeds a live link at the right depth" \
  || bad "(J8) retry did not seed the child"

# ---------------------------------------------------------------------------
# K. ROUND-2 REVIEW FINDINGS -- the retraction must name the seed it retracts,
#    and the content comparison must fail closed.
# ---------------------------------------------------------------------------
seed_child() {   # $1 = project, $2 = child artifact, $3.. = extra log lines
  local proj="$1" art="$2"; shift 2
  local log; log="$(logpath "$proj" "$art")"
  mkdir -p "$(dirname "$log")"
  printf 'SPLIT_CHILD_OF 2026-01-01T00:00:00Z parent=other_deadbeef parent_round=4 depth=1\n' > "$log"
  for extra in "$@"; do printf '%s\n' "$extra" >> "$log"; done
  printf '%s' "$log"
}

L="$TMP/residue"; mkdir -p "$L/.sdp"; printf 'plan\n' > "$L/plan.md"
printf 'child a\n' > "$L/a.md"; printf 'child b\n' > "$L/b.md"; gates "$L" 2 2
set_claude_verdict "BLOCK: seed"
drive "$L" "$L/plan.md" 2 residue
H --cwd "$L" --reviewer claude review "$L/plan.md" >/dev/null 2>&1

# A live seed from ANOTHER parent is state: this child is spoken for.
seed_child "$L" "$L/a.md" >/dev/null
out="$(printf 'record split for plan into 2 at round 2\n' | \
        RS --cwd "$L" record-split "$L/plan.md" --split-child "$L/a.md" --split-child "$L/b.md" \
           --split-rationale "two concerns" --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'already carries gate state'; } \
  && ok "(K1) a child already seeded by another parent is refused" \
  || bad "(K1) a child owned by another split was adopted"

# An UNBOUND retraction must not clear that seed -- otherwise appending one line
# launders the chain depth away.
seed_child "$L" "$L/a.md" "SPLIT_CHILD_ABANDONED 2026-01-02T00:00:00Z" >/dev/null
out="$(printf 'record split for plan into 2 at round 2\n' | \
        RS --cwd "$L" record-split "$L/plan.md" --split-child "$L/a.md" --split-child "$L/b.md" \
           --split-rationale "two concerns" --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'already carries gate state'; } \
  && ok "(K2) a retraction naming no seed does not clear one" \
  || bad "(K2) an unbound SPLIT_CHILD_ABANDONED laundered a live seed"

# A retraction naming a DIFFERENT seed is equally inert.
seed_child "$L" "$L/a.md" \
  "SPLIT_CHILD_ABANDONED 2026-01-02T00:00:00Z parent=other_deadbeef seed=1999-01-01T00:00:00Z" >/dev/null
out="$(printf 'record split for plan into 2 at round 2\n' | \
        RS --cwd "$L" record-split "$L/plan.md" --split-child "$L/a.md" --split-child "$L/b.md" \
           --split-rationale "two concerns" --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'already carries gate state'; } \
  && ok "(K3) a retraction naming a different seed does not clear this one" \
  || bad "(K3) a mismatched retraction cleared a live seed"

# The matching retraction IS honoured -- that is what makes a failed split retryable.
seed_child "$L" "$L/a.md" \
  "SPLIT_CHILD_ABANDONED 2026-01-02T00:00:00Z parent=other_deadbeef seed=2026-01-01T00:00:00Z" >/dev/null
out="$(printf 'record split for plan into 2 at round 2\n' | \
        RS --cwd "$L" record-split "$L/plan.md" --split-child "$L/a.md" --split-child "$L/b.md" \
           --split-rationale "two concerns" --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^SPLIT: plan.md closed'; } \
  && ok "(K4) a retraction naming its own seed restores freshness" \
  || bad "(K4) a matched retraction did not restore freshness"

# Content comparison: unreadable and oversized children are refusals, not skips.
M="$TMP/content"; mkdir -p "$M/.sdp"; printf 'the plan\n' > "$M/plan.md"
printf 'a\n' > "$M/a.md"; printf 'b\n' > "$M/b.md"; gates "$M" 2 2
drive "$M" "$M/plan.md" 2 content
H --cwd "$M" --reviewer claude review "$M/plan.md" >/dev/null 2>&1
chmod 000 "$M/a.md"
out="$(H --cwd "$M" prepare-split "$M/plan.md" --split-child "$M/a.md" \
        --split-child "$M/b.md" --split-rationale "two concerns" 2>&1)"
chmod 644 "$M/a.md"
printf '%s' "$out" | grep -qE 'FAIL \(8\).*(unreadable|Permission)' \
  && ok "(K5) an unreadable child is refused, not silently skipped" \
  || bad "(K5) an unreadable child passed the content check"
python3 -c "open('$M/big.md','w').write('x' * 600000)"
out="$(H --cwd "$M" prepare-split "$M/plan.md" --split-child "$M/big.md" \
        --split-child "$M/b.md" --split-rationale "two concerns" 2>&1)"
printf '%s' "$out" | grep -q 'FAIL (8).*larger than the' \
  && ok "(K6) a child past the artifact cap is refused (a prefix hash would lie)" \
  || bad "(K6) an oversized child was compared by prefix"

# An append failure mid-seed must leave the parent unsealed. (The retraction
# itself cannot be observed here: the harness's append seam fails every call
# after the budget, so the compensating append fails too -- which is the
# fail-closed direction, the child stays visibly spoken for.)
FA="$TMP/appendfail"; mkdir -p "$FA/.sdp"; printf 'plan\n' > "$FA/plan.md"
printf 'a\n' > "$FA/a.md"; printf 'b\n' > "$FA/b.md"; gates "$FA" 2 2
drive "$FA" "$FA/plan.md" 2 appendfail
H --cwd "$FA" --reviewer claude review "$FA/plan.md" >/dev/null 2>&1
FALOG="$(logpath "$FA" "$FA/plan.md")"
out="$(printf 'record split for plan into 2 at round 2\n' | \
        SDP_MARKER_HUMAN=sekret python3 "$HARNESS" --binary-resolver "$RES" \
          --passwd-home "$HOMEFIX" --isatty true --append-fail-after 1 -- \
          --cwd "$FA" record-split "$FA/plan.md" --split-child "$FA/a.md" \
          --split-child "$FA/b.md" --split-rationale "two concerns" \
          --i-am-recording-a-state-changing-decision 2>&1)"; rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q '^SPLIT ' "$FALOG"; } \
  && ok "(K7) an append failure during seeding leaves the parent unsealed" \
  || bad "(K7) the parent closed despite a failed seed"

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
