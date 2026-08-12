#!/usr/bin/env bash
# regression.sh — SELF-TEST for scripts/sdp-regression.sh.
# The 6 real reference projects (Project-A/Project-B/Project-C/Project-D/Project-E/
# Project-F) are NOT available in this session, so this proves the harness
# LOGIC against synthetic throwaway fixtures. It does NOT and cannot assert the
# real 6-project regression passed — that must be run natively (see KNOWN_GAPS).
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REG="$SDP_ROOT/scripts/sdp-regression.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d -t sdp_reg_test.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

mkfixture() { # $1=dir $2=escalate_from $3=max_block $4=require_checklist $5=include(optional)
  local d="$1"; mkdir -p "$d/.sdp"
  cat > "$d/.sdp/defaults.yaml" <<YAML
base_dir: .private/sdp-artifacts
output_locale: auto
forced_ext: {}
YAML
  cat > "$d/.sdp/gates.yaml" <<YAML
cadence:
  escalate_from: $2
halt:
  max_block: $3
require_checklist: $4
YAML
  [ -n "${5:-}" ] && printf 'review_checklist_include: %s\n' "$5" >> "$d/.sdp/gates.yaml"
}

# --- 1: clean PASS fixture (escalate_from 6, max_block 13, no checklist required) ---
GOOD="$TMP/good"; mkfixture "$GOOD" 6 13 false
if bash "$REG" "$GOOD" >"$TMP/good.out" 2>&1; then ok "harness PASSES a clean fixture (exit 0)"; else bad "clean fixture should pass ($(tail -1 "$TMP/good.out"))"; fi
grep -q 'anchor resolves' "$TMP/good.out" && ok "clean fixture: anchor check ran" || bad "anchor check missing"
grep -q 'at or below baseline' "$TMP/good.out" && ok "clean fixture: gate-strength check ran" || bad "gate check missing"

# --- 2: WEAKENED gate (escalate_from 10) must FAIL ---
WEAK="$TMP/weak"; mkfixture "$WEAK" 10 13 false
if bash "$REG" "$WEAK" >"$TMP/weak.out" 2>&1; then bad "weakened gate should FAIL but passed"; else ok "harness DETECTS weakened escalate_from (non-zero exit)"; fi
grep -qE 'gate weakened|relaxed past baseline' "$TMP/weak.out" && ok "weakened gate: correct FAIL reason reported" || bad "weakened reason missing"

# --- 3: max_block raised above 13 must FAIL ---
WEAK2="$TMP/weak2"; mkfixture "$WEAK2" 6 20 false
bash "$REG" "$WEAK2" >/dev/null 2>&1 && bad "raised max_block should FAIL" || ok "harness DETECTS raised max_block (non-zero exit)"

# --- 3b: BASELINE vs sanctioned envelope (codex review MEDIUM-3). The shipped
#         default is 6/1; going later/looser must NOT be certified silently just
#         because it sits under a wider ceiling. It requires an explicit
#         cadence.relaxation_ack, and the envelope still caps the declared value.
cad() {   # $1=dir  $2..=extra cadence: lines
  local d="$1"; shift
  { printf 'cadence:\n'; for l in "$@"; do printf '  %s\n' "$l"; done; } >> "$d/.sdp/gates.yaml"
}
BASE2="$TMP/base2"; mkfixture "$BASE2" 6 13 false
bash "$REG" "$BASE2" >"$TMP/base2.out" 2>&1 && ok "baseline 6/1 passes without any declaration" \
  || bad "baseline 6/1 should pass"
grep -q 'at or below baseline' "$TMP/base2.out" && ok "baseline: reported as baseline, not as a relaxation" \
  || bad "baseline reason missing"

NOACK="$TMP/noack"; mkfixture "$NOACK" 8 13 false
cad "$NOACK" "review_on: even" "marker_span: 4"
bash "$REG" "$NOACK" >"$TMP/noack.out" 2>&1 && bad "undeclared relaxation should FAIL" \
  || ok "harness DETECTS relaxation past baseline with no relaxation_ack"
grep -q 'without cadence.relaxation_ack' "$TMP/noack.out" \
  && ok "undeclared relaxation: correct FAIL reason reported" || bad "undeclared-relaxation reason missing"

ACK="$TMP/ack"; mkfixture "$ACK" 8 13 false
cad "$ACK" "review_on: even" "marker_span: 4" "relaxation_ack: declared-for-test"
bash "$REG" "$ACK" >"$TMP/ack.out" 2>&1 && ok "declared relaxation inside the envelope passes" \
  || bad "declared 8/4 should pass"
grep -q 'RELAXED within the sanctioned envelope' "$TMP/ack.out" \
  && ok "declared relaxation is reported LOUDLY, not as an ordinary ok" || bad "relaxation not reported loudly"

OVER="$TMP/over"; mkfixture "$OVER" 9 13 false
cad "$OVER" "relaxation_ack: declared-for-test"
bash "$REG" "$OVER" >/dev/null 2>&1 && bad "escalate_from=9 should FAIL even when declared" \
  || ok "harness DETECTS escalate_from past the envelope (9) despite a declaration"
SPANBAD="$TMP/spanbad"; mkfixture "$SPANBAD" 8 13 false
cad "$SPANBAD" "marker_span: 5" "relaxation_ack: declared-for-test"
bash "$REG" "$SPANBAD" >/dev/null 2>&1 && bad "marker_span=5 should FAIL even when declared" \
  || ok "harness DETECTS marker_span past the envelope (5) despite a declaration"

# --- 3c: the COMBINATION invariant (codex review HIGH-1). Both triples below are
#         inside the envelope and declared, yet every window anchor is TEAM_CARRY,
#         so fresh outputs= evidence is never demanded in rounds ef..max_block.
CARRY1="$TMP/carry1"; mkfixture "$CARRY1" 7 13 false
cad "$CARRY1" "review_on: even" "marker_span: 4" "relaxation_ack: declared-for-test"
bash "$REG" "$CARRY1" >"$TMP/carry1.out" 2>&1 && bad "ef=7/span=4/even should FAIL (all-CARRY)" \
  || ok "harness DETECTS all-TEAM_CARRY cadence (escalate_from=7, span=4, review_on=even)"
grep -q 'never demands a TEAM_REVIEW' "$TMP/carry1.out" \
  && ok "all-CARRY: correct FAIL reason reported" || bad "all-CARRY reason missing"
CARRY2="$TMP/carry2"; mkfixture "$CARRY2" 8 13 false
cad "$CARRY2" "review_on: odd" "marker_span: 4" "relaxation_ack: declared-for-test"
bash "$REG" "$CARRY2" >/dev/null 2>&1 && bad "ef=8/span=4/odd should FAIL (all-CARRY)" \
  || ok "harness DETECTS all-TEAM_CARRY cadence (escalate_from=8, span=4, review_on=odd)"

# --- 3d: the escalation range is HALF-OPEN [escalate_from, max_block) because the
#         runtime returns the max_block halt BEFORE the cadence block. Counting the
#         halted round can invent a TEAM_REVIEW that never executes (codex F2).
#         Both fixtures below have span=1 and sit inside the envelope, yet their
#         only LIVE escalation round is a TEAM_CARRY.
EDGE1="$TMP/edge1"; mkfixture "$EDGE1" 7 8 false      # live range = {7} -> anchor 7 odd -> CARRY
cad "$EDGE1" "review_on: even" "relaxation_ack: declared-for-test"
bash "$REG" "$EDGE1" >"$TMP/edge1.out" 2>&1 && bad "ef=7/max_block=8/span=1/even should FAIL (halted round 8 is not a window)" \
  || ok "harness EXCLUDES the halted round (escalate_from=7, max_block=8, review_on=even)"
grep -q 'never demands a TEAM_REVIEW' "$TMP/edge1.out" \
  && ok "half-open range: correct FAIL reason reported" || bad "half-open range reason missing"
EDGE2="$TMP/edge2"; mkfixture "$EDGE2" 6 7 false      # live range = {6} -> anchor 6 even, review_on odd -> CARRY
cad "$EDGE2" "review_on: odd"
bash "$REG" "$EDGE2" >/dev/null 2>&1 && bad "ef=6/max_block=7/span=1/odd should FAIL (all-CARRY)" \
  || ok "harness DETECTS all-CARRY at BASELINE 6/1 too (max_block=7, review_on=odd)"

# --- 3e: escalate_from >= max_block is EARLIER/STRICTER, not a weakening. With no
#         permissive escalation round the reviewer can never return ALLOW under a
#         TEAM_CARRY-only cadence -- the gate halts and demands a human instead. The
#         existential must therefore NOT fire on an empty range: rejecting it would
#         invent an unspecced `escalate_from < max_block` requirement and refuse a
#         STRONGER config than the baseline (codex review, F3).
NOESC="$TMP/noesc"; mkfixture "$NOESC" 6 6 false
bash "$REG" "$NOESC" >"$TMP/noesc.out" 2>&1 && ok "harness ACCEPTS ef>=max_block as halt-first/stricter (ef=6, max_block=6)" \
  || bad "empty escalation range wrongly rejected as weakened ($(grep -m1 'FAIL' "$TMP/noesc.out"))"
grep -q 'no permissive escalation window' "$TMP/noesc.out" \
  && ok "empty range: reported as halt-first, not as a cadence weakening" || bad "empty-range reason missing"

# --- 3f: the harness verdict must not depend on the caller's cwd (codex F1) ----
CWDI="$TMP/cwdi"; mkfixture "$CWDI" 6 13 true ".sdp/project-rules.md"
echo "domain rules" > "$CWDI/.sdp/project-rules.md"
r_repo=0; r_root=0
bash "$REG" "$CWDI" >/dev/null 2>&1 || r_repo=$?
( cd / && bash "$REG" "$CWDI" >/dev/null 2>&1 ) || r_root=$?
{ [ "$r_repo" -eq 0 ] && [ "$r_root" -eq 0 ]; } \
  && ok "harness verdict is cwd-independent (relative include resolves under the PROJECT)" \
  || bad "harness verdict depends on caller cwd (repo=$r_repo, /=$r_root)"

# --- 4: require_checklist=true with NO include -> fail-closed FAIL (AC-12) ---
NOINC="$TMP/noinc"; mkfixture "$NOINC" 6 13 true
if bash "$REG" "$NOINC" >"$TMP/noinc.out" 2>&1; then bad "require_checklist w/o include should FAIL"; else ok "harness DETECTS missing checklist include (fail-closed, AC-12)"; fi
grep -q 'would BLOCK' "$TMP/noinc.out" && ok "fail-closed: correct AC-12 reason reported" || bad "fail-closed reason missing"

# --- 5: require_checklist=true WITH a non-empty include -> passes ---
OKINC="$TMP/okinc"; mkfixture "$OKINC" 6 13 true ".sdp/project-rules.md"
echo "domain rules" > "$OKINC/.sdp/project-rules.md"
bash "$REG" "$OKINC" >/dev/null 2>&1 && ok "require_checklist + present include -> passes" || bad "valid checklist include should pass"

# --- 6: no projects configured -> neutral skip, exit 0 ---
out="$(SDP_REGRESSION_PROJECTS='' bash "$REG" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$out" | grep -qi 'neutral skip'; } && ok "no projects -> neutral skip (exit 0)" || bad "no-projects skip (rc=$rc)"

# --- 7: missing project dir -> FAIL (not a silent pass) ---
bash "$REG" "$TMP/does-not-exist" >/dev/null 2>&1 && bad "missing project dir should FAIL" || ok "harness FAILS on missing project dir"

# --- 8: user-global-only config is a valid harness input ---------------------
GLOBAL="$TMP/global-only"; GX="$TMP/global-xdg"; mkdir -p "$GLOBAL" "$GX/sdp"
cat > "$GX/sdp/defaults.yaml" <<YAML
base_dir: .private/sdp-artifacts
output_locale: auto
forced_ext: {}
YAML
cat > "$GX/sdp/gates.yaml" <<YAML
cadence:
  escalate_from: 6
halt:
  max_block: 13
require_checklist: false
YAML
XDG_CONFIG_HOME="$GX" bash "$REG" "$GLOBAL" >"$TMP/global.out" 2>&1 \
  && ok "harness accepts global-only defaults/gates" || bad "global-only harness failed ($(tail -1 "$TMP/global.out"))"

# --- 9: unsafe higher-priority candidate fails, never falls through ----------
UNSAFE="$TMP/unsafe"; mkdir -p "$UNSAFE" "$TMP/unsafe-target"
printf 'base_dir: .private/sdp-artifacts\n' > "$TMP/unsafe-target/defaults.yaml"
ln -s "$TMP/unsafe-target" "$UNSAFE/.sdp"
XDG_CONFIG_HOME="$GX" bash "$REG" "$UNSAFE" >/dev/null 2>&1 \
  && bad "unsafe local config ancestor should not fall through to global" \
  || ok "harness fails closed on unsafe local config ancestor"

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
