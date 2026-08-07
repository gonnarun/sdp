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
grep -q 'gate thresholds not weakened' "$TMP/good.out" && ok "clean fixture: gate-strength check ran" || bad "gate check missing"

# --- 2: WEAKENED gate (escalate_from 10) must FAIL ---
WEAK="$TMP/weak"; mkfixture "$WEAK" 10 13 false
if bash "$REG" "$WEAK" >"$TMP/weak.out" 2>&1; then bad "weakened gate should FAIL but passed"; else ok "harness DETECTS weakened escalate_from (non-zero exit)"; fi
grep -q 'gate weakened' "$TMP/weak.out" && ok "weakened gate: correct FAIL reason reported" || bad "weakened reason missing"

# --- 3: max_block raised above 13 must FAIL ---
WEAK2="$TMP/weak2"; mkfixture "$WEAK2" 6 20 false
bash "$REG" "$WEAK2" >/dev/null 2>&1 && bad "raised max_block should FAIL" || ok "harness DETECTS raised max_block (non-zero exit)"

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

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
