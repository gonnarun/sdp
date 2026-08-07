#!/usr/bin/env bash
# docs.sh — documentation/consistency guards (no behavior).
# Ensures user-facing docs don't make stale claims after P2/P3 and that the
# known-gaps note stays present. Static grep only, in the smoke/gate test style.
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SDP_ROOT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# 1. README must describe fcntl.flock as the CURRENT lock (design §2.4) -- the
#    live mechanism is a KEY-namespaced flock, NOT the retired bash mkdir lock.
grep -qi 'flock' README.md \
  && ok "README describes the fcntl.flock lock (live mechanism)" \
  || bad "README does not describe the fcntl.flock lock (design §2.4)"

# 2. README must NOT still claim the retired mkdir lock.
grep -qi 'mkdir' README.md \
  && bad "README still claims the retired mkdir lock (stale)" \
  || ok "README has no stale mkdir lock claim"

# 3. Known-gaps note exists and covers the two open gaps.
if [ -f docs/KNOWN_GAPS.md ]; then
  ok "docs/KNOWN_GAPS.md exists"
  grep -q 'run_segment_tmux.sh' docs/KNOWN_GAPS.md && ok "KNOWN_GAPS covers the tmux/auto backend gap" || bad "KNOWN_GAPS missing tmux/auto gap"
  grep -q 'output_locale' docs/KNOWN_GAPS.md && ok "KNOWN_GAPS covers the output_locale auto caveat" || bad "KNOWN_GAPS missing output_locale caveat"
else
  bad "docs/KNOWN_GAPS.md missing"
fi

# 4. README surfaces the not-yet-implemented limitations to users.
grep -qi 'Known limitations' README.md && ok "README has a Known limitations section" || bad "README missing Known limitations section"

# =============================================================================
# ADR-G10's doc guards (i)-(ix), plus guard (x) for the BLOCK output contract.
# These run against BOTH TREES. Until now this file read only the root README,
# which is exactly why the root/plugin doc drift stayed invisible: the deployed
# plugins/sdp/ copy is the one a live session actually reads.
#
# NOTE: guard (x) is NOT one of ADR-G10's guards. It verifies the BLOCK output
# contract, which was added to P3 mid-dispatch and which the design does not
# contain. It is labelled separately so no reader mistakes it for one of them.
# =============================================================================
SHIPPED_DOCS="README.md plugins/sdp/README.md core plugins/sdp/core commands plugins/sdp/commands"
CONTRACT_FILES="core/Stage4_design_plan.md plugins/sdp/core/Stage4_design_plan.md core/Stage7_test_exec.md plugins/sdp/core/Stage7_test_exec.md"

# ---- (i) no file claims the gate "does not itself enforce the roster" -------
# shellcheck disable=SC2086
if grep -rqF 'does not itself enforce the roster' $SHIPPED_DOCS 2>/dev/null; then
  bad "(i) a shipped doc still claims the gate 'does not itself enforce the roster'"
else
  ok "(i) no shipped doc claims the gate does not enforce the roster"
fi

# ---- (ii) the "physically refuses" sentence is replaced, VERBATIM -----------
G2='the gate refuses to re-run the reviewer until a valid team roster is recorded in the gate log — a fail-closed check on log content, not a barrier against a same-uid writer who can append to that log.'
for f in README.md plugins/sdp/README.md; do
  if grep -qF 'physically refuses' "$f"; then
    bad "(ii) $f still overclaims with 'physically refuses'"
  elif grep -qF "$G2" "$f"; then
    ok "(ii) $f carries the fail-closed replacement sentence verbatim"
  else
    bad "(ii) $f does not carry the replacement sentence verbatim"
  fi
done

# ---- (iii) the PLUGIN Stage-4 copy carries the escalation instruction -------
S4P="plugins/sdp/core/Stage4_design_plan.md"
miss=""
for tok in 'TEAM_REVIEW' 'escalate_from' 'roster' '.halt'; do
  grep -qF "$tok" "$S4P" || miss="$miss $tok"
done
[ -z "$miss" ] && ok "(iii) the plugin Stage-4 copy carries TEAM_REVIEW / escalate_from / roster / .halt" \
               || bad "(iii) the plugin Stage-4 copy is missing:$miss"

# ---- (iv) no laundering recipe in ANY shipped file, in EITHER tree ----------
# shellcheck disable=SC2086
launder="$(grep -rnE '>>[^|]*\.log|\b(mv|rm)\b[^|]*\.halt' $SHIPPED_DOCS 2>/dev/null || true)"
[ -z "$launder" ] \
  && ok "(iv) no shipped file redirects into a .log or mv/rm's a .halt (operator procedures stay root-only)" \
  || bad "(iv) a shipped file carries a laundering recipe -> $launder"

# ---- (v) no relative docs/ link in the plugin README ------------------------
grep -qF '](docs/' plugins/sdp/README.md \
  && bad "(v) plugins/sdp/README.md links a relative docs/ path that does not exist in that tree" \
  || ok "(v) plugins/sdp/README.md has no relative docs/ link"

# ---- (vi) REQ-E-05 adjacency: within 5 SOURCE LINES, not mere presence ------
# The same README is simultaneously SOFTENING 'physically refuses' and ADDING two
# new official commands, so a reader skimming the diff can come away believing the
# guarantee was strengthened. Presence alone does not prevent that; adjacency does.
python3 - <<'PY' && ok "(vi) the REQ-E-05 honesty sentence is within 5 source lines of record-marker in BOTH READMEs" \
                 || bad "(vi) the REQ-E-05 sentence is absent or too far from record-marker"
import sys, pathlib
SENT = ("The marker is honor-plus-evidence: the gate checks roster cardinality, distinctness and "
        "output freshness, but the log is agent-writable same-uid and forgery cannot be fully "
        "prevented (`review_gate.py:1103-1104`).")
for path in ("README.md", "plugins/sdp/README.md"):
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    first = next((i for i, l in enumerate(lines) if "record-marker" in l), None)
    hon = [i for i, l in enumerate(lines) if SENT in l]
    if first is None or not hon:
        sys.exit(1)
    if min(abs(h - first) for h in hon) > 5:
        sys.exit(1)
PY

# ---- (vii) the committed register's INTERNAL INTEGRITY only ----------------
# Nothing here asserts the register is COMPLETE. Completeness rests on human
# reading (NC-21) and no assertion may be written as if it were a proof.
python3 - <<'PY' && ok "(vii) KNOWN_GAPS §6 ids are contiguous NC-01..NC-NN and the stated total equals the row count" \
                  || bad "(vii) KNOWN_GAPS §6 register integrity failed"
import re, sys, pathlib
text = pathlib.Path("docs/KNOWN_GAPS.md").read_text(encoding="utf-8")
m = re.search(r"^## 6\. .*$", text, re.M)
if not m:
    sys.exit(1)
end = text.find("\n## ", m.end())
section = text[m.start():end if end != -1 else len(text)]
stated = re.search(r"carries (\d+) rows", section)
ids = [int(x) for x in re.findall(r"^\| \*\*NC-(\d{2})\*\* \|", section, re.M)]
if not stated or not ids:
    sys.exit(1)
total = int(stated.group(1))
if len(ids) != total or sorted(ids) != list(range(1, total + 1)):
    sys.exit(1)
sys.exit(0)
PY
for s in '## 1.' '## 2.' '## 3.' '## 4.' '## 5.' '## Resolved (for the record)'; do
  grep -qF "$s" docs/KNOWN_GAPS.md || bad "(vii) KNOWN_GAPS lost the pre-existing section '$s'"
done
ok "(vii) KNOWN_GAPS §§1-5 and the Resolved list are still present (added to, never replaced)"

# ---- (viii) NC-02's committed carrier ---------------------------------------
python3 - <<'PY' && ok "(viii) GATE_OPERATIONS carries the deferred-migration obligations, numbered contiguously from 1" \
                  || bad "(viii) the deferred key-migration section is missing or mis-numbered"
import re, sys, pathlib
p = pathlib.Path("docs/GATE_OPERATIONS.md")
if not p.is_file():
    sys.exit(1)
text = p.read_text(encoding="utf-8")
m = re.search(r"^## Deferred: gate-state key migration\s*$", text, re.M)
if not m:
    sys.exit(1)
end = text.find("\n## ", m.end())
section = text[m.end():end if end != -1 else len(text)]
ids = [int(x) for x in re.findall(r"^(\d+)\. ", section, re.M)]
sys.exit(0 if ids and ids == list(range(1, len(ids) + 1)) else 1)
PY

# ---- (ix) the load-bearing Stage-8 coupling survives in BOTH trees ----------
for f in core/SDP.md plugins/sdp/core/SDP.md; do
  grep -qF '(or while `doctor` exits non-zero)' "$f" \
    && ok "(ix) $f still couples .needs_human to Stage 8 through doctor's exit code" \
    || bad "(ix) $f LOST the '(or while doctor exits non-zero)' parenthetical"
done

# ---- (x) ★ the BLOCK output contract, as FIXED STRINGS ---------------------
# grep -F, not a pattern: a paraphrase must fail.
L1='SCOPE** — `closeable-in-this-dispatch` | `must-be-recorded-instead`'
L2='INCOMPLETE - <field> not supplied because <reason>'
for f in $CONTRACT_FILES; do
  if grep -qF "$L1" "$f" && grep -qF "$L2" "$f"; then
    ok "(x) $f carries both BLOCK-output-contract literals verbatim"
  else
    bad "(x) $f is missing a BLOCK-output-contract literal (paraphrased?)"
  fi
done
python3 - <<'PY' && ok "(x) every gate prompt string in all four files requires the BLOCK output contract by name" \
                  || bad "(x) a gate prompt string does not reference the BLOCK output contract"
import sys, pathlib
files = ["core/Stage4_design_plan.md", "plugins/sdp/core/Stage4_design_plan.md",
         "core/Stage7_test_exec.md", "plugins/sdp/core/Stage7_test_exec.md"]
expect = {"core/Stage4_design_plan.md": 2, "plugins/sdp/core/Stage4_design_plan.md": 2,
          "core/Stage7_test_exec.md": 1, "plugins/sdp/core/Stage7_test_exec.md": 1}
# EVERY literal below is checked PER PROMPT STRING. The file-scope grep above
# cannot stand in for this: a surviving prose copy of the subsection satisfies a
# file-wide grep even when all four executable prompt strings have been
# paraphrased, which is precisely the drift this guard exists to catch.
REQUIRED = (
    "BLOCK output contract",
    "must-be-recorded-instead",
    "closeable-in-this-dispatch",
    "INCOMPLETE - <field> not supplied because <reason>",
)
for f in files:
    prompts = [l for l in pathlib.Path(f).read_text(encoding="utf-8").splitlines()
               if "review_gate.py" in l and "no preamble." in l]
    if len(prompts) != expect[f]:
        sys.exit(1)
    for p in prompts:
        for needed in REQUIRED:
            if needed not in p:
                sys.exit(1)
sys.exit(0)
PY

# ---- (xi) P6 step-0: core-tree reconciliation invariant --------------------
# The two core/ trees may differ ONLY on reviewer-DIRECTION/invocation lines; the
# 3-state POLICY must be identical. A presence-only check is insufficient (an added
# contradiction would still pass), so this is enforced three ways:
#   (a) the reconciled policy sentences are present in BOTH trees;
#   (b) each host's gate CLI command block names the OPPOSITE reviewer, so an
#       MCP-unavailable fallback cannot self-review (codex host must use --reviewer
#       claude; Claude host --reviewer codex);
#   (c) a divergence manifest pins the per-file divergent-line COUNT and requires
#       every divergent line to carry a direction/invocation token -- an added
#       contradiction either bumps a count or lacks a token, and trips this guard.
# Full text-unification (removing the direction divergence entirely) awaits the
# cross-provider gate and is deferred; this guard bounds the divergence until then.

# (a) reconciled 3-state policy present in BOTH trees
for f in core/Stage4_design_plan.md plugins/sdp/core/Stage4_design_plan.md core/Stage7_test_exec.md plugins/sdp/core/Stage7_test_exec.md; do
  grep -qF 'clears the infra flag' "$f" \
    && ok "(xi-a) $f carries the INFRA_ERROR merge/push interlock" \
    || bad "(xi-a) $f LOST the INFRA_ERROR merge/push interlock (P6 re-divergence)"
done
for f in core/Stage5_implement.md plugins/sdp/core/Stage5_implement.md; do
  grep -qF 'MERGE/PUSH stays blocked until a clean `ALLOW:`' "$f" \
    && ok "(xi-a) $f carries the Stage-5 INFRA_ERROR interlock" \
    || bad "(xi-a) $f LOST the Stage-5 INFRA_ERROR interlock (P6 re-divergence)"
done
for f in core/SDP.md plugins/sdp/core/SDP.md; do
  grep -qF 'hard-halts at `${halt.max_block}`' "$f" \
    && ok "(xi-a) $f carries the escalate_from/max_block halt-limit sentence" \
    || bad "(xi-a) $f LOST the halt-limit sentence (P6 re-divergence)"
done
for f in core/Stage4_design_plan.md plugins/sdp/core/Stage4_design_plan.md; do
  grep -qF '`record-marker` is the only command that writes it' "$f" \
    && ok "(xi-a) $f carries the sanctioned record-marker path" \
    || bad "(xi-a) $f LOST the sanctioned record-marker sentence (P6 re-divergence)"
done

# (b) each host's gate CLI command block names the OPPOSITE reviewer (no self-review)
gate_cmds() { grep 'review_gate.py' "$1" | grep 'no preamble.'; }
for f in plugins/sdp/core/Stage4_design_plan.md plugins/sdp/core/Stage7_test_exec.md; do
  t=$(gate_cmds "$f" | wc -l | tr -d ' '); w=$(gate_cmds "$f" | grep -c -- '--reviewer claude')
  { [ "$t" -gt 0 ] && [ "$t" = "$w" ]; } \
    && ok "(xi-b) $f: all $t gate command block(s) pin --reviewer claude (codex host cannot self-review)" \
    || bad "(xi-b) $f: only $w/$t gate command block(s) pin --reviewer claude"
done
for f in core/Stage4_design_plan.md core/Stage7_test_exec.md; do
  t=$(gate_cmds "$f" | wc -l | tr -d ' '); w=$(gate_cmds "$f" | grep -c -- '--reviewer codex')
  { [ "$t" -gt 0 ] && [ "$t" = "$w" ]; } \
    && ok "(xi-b) $f: all $t gate command block(s) pin --reviewer codex" \
    || bad "(xi-b) $f: only $w/$t gate command block(s) pin --reviewer codex"
done
# Codex-side skills invoke the gate too; their review calls must pin --reviewer claude.
for f in plugins/sdp/skills/sdp/SKILL.md plugins/sdp/skills/batch-sdp/SKILL.md plugins/sdp/skills/worktree-dispatch/SKILL.md \
         skills/sdp/SKILL.md skills/batch-sdp/SKILL.md skills/worktree-dispatch/SKILL.md; do
  t=$(grep -cF 'review_gate.py --cwd "$PWD"' "$f"); w=$(grep -F 'review_gate.py --cwd "$PWD"' "$f" | grep -c -- '--reviewer claude')
  { [ "$t" -gt 0 ] && [ "$t" = "$w" ]; } \
    && ok "(xi-b) $f: all $t Codex-side gate invocation(s) pin --reviewer claude (no self-review)" \
    || bad "(xi-b) $f: only $w/$t Codex-side gate invocation(s) pin --reviewer claude"
done
# Shipped READMEs: the generic gate example must not be a bare (codex-defaulting) review
# call, and must document both directions (author -> opposite reviewer).
for f in README.md plugins/sdp/README.md; do
  n=$(grep -cF 'review_gate.py" --cwd "$PWD" "' "$f")
  [ "$n" = "0" ] \
    && ok "(xi-b) $f: no bare gate review example (would self-review on codex host)" \
    || bad "(xi-b) $f: $n bare gate review example(s) default to codex self-review"
  { grep -qF -- '--reviewer codex' "$f" && grep -qF -- '--reviewer claude' "$f"; } \
    && ok "(xi-b) $f: gate docs show both review directions" \
    || bad "(xi-b) $f: gate docs missing a --reviewer direction"
done

# (c) divergence manifest: per-file divergent-line count + every divergent line is a direction line
python3 - <<'PY' && ok "(xi-c) core-tree divergence matches the manifest (direction-only; no new contradiction)" \
                 || bad "(xi-c) core-tree divergence drifted from the manifest (see stderr)"
import pathlib, difflib, re, sys
EXPECT = {"SDP.md":1, "Stage1_interview.md":0, "Stage2_normalize.md":0, "Stage3_current_state.md":0,
          "Stage4_design_plan.md":4, "Stage5_implement.md":1, "Stage6_test_plan.md":0,
          "Stage7_test_exec.md":4, "Stage8_verification.md":0}
tok = re.compile(r'codex|Codex|Claude|claude_review_gate|review_gate\.py|\bMCP\b|call the script|--reviewer')
ok = True
for f, exp in EXPECT.items():
    a = (pathlib.Path("core")/f).read_text(encoding="utf-8").splitlines()
    b = (pathlib.Path("plugins/sdp/core")/f).read_text(encoding="utf-8").splitlines()
    diff = [l for l in difflib.unified_diff(a, b, lineterm="")
            if l[:1] in "+-" and l[:3] not in ("---", "+++")]
    root_side = [l[1:] for l in diff if l[0] == "-"]
    if len(root_side) != exp:
        sys.stderr.write(f"  {f}: {len(root_side)} divergent line(s); manifest expects {exp}\n"); ok = False
    for l in diff:
        c = l[1:]
        if c.strip() and not tok.search(c):
            sys.stderr.write(f"  {f}: NON-direction divergent line -> {c[:70]}\n"); ok = False
sys.exit(0 if ok else 1)
PY

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
