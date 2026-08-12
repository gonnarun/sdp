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
mkdir -p "$GX/sdp"; cp "$SDP_ROOT/.sdp/defaults.yaml" "$GX/sdp/"; cp "$SDP_ROOT/.sdp/gates.yaml" "$GX/sdp/"
grt="$(CLAUDE_PROJECT_DIR="$PJ" XDG_CONFIG_HOME="$GX" bash "$SDP_ROOT/scripts/sdp-anchor.sh" 2>/dev/null)"
{ [ -f "$grt" ] && grep -qF "$(cd "$GX/sdp" && pwd -P)/defaults.yaml" "$grt" \
    && grep -qF "$(cd "$GX/sdp" && pwd -P)/gates.yaml" "$grt" \
    && [ -s "$PJ/.private/sdp-config-provenance.json" ]; } \
  && ok "global XDG defaults/gates used + provenance written" || bad "global config fallback/provenance"
# Claude Code executes the installed plugin copy, not the root mirror.
PJC="$(mktemp -d -t sdp_claude_proj.XXXXXX)"
crt="$(CLAUDE_PROJECT_DIR="$PJC" XDG_CONFIG_HOME="$GX" bash "$SDP_ROOT/plugins/sdp/scripts/sdp-anchor.sh" 2>/dev/null)"
{ [ -f "$crt" ] && grep -qF "$SDP_ROOT/plugins/sdp" "$crt" \
    && grep -qF "$(cd "$GX/sdp" && pwd -P)/defaults.yaml" "$crt" \
    && grep -qF "$(cd "$GX/sdp" && pwd -P)/gates.yaml" "$crt" \
    && [ -s "$PJC/.private/sdp-config-provenance.json" ]; } \
  && ok "Claude plugin anchor uses global config + plugin-local discovery module" \
  || bad "Claude plugin anchor/global config path"
# precedence: a project .sdp/ ALWAYS beats the global config.
PJ2="$(mktemp -d -t sdp_proj2.XXXXXX)"; mkdir -p "$PJ2/.sdp"; cp "$SDP_ROOT/.sdp/defaults.yaml" "$PJ2/.sdp/"; cp "$SDP_ROOT/.sdp/gates.yaml" "$PJ2/.sdp/"
prt="$(CLAUDE_PROJECT_DIR="$PJ2" XDG_CONFIG_HOME="$GX" bash "$SDP_ROOT/scripts/sdp-anchor.sh" 2>/dev/null)"
{ [ -f "$prt" ] && grep -qF "$(cd "$PJ2/.sdp" && pwd -P)/defaults.yaml" "$prt" \
    && grep -qF "$(cd "$PJ2/.sdp" && pwd -P)/gates.yaml" "$prt"; } \
  && ok "project .sdp/ beats global defaults/gates" || bad "project precedence"

# Unsafe higher-priority presence must stop anchor rather than fall through.
PJ3="$(mktemp -d -t sdp_proj3.XXXXXX)"; TARGET="$(mktemp -d -t sdp_target.XXXXXX)"
cp "$SDP_ROOT/.sdp/defaults.yaml" "$TARGET/defaults.yaml"; ln -s "$TARGET" "$PJ3/.sdp"
CLAUDE_PROJECT_DIR="$PJ3" XDG_CONFIG_HOME="$GX" bash "$SDP_ROOT/scripts/sdp-anchor.sh" >/dev/null 2>&1 \
  && bad "unsafe project .sdp symlink fell through" || ok "unsafe project config ancestor fails closed"
rm -rf "$GX" "$PJ" "$PJC" "$PJ2" "$PJ3" "$TARGET"

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


# --- anchor provenance + staleness reporting -------------------------------
# .sdp_runtime.env is written once per command entry and is NEVER refreshed by a
# plugin reinstall. Old plugin-cache versions stay on disk while live sessions
# hold them, so a stale SDP_ROOT still resolves and a different engine runs
# silently. doctor reports that; it must NOT enforce it, or every project whose
# last command entry predates the current install would go UNHEALTHY at once.
AP="$(mktemp -d -t sdp_anchor.XXXXXX)"
rt="$(CLAUDE_PROJECT_DIR="$AP" bash "$SDP_ROOT/scripts/sdp-anchor.sh" 2>/dev/null)"
{ grep -q "^SDP_VERSION=" "$rt" && grep -q "^ANCHORED_AT=" "$rt"; } \
  && ok "anchor records SDP_VERSION + ANCHORED_AT (provenance for staleness checks)" \
  || bad "anchor provenance fields missing"

aout="$(python3 "$SDP_ROOT/scripts/review_gate.py" --cwd "$AP" doctor 2>&1)"
printf '%s' "$aout" | grep -q "anchor: current" \
  && ok "doctor: freshly anchored project reports anchor current" \
  || { bad "doctor anchor current"; printf '%s\n' "$aout" | grep anchor: | sed 's/^/       /'; }

# Point the record at a directory that exists but is not this engine.
sed -i.bak "s|^SDP_ROOT=.*|SDP_ROOT='/tmp'|" "$rt" && rm -f "$rt.bak"
sout="$(python3 "$SDP_ROOT/scripts/review_gate.py" --cwd "$AP" doctor 2>&1)"; src=$?
aline="$(printf '%s' "$sout" | grep 'anchor:')"
{ printf '%s' "$aline" | grep -q "STALE" && printf '%s' "$aline" | grep -q "DIFFERENT engine"; } \
  && ok "doctor: stale anchor pointing at an existing other dir is reported as STALE" \
  || bad "doctor stale-anchor detection: $aline"

# The staleness must not move the health verdict -- compare against the fresh run.
fresh_health="$(printf '%s' "$aout" | grep -o 'health: [A-Z]*')"
stale_health="$(printf '%s' "$sout" | grep -o 'health: [A-Z]*')"
[ "$fresh_health" = "$stale_health" ] \
  && ok "doctor: a stale anchor is reported but does NOT change the health verdict" \
  || bad "stale anchor changed health ($fresh_health -> $stale_health, rc=$src)"
rm -rf "$AP"

echo "-------- $P passed, $F failed --------"; [ "$F" -eq 0 ]
