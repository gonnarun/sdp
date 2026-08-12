#!/usr/bin/env bash
# adapters.sh — plugin command adapters resolve/consistency check.
# Verifies: plugin.json is valid JSON and its commands key points at a real dir;
# the three adapter files exist with well-formed frontmatter; and each adapter
# references the anchor script + SDP core it is supposed to drive (thin-adapter
# contract). No model calls — pure static resolve, in the smoke/gate test style.
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SDP_ROOT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# 1. manifest valid JSON + commands key resolves to a real dir (relative to the
#    plugin root, which moved under plugins/sdp/ at P11).
MANIFEST="plugins/sdp/.claude-plugin/plugin.json"
python3 -m json.tool "$MANIFEST" >/dev/null 2>&1 && ok "plugin.json is valid JSON" || bad "plugin.json invalid JSON"
CMD="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("commands",""))' "$MANIFEST" 2>/dev/null)"
[ "$CMD" = "./commands" ] && ok "manifest commands = ./commands" || bad "manifest commands key = '$CMD' (expected ./commands)"
[ -d "plugins/sdp/${CMD#./}" ] && ok "commands/ dir resolves" || bad "commands/ dir missing (dangling manifest ref)"

# 2. all three host-divergent SDP adapters exist in BOTH host trees, with
# well-formed frontmatter and the thin-adapter contract. Generator skips these.
for tree in commands plugins/sdp/commands; do
  for c in sdp batch-sdp worktree-dispatch; do
    f="$tree/$c.md"
    if [ ! -f "$f" ]; then bad "$f missing"; continue; fi
    fm="$(awk 'NR==1{if($0!="---") exit 1} NR>1 && $0=="---"{print "ok"; exit 0}' "$f" && echo y)"
    [ -n "$fm" ] && ok "$f has well-formed --- frontmatter ---" || bad "$f frontmatter malformed"
    grep -q '^description:' "$f" && ok "$f has description" || bad "$f missing description"
    # thin-adapter contract: drives the anchor + the shared core
    grep -q 'sdp-anchor.sh' "$f" && ok "$f drives sdp-anchor.sh" || bad "$f does not call the anchor"
    grep -q 'core/SDP.md'   "$f" && ok "$f drives core/SDP.md"   || bad "$f does not load the core"
  done
done

# 3. utility commands exist, with well-formed frontmatter
# shellcheck disable=SC2043  # single item today; kept as a loop for future utility commands
for c in precompact; do
  f="commands/$c.md"
  if [ ! -f "$f" ]; then bad "$f missing"; continue; fi
  fm="$(awk 'NR==1{if($0!="---") exit 1} NR>1 && $0=="---"{print "ok"; exit 0}' "$f" && echo y)"
  [ -n "$fm" ] && ok "$f has well-formed --- frontmatter ---" || bad "$f frontmatter malformed"
  grep -q '^description:' "$f" && ok "$f has description" || bad "$f missing description"
done

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
