#!/usr/bin/env bash
# bump.sh — ADR-007 (9a): in-tree acceptance for bump_codex_plugin_version.py.
# Every assertion here would have caught H2 (the build bumped 1 live / 1 dead /
# 0 Claude manifests) BEFORE it shipped. Runs with no cache — the 9b post-merge
# half (reading the refreshed plugin cache) is a separate manual verification.
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }; bad(){ F=$((F+1)); echo "FAIL - $1"; }

BUMPER="$SDP_ROOT/scripts/bump_codex_plugin_version.py"

# --- Build an isolated fixture tree so ROOT (= parents[1] of the script) is the
#     fixture, never the real repo. -------------------------------------------
make_fixture() {
  local fx claude_ver codex_ver
  fx="$1"; claude_ver="$2"; codex_ver="$3"
  mkdir -p "$fx/scripts" "$fx/plugins/sdp/.claude-plugin" "$fx/plugins/sdp/.codex-plugin"
  cp "$BUMPER" "$fx/scripts/bump_codex_plugin_version.py"
  printf '{\n  "name": "sdp",\n  "version": "%s"\n}\n' "$claude_ver" > "$fx/plugins/sdp/.claude-plugin/plugin.json"
  printf '{\n  "name": "sdp",\n  "version": "%s"\n}\n' "$codex_ver"  > "$fx/plugins/sdp/.codex-plugin/plugin.json"
}
jver() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$1"; }

# --- 1. Claude manifest gets a REAL patch increment (semver, no +build) -------
FX="$(mktemp -d -t sdp_bump.XXXXXX)"; trap 'rm -rf "$FX"' EXIT
make_fixture "$FX" "0.1.2" "0.1.0+codex.20260101000000"
if python3 "$FX/scripts/bump_codex_plugin_version.py" >/dev/null 2>&1; then
  cv="$(jver "$FX/plugins/sdp/.claude-plugin/plugin.json")"
  [ "$cv" = "0.1.3" ] && ok "claude manifest patch-incremented (0.1.2 -> 0.1.3)" \
                       || bad "claude manifest patch increment (got $cv)"
  xv="$(jver "$FX/plugins/sdp/.codex-plugin/plugin.json")"
  echo "$xv" | grep -Eq '^0\.1\.0\+codex\.[0-9]{14}$' \
    && ok "codex manifest got +codex.<ts> (got $xv)" \
    || bad "codex manifest +codex.<ts> (got $xv)"
  # Two manifests, two DIFFERENT version strings — the old divergence check
  # (which raised 'versions diverged') must be gone.
  [ "$cv" != "$xv" ] && ok "two semantics coexist (no divergence check)" \
                     || bad "two semantics coexist"
else
  bad "bumper ran on a valid fixture"
fi
rm -rf "$FX"

# --- 2. L11 no-partial-write: an invalid manifest leaves EVERY file untouched.
#     The invalid one is the SECOND (codex) manifest, so a write-in-loop bumper
#     would already have written the FIRST (claude) manifest -> this FAILS
#     against the pre-L11 code and passes only with read-all-then-write. -------
FX2="$(mktemp -d -t sdp_bump.XXXXXX)"; trap 'rm -rf "$FX2"' EXIT
make_fixture "$FX2" "0.1.2" "0.1.0+codex.20260101000000"
printf '{\n  "name": "sdp"\n}\n' > "$FX2/plugins/sdp/.codex-plugin/plugin.json"  # no version
before="$(cat "$FX2/plugins/sdp/.claude-plugin/plugin.json")"
if python3 "$FX2/scripts/bump_codex_plugin_version.py" >/dev/null 2>&1; then
  bad "bumper must fail closed on an invalid manifest"
else
  after="$(cat "$FX2/plugins/sdp/.claude-plugin/plugin.json")"
  [ "$before" = "$after" ] && ok "L11: no partial write on invalid manifest" \
                           || bad "L11: claude manifest was written before the failure"
fi
rm -rf "$FX2"

# --- 3. The dead root .codex-plugin/plugin.json is gone from the real repo. ---
[ ! -e "$SDP_ROOT/.codex-plugin/plugin.json" ] \
  && ok "dead root .codex-plugin/plugin.json removed" \
  || bad "dead root .codex-plugin/plugin.json still present"

echo "-------- $P passed, $F failed --------"; [ "$F" -eq 0 ]
