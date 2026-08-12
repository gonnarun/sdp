#!/usr/bin/env bash
# codex_plugin.sh — Codex plugin packaging/static contract.
# shellcheck disable=SC2015,SC2016 # existing compact assertions; literal backticks are intentional
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
cd "$SDP_ROOT" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

PLUGIN="plugins/sdp"
MANIFEST="$PLUGIN/.codex-plugin/plugin.json"
CLAUDE_MANIFEST="$PLUGIN/.claude-plugin/plugin.json"  # moved under the plugin root at P11

# The dead root .codex-plugin/plugin.json is removed (P1/REQ-004): no host reads
# it, and the bump path is now Claude patch + codex +codex.<ts>, two semantics.
[ ! -e ".codex-plugin/plugin.json" ] && ok "dead root .codex-plugin/plugin.json removed" || bad "dead root .codex-plugin/plugin.json still present"

python3 -m json.tool "$MANIFEST" >/dev/null 2>&1 && ok "Codex plugin manifest is valid JSON" || bad "Codex plugin manifest invalid JSON"
python3 -m json.tool "$CLAUDE_MANIFEST" >/dev/null 2>&1 && ok "Claude plugin manifest is valid JSON" || bad "Claude plugin manifest invalid JSON"
[ -f "$PLUGIN/scripts/config_discovery.py" ] \
  && ok "Claude/Codex plugin payload ships config_discovery.py" \
  || bad "plugin payload missing config_discovery.py"
SKILLS="$(python3 -c 'import json;print(json.load(open("plugins/sdp/.codex-plugin/plugin.json")).get("skills",""))' 2>/dev/null)"
[ "$SKILLS" = "./skills/" ] && ok "Codex plugin manifest skills path = ./skills/" || bad "Codex plugin skills path = '$SKILLS'"

# Host-divergent MCP manifests (OQ-1): Claude reads .mcp.json (${CLAUDE_PLUGIN_ROOT},
# no cwd -- Claude expands the var); codex reads .mcp.codex.json (cwd:".", no ${ in
# args -- codex resolves cwd against the cache dir and does NOT expand vars). Neither
# manifest may carry the other host's form.
python3 - "$PLUGIN/.mcp.json" <<'PY' && ok "Claude .mcp.json: no cwd, plugin-root var in args" || bad "Claude .mcp.json host form wrong"
import json, sys
s = json.load(open(sys.argv[1]))["mcpServers"]["sdp_review_gate"]
raise SystemExit(0 if "cwd" not in s and any("${CLAUDE_PLUGIN_ROOT}" in a for a in s["args"]) else 1)
PY
python3 - "$PLUGIN/.mcp.codex.json" <<'PY' && ok "codex .mcp.codex.json: cwd set, no unexpanded var in args" || bad "codex .mcp.codex.json host form wrong"
import json, sys
s = json.load(open(sys.argv[1]))["mcpServers"]["sdp_review_gate"]
raise SystemExit(0 if s.get("cwd") == "." and all("${" not in a for a in s["args"]) else 1)
PY
MREF="$(python3 -c 'import json;print(json.load(open("plugins/sdp/.codex-plugin/plugin.json")).get("mcpServers"))')"
[ "$MREF" = "./.mcp.codex.json" ] && ok "codex plugin.json mcpServers -> ./.mcp.codex.json" || bad "codex mcpServers ref = '$MREF' (want ./.mcp.codex.json)"

for keyword in batch-sdp worktree-dispatch precompact; do
  python3 - "$keyword" <<'PY' && ok "Codex plugin manifest keyword present: $keyword" || bad "Codex plugin manifest missing keyword: $keyword"
import json, sys
kw = sys.argv[1]
data = json.load(open("plugins/sdp/.codex-plugin/plugin.json"))
raise SystemExit(0 if kw in data.get("keywords", []) else 1)
PY
done

for skill in sdp batch-sdp worktree-dispatch; do
  f="$PLUGIN/skills/$skill/SKILL.md"
  if [ ! -f "$f" ]; then bad "Codex skill missing: $skill"; continue; fi
  grep -q "^name: $skill$" "$f" && ok "Codex skill present: $skill" || bad "Codex skill name mismatch: $skill"
  grep -q 'review-gate' "$f" && ok "$skill skill labels review gate" || bad "$skill skill missing review gate label"

  rf="skills/$skill/SKILL.md"
  if [ ! -f "$rf" ]; then bad "Root Codex skill missing: $skill"; continue; fi
  grep -q "^name: $skill$" "$rf" && ok "Root Codex skill present: $skill" || bad "Root Codex skill name mismatch: $skill"
  grep -q 'review-gate' "$rf" && ok "Root $skill skill labels review gate" || bad "Root $skill skill missing review gate label"
done

# shellcheck disable=SC2043  # single item today; kept as a loop for future utility skills
for skill in precompact; do
  f="$PLUGIN/skills/$skill/SKILL.md"
  if [ ! -f "$f" ]; then bad "Codex utility skill missing: $skill"; continue; fi
  grep -q "^name: $skill$" "$f" && ok "Codex utility skill present: $skill" || bad "Codex utility skill name mismatch: $skill"
  grep -qF '.private/precompact/{YYYYMMDD}/precompact_{topic}.md' "$f" && ok "$skill skill defines private snapshot file pattern" || bad "$skill skill missing private snapshot file pattern"

  rf="skills/$skill/SKILL.md"
  if [ ! -f "$rf" ]; then bad "Root Codex utility skill missing: $skill"; continue; fi
  grep -q "^name: $skill$" "$rf" && ok "Root Codex utility skill present: $skill" || bad "Root Codex utility skill name mismatch: $skill"
  grep -qF '.private/precompact/{YYYYMMDD}/precompact_{topic}.md' "$rf" && ok "Root $skill skill defines private snapshot file pattern" || bad "Root $skill skill missing private snapshot file pattern"
done

[ -f "commands/precompact.md" ] && ok "Claude command present: precompact" || bad "Claude command missing: precompact"
[ -f ".codex/prompts/precompact.md" ] && ok "Codex prompt present: precompact" || bad "Codex prompt missing: precompact"
grep -qxF '.private/' .gitignore && ok ".private/ is gitignored for private runtime artifacts" || bad ".private/ missing from .gitignore"

if grep -RqsF '.references' \
  "commands/precompact.md" \
  ".codex/prompts/precompact.md" \
  "skills/precompact" \
  "$PLUGIN/commands/precompact.md" \
  "$PLUGIN/skills/precompact" \
  ".agents/skills/precompact"; then
  bad "precompact assets contain legacy Project-A path text (.references)"
else
  ok "precompact assets avoid legacy Project-A path text"
fi

# English-only rule (core/SDP.md deliverable-language): shipped precompact assets must be ASCII.
# LC_ALL=C + [^ -~] is byte-wise and portable across BSD/GNU grep; catches any non-ASCII (e.g. legacy Korean path words).
if LC_ALL=C grep -Rqs '[^ -~]' \
  "commands/precompact.md" \
  ".codex/prompts/precompact.md" \
  "skills/precompact" \
  "$PLUGIN/commands/precompact.md" \
  "$PLUGIN/skills/precompact" \
  ".agents/skills/precompact"; then
  bad "precompact assets contain non-ASCII text (English-only rule)"
else
  ok "precompact assets are ASCII-only (English-only rule)"
fi

grep -q 'review-gate: plan review' "$PLUGIN/core/SDP.md" && ok "Codex core progress shows review-gate plan review" || bad "Codex core plan gate label stale"
grep -q 'review-gate: test-result review' "$PLUGIN/core/SDP.md" && ok "Codex core progress shows review-gate test-result review" || bad "Codex core test gate label stale"

if grep -Rqs 'scripts/claude-gate.sh' "$PLUGIN/core" "$PLUGIN/commands" "$PLUGIN/skills"; then
  bad "Codex plugin references nonexistent scripts/claude-gate.sh"
else
  ok "Codex plugin does not reference nonexistent scripts/claude-gate.sh"
fi

if grep -RqsE 'codex-gate: plan review|codex-gate: test-result review' "$PLUGIN/core" "$PLUGIN/skills" "core" "skills"; then
  bad "Plugin still displays stale codex-gate progress labels (either tree)"
else
  ok "No stale codex-gate progress labels in either tree"
fi

ROOT_SDP_SKILL="skills/sdp/SKILL.md"
PACKAGED_SDP_SKILL="$PLUGIN/skills/sdp/SKILL.md"
if cmp -s "$ROOT_SDP_SKILL" "$PACKAGED_SDP_SKILL"; then
  ok "Root and packaged Codex SDP skills are byte-identical"
else
  bad "Root and packaged Codex SDP skills drifted"
fi

for marker in \
  'Codex Execution and Cost Profile' \
  'Planner, Evaluator, Researcher, Designer / `opus`' \
  'Explore, Security / `sonnet`' \
  'Runner / `haiku`' \
  'S | 0' \
  'M | 2' \
  'L | 3' \
  'XL | 5' \
  'no per-agent model, reasoning-effort, token, or billing selector' \
  'Adversarial Review-Gate Loop' \
  'Attempt 14 is forbidden'; do
  if grep -qF "$marker" "$ROOT_SDP_SKILL"; then
    ok "Codex SDP policy marker present: $marker"
  else
    bad "Codex SDP policy marker missing: $marker"
  fi
done

for marker in \
  'Stop immediately on the first `ALLOW:`' \
  '`BLOCK: INFRA_ERROR` does not increment' \
  'After 13 content `BLOCK:` verdicts' \
  'distinct question or file set' \
  'Record any required deviation'; do
  if grep -qF "$marker" "$ROOT_SDP_SKILL"; then
    ok "Codex SDP invariant present: $marker"
  else
    bad "Codex SDP invariant missing: $marker"
  fi
done

for stage in 1 2 3 4 5 6 7 8; do
  if grep -qF "| $stage |" "$ROOT_SDP_SKILL"; then
    ok "Codex SDP stage placement present: Stage $stage"
  else
    bad "Codex SDP stage placement missing: Stage $stage"
  fi
done

if grep -qF '| **Planner** | planner | opus |' core/SDP.md; then ok "Claude core preserves Planner/opus profile"; else bad "Claude core Planner/opus profile changed"; fi
if grep -qF '| Explorer | Explore | sonnet |' core/SDP.md; then ok "Claude core preserves Explore/sonnet profile"; else bad "Claude core Explore/sonnet profile changed"; fi
if grep -qF '| Runner | Bash | haiku |' core/SDP.md; then ok "Claude core preserves Bash/haiku profile"; else bad "Claude core Bash/haiku profile changed"; fi

if grep -qF 'Never ask agy after Claude returns a clean content `BLOCK:`' "$ROOT_SDP_SKILL"; then ok "Codex SDP preserves clean Claude BLOCK terminal rule"; else bad "Codex SDP clean Claude BLOCK terminal rule missing"; fi
if grep -qF 'runs Claude Code as a read-only reviewer' "$ROOT_SDP_SKILL"; then ok "Codex SDP preserves isolated read-only reviewer contract"; else bad "Codex SDP reviewer isolation contract missing"; fi

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
