#!/usr/bin/env bash
# run.sh — the single test entry point (ADR-007 (5)).
#
#   run.sh --fast   regen-check + orphan-detector + packaging + smoke + lint.
#                   Seconds, no model calls. Wired into pre-commit at P11.
#   run.sh          the full suite: every command in every test.layers.* layer,
#                   read from .sdp/defaults.yaml. Stage 7 runs this.
#
# The orphan detector is what stops the NEXT 11 orphans: every tests/*.sh must be
# reachable from exactly one test.commands.<layer>, and every layer entry must
# resolve to a defined command. Wiring alone (without it) rebuilds the factory.
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
cd "$SDP_ROOT" || exit 1

DEFAULTS=".sdp/defaults.yaml"
FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

fails=0
step() {
  local name="$1"; shift
  printf '\n===== %s =====\n' "$name"
  if "$@"; then
    echo "[OK] $name"
  else
    echo "[FAIL] $name"
    fails=$((fails + 1))
  fi
}

regen_check() { python3 scripts/build_plugin_tree.py --check; }

orphan_detector() {
  python3 - "$DEFAULTS" <<'PY'
import re, sys, pathlib
defaults = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()

commands, layers = {}, {}
section = None            # None | "commands" | "layers"
in_test = False
for line in defaults:
    if re.match(r"^\S", line):                 # top-level key -> leaves test:
        in_test = line.startswith("test:")
        section = None
        continue
    if not in_test:
        continue
    if re.match(r"^  commands:\s*$", line):
        section = "commands"; continue
    if re.match(r"^  layers:\s*$", line):
        section = "layers"; continue
    if re.match(r"^  \S", line):               # another key under test:
        section = None; continue
    if section == "commands":
        m = re.match(r'^    (\w+):\s*"(.*)"\s*$', line)
        if m:
            commands[m.group(1)] = m.group(2)
    elif section == "layers":
        m = re.match(r"^    (\w+):\s*\[(.*)\]\s*$", line)
        if m:
            items = [x.strip() for x in m.group(2).split(",") if x.strip()]
            layers[m.group(1)] = items

problems = []

# every layer entry resolves to a defined command
for layer, entries in layers.items():
    for name in entries:
        if name not in commands:
            problems.append(f"layer {layer}: undefined command {name!r}")

# every tests/*.sh reachable from exactly one command
test_files = sorted(p.name for p in pathlib.Path("tests").glob("*.sh") if p.name != "run.sh")
joined = " ".join(commands.values())
for tf in test_files:
    hits = sum(1 for cmd in commands.values() if f"tests/{tf}" in cmd)
    if hits == 0:
        problems.append(f"orphan test: tests/{tf} is in no test.commands.<layer>")
    elif hits > 1:
        problems.append(f"tests/{tf} referenced by {hits} commands (want exactly 1)")

if problems:
    sys.stderr.write("orphan detector FAILED:\n")
    for p in problems:
        sys.stderr.write(f"  {p}\n")
    raise SystemExit(1)
print(f"orphan detector OK — {len(test_files)} test files, {len(commands)} commands, {len(layers)} layers")
PY
}

run_lint() {
  local lint
  lint="$(python3 -c 'import re,sys
for ln in open(".sdp/defaults.yaml"):
    m=re.match(r"^  lint:\s*\"(.*)\"\s*$", ln)
    if m: print(m.group(1)); break')"
  [ -n "$lint" ] || { echo "(no lint configured)"; return 0; }
  echo "+ $lint"
  eval "$lint"
}

run_layer_commands() {
  python3 - "$DEFAULTS" <<'PY' | while IFS= read -r cmd; do
import re, sys, pathlib
defaults = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
commands, layers = {}, {}
section=None; in_test=False
for line in defaults:
    if re.match(r"^\S", line):
        in_test=line.startswith("test:"); section=None; continue
    if not in_test: continue
    if re.match(r"^  commands:\s*$", line): section="commands"; continue
    if re.match(r"^  layers:\s*$", line): section="layers"; continue
    if re.match(r"^  \S", line): section=None; continue
    if section=="commands":
        m=re.match(r'^    (\w+):\s*"(.*)"\s*$', line)
        if m: commands[m.group(1)]=m.group(2)
    elif section=="layers":
        m=re.match(r"^    (\w+):\s*\[(.*)\]\s*$", line)
        if m: layers[m.group(1)]=[x.strip() for x in m.group(2).split(",") if x.strip()]
seen=[]
for layer in ("mandatory","risk_gated","supporting"):
    for name in layers.get(layer, []):
        if name in commands and commands[name] not in seen:
            seen.append(commands[name])
for c in seen: print(c)
PY
    echo "+ $cmd"
    eval "$cmd" || return 1
  done
}

step "regen-check" regen_check
step "orphan-detector" orphan_detector
step "packaging" bash tests/codex_plugin.sh
step "smoke" bash tests/smoke.sh
step "lint" run_lint
if [ "$FAST" -eq 0 ]; then
  step "full-suite" run_layer_commands
fi

printf '\n==================== run.sh: %d step(s) failed ====================\n' "$fails"
[ "$fails" -eq 0 ]
