#!/usr/bin/env bash
# smoke.sh — SDP boots: anchor writes runtime env, doctor runs, config reads.
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }; bad(){ F=$((F+1)); echo "FAIL - $1"; }

TMP="$(mktemp -d -t sdp_smoke.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.sdp"; cp "$SDP_ROOT/.sdp/defaults.yaml" "$TMP/.sdp/"; cp "$SDP_ROOT/.sdp/gates.yaml" "$TMP/.sdp/"

rt="$(CLAUDE_PROJECT_DIR="$TMP" bash "$SDP_ROOT/scripts/sdp-anchor.sh")"
[ -f "$rt" ] && grep -q '^BASE_DIR=' "$rt" && ok "anchor writes runtime env" || bad "anchor runtime env"
[ -d "$TMP/.private" ] && grep -qxF '.private/' "$TMP/.gitignore" && ok ".private created + gitignored" || bad ".private/gitignore"
grep -q '^OUTPUT_LOCALE=' "$rt" && ok "output_locale resolved" || bad "output_locale"

# global config fallback (REQ-U-05): no project .sdp/, a user-global XDG config is used.
GX="$(mktemp -d -t sdp_xdg.XXXXXX)"; PJ="$(mktemp -d -t sdp_proj.XXXXXX)"
mkdir -p "$GX/sdp"; cp "$SDP_ROOT/.sdp/defaults.yaml" "$GX/sdp/"
grt="$(CLAUDE_PROJECT_DIR="$PJ" XDG_CONFIG_HOME="$GX" bash "$SDP_ROOT/scripts/sdp-anchor.sh" 2>/dev/null)"
{ [ -f "$grt" ] && grep -qF "$GX/sdp/defaults.yaml" "$grt"; } \
  && ok "global XDG config used when project ships no .sdp/" || bad "global config fallback"
# precedence: a project .sdp/ ALWAYS beats the global config.
PJ2="$(mktemp -d -t sdp_proj2.XXXXXX)"; mkdir -p "$PJ2/.sdp"; cp "$SDP_ROOT/.sdp/defaults.yaml" "$PJ2/.sdp/"
prt="$(CLAUDE_PROJECT_DIR="$PJ2" XDG_CONFIG_HOME="$GX" bash "$SDP_ROOT/scripts/sdp-anchor.sh" 2>/dev/null)"
{ [ -f "$prt" ] && grep -qF "$PJ2/.sdp/defaults.yaml" "$prt"; } \
  && ok "project .sdp/ beats global config (precedence)" || bad "project precedence"
rm -rf "$GX" "$PJ" "$PJ2"

# doctor reports TWO axes and exits non-zero if either is unhealthy: `toolchain`
# (is a primary reviewer trustably resolvable) and `gate-state` (is any artifact
# wedged). A clean CI runner and a fresh clone have NEITHER `codex` nor `claude`
# installed, so a non-zero exit there is doctor working correctly, not a defect.
# Assert the axis this suite owns -- gate-state -- and skip the toolchain axis
# when no reviewer is present, in the same shape as tests/run_segment.sh.
dout="$(python3 "$SDP_ROOT/scripts/review_gate.py" --cwd "$TMP" doctor 2>&1)"; drc=$?
if [ "$drc" -eq 0 ]; then
  ok "review gate doctor exit 0"
elif printf '%s' "$dout" | grep -qF 'gate-state=ok'; then
  echo "SKIP - no primary reviewer CLI (codex/claude) resolvable; toolchain axis not exercised"
  ok "review gate doctor: gate-state ok"
else
  bad "review gate doctor"
  printf '%s\n' "$dout" | sed 's/^/       /'
fi

echo "-------- $P passed, $F failed --------"; [ "$F" -eq 0 ]
