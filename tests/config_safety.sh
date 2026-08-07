#!/usr/bin/env bash
# config_safety.sh — unit test for sdp_cfg_check_no_weakening (REQ-U-04 no-weakening guard).
# A project's forced_ext must only STRENGTHEN base safety keys; every YAML-false spelling and inline-flow
# evasion must be caught (Fail-Close).
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
TMP="$(mktemp -d -t sdp_cfg_test.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
# shellcheck source=/dev/null
. "$SDP_ROOT/scripts/lib/sdp-config.sh"

chk() { sdp_cfg_check_no_weakening "$1" >/dev/null 2>&1; }   # rc 1 = weakening blocked, 0 = ok

# each YAML-false spelling weakening a base key must be blocked
for spell in false False FALSE no No off n 0; do
  printf 'forced_ext:\n  hardcoded_secret_block: %s\n' "$spell" > "$TMP/w.yaml"
  chk "$TMP/w.yaml" && bad "weakening spelling '$spell' NOT blocked" || ok "weakening '$spell' blocked"
done

# non-empty inline-flow forced_ext (evades the line reader) must be rejected
printf 'forced_ext: {hardcoded_secret_block: false}\n' > "$TMP/inline.yaml"
chk "$TMP/inline.yaml" && bad "non-empty inline-flow NOT rejected" || ok "non-empty inline-flow rejected"

# fail-closed against the agy-round-3 bypass forms:
printf 'forced_ext:\n  { hardcoded_secret_block: false }\n' > "$TMP/mlflow.yaml"
chk "$TMP/mlflow.yaml" && bad "multi-line inline flow NOT rejected" || ok "multi-line inline flow rejected"
printf 'forced_ext:\n  hardcoded_secret_block:\n    false\n' > "$TMP/nextline.yaml"
chk "$TMP/nextline.yaml" && bad "next-line value NOT rejected" || ok "next-line value rejected"
printf 'forced_ext:\n  "hardcoded_secret_block": false\n' > "$TMP/qkey.yaml"
chk "$TMP/qkey.yaml" && bad "quoted key NOT rejected" || ok "quoted key rejected"
printf 'forced_ext:\n  hardcoded_secret_block: null\n' > "$TMP/null.yaml"
chk "$TMP/null.yaml" && bad "null value NOT rejected" || ok "null value rejected"
printf 'forced_ext: {\n  hardcoded_secret_block: false\n}\n' > "$TMP/mlopen.yaml"
chk "$TMP/mlopen.yaml" && bad "multi-line flow-open NOT rejected" || ok "multi-line flow-open rejected"
printf 'forced_ext:\n\thardcoded_secret_block: false\n' > "$TMP/tab.yaml"
chk "$TMP/tab.yaml" && bad "tab-indented weakening NOT rejected" || ok "tab-indented weakening rejected"
printf '"forced_ext":\n  hardcoded_secret_block: false\n' > "$TMP/qparent.yaml"
chk "$TMP/qparent.yaml" && bad "quoted forced_ext key NOT rejected" || ok "quoted forced_ext key rejected"
# a SECOND forced_ext block must reopen (not slip past the dedent)
printf 'forced_ext:\n  hardcoded_secret_block: true\nforced_ext:\n  redact_secrets: false\n' > "$TMP/multi.yaml"
chk "$TMP/multi.yaml" && bad "second forced_ext block NOT rejected" || ok "second forced_ext block rejected"
# a colonless base key (no value) is ambiguous -> fail-closed
printf 'forced_ext:\n  redact_secrets\n' > "$TMP/colonless.yaml"
chk "$TMP/colonless.yaml" && bad "colonless base key NOT rejected" || ok "colonless base key rejected"
# a FLAT dotted key (forced_ext.<base>: falsy) resolves by literal name in sdp_cfg_get -> must be blocked too
printf 'forced_ext.redact_secrets: false\n' > "$TMP/dotted.yaml"
chk "$TMP/dotted.yaml" && bad "flat dotted-key weakening NOT rejected" || ok "flat dotted-key weakening rejected"
printf 'forced_ext.hardcoded_secret_block: true\n' > "$TMP/dottedok.yaml"
chk "$TMP/dottedok.yaml" && ok "flat dotted-key strengthening allowed" || bad "flat dotted-key true wrongly blocked"
# must NOT false-positive on a CRLF file with a truthy key
printf 'forced_ext:\r\n  hardcoded_secret_block: true\r\n' > "$TMP/crlf.yaml"
chk "$TMP/crlf.yaml" && ok "CRLF truthy key allowed (no false positive)" || bad "CRLF truthy key wrongly blocked"

# strengthening (true) is allowed
printf 'forced_ext:\n  hardcoded_secret_block: true\n' > "$TMP/s.yaml"
chk "$TMP/s.yaml" && ok "strengthening (true) allowed" || bad "strengthening wrongly blocked"

# empty inline-flow {} is harmless and allowed
printf 'forced_ext: {}\n' > "$TMP/empty.yaml"
chk "$TMP/empty.yaml" && ok "empty forced_ext {} allowed" || bad "empty {} wrongly blocked"

# the repo's own defaults must pass
chk "$SDP_ROOT/.sdp/defaults.yaml" && ok "repo defaults.yaml passes" || bad "repo defaults.yaml blocked"

# --- GAP-04 (C1 permanent net): the .sdp_runtime.env dot-source vector is GONE ---
# The original C1 test drove the LIVE codex-gate.sh against a poisoned runtime env;
# P9 deleted codex-gate.sh, so that test self-disabled (its `[ -f codex-gate.sh ]`
# guard is now always false). These two nets replace it and depend on NO deleted
# file: they assert the underlying invariants directly and FAIL if a future edit
# reintroduces either the dot-source vector or an env behavioral knob.

# The two scanners are written to temp .py files first, then run: a quoted heredoc
# nested inside $(...) is mis-parsed by bash 3.2 when the body has an odd number of
# double-quotes, so the heredoc must NOT sit inside a command substitution.

# (1) NO shell under scripts/ or plugins/sdp/scripts/ may dot-source the runtime env.
# sdp-anchor.sh only WRITES ${base_dir}/.sdp_runtime.env (a redirect), never sources
# it. This catches both the literal-path form and a `. "$RUNTIME_ENV"` variable form.
cat > "$TMP/no_runtime_source.py" <<'PY'
import sys, pathlib, re
root = pathlib.Path(sys.argv[1])
# a genuine dot-source at a statement position: `. <..runtime..>` / `source <..runtime..>`
verb = re.compile(r'(?:^|;|&&|\|\||\bthen\b|\bdo\b|\{)\s*(?:\.|source)\s+["\x27]?\S*runtime', re.I)
bad = []
for tree in ("scripts", "plugins/sdp/scripts"):
    base = root / tree
    if not base.is_dir():
        continue
    for p in sorted(base.rglob("*")):
        if not p.is_file() or "__pycache__" in p.parts:
            continue
        try:
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        except Exception:
            continue
        for i, raw in enumerate(lines, 1):
            line = raw.split("#", 1)[0]           # drop comments (the anchor's WRITE has one)
            if "runtime" not in line.lower():
                continue
            if verb.search(line):
                bad.append(f"{p.relative_to(root)}:{i}:{raw.strip()}")
print("NONE" if not bad else "SOURCED " + " | ".join(bad))
PY
runtime_src="$(python3 "$TMP/no_runtime_source.py" "$SDP_ROOT")"
[ "$runtime_src" = "NONE" ] \
  && ok "GAP-04/C1: no script dot-sources .sdp_runtime.env (anchor only WRITES it)" \
  || bad "GAP-04/C1: a script dot-sources the runtime env -> $runtime_src"

# (2) review_gate.py reads NO behavioral env knob except SDP_BASE_DIR, the
# attended-override trigger SDP_GATE_OVERRIDE, and record-marker's human-intent
# signal SDP_MARKER_HUMAN (ADR-004 D2 / ADR-G02b). The only dynamic
# os.environ read is the inert Class-1 locale/term forward loop; a literal knob or
# a behavioral key smuggled into that loop is an env-knob regression.
cat > "$TMP/env_knob_allowlist.py" <<'PY'
import sys, ast
BEHAVIORAL_ALLOW = {"SDP_BASE_DIR", "SDP_GATE_OVERRIDE", "SDP_MARKER_HUMAN"}
INERT_FORWARD = {"LANG", "LC_ALL", "LC_CTYPE", "LC_NUMERIC", "LC_TIME", "TMPDIR", "TERM", "TZ"}
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
def is_environ(n):
    return (isinstance(n, ast.Attribute) and n.attr == "environ"
            and isinstance(n.value, ast.Name) and n.value.id == "os")
loopvar = {}   # for-loop target name -> {string constants it iterates}
for n in ast.walk(tree):
    if isinstance(n, ast.For) and isinstance(n.target, ast.Name):
        cs = {e.value for e in ast.walk(n.iter)
              if isinstance(e, ast.Constant) and isinstance(e.value, str)}
        if cs:
            loopvar.setdefault(n.target.id, set()).update(cs)
literals, dynamic = set(), []
for n in ast.walk(tree):
    key = None
    if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.args:
        if n.func.attr == "get" and is_environ(n.func.value):
            key = n.args[0]
        elif n.func.attr == "getenv" and isinstance(n.func.value, ast.Name) and n.func.value.id == "os":
            key = n.args[0]
    elif isinstance(n, ast.Subscript) and is_environ(n.value):
        key = n.slice
    if key is None:
        continue
    if isinstance(key, ast.Constant) and isinstance(key.value, str):
        literals.add(key.value)
    elif isinstance(key, ast.Name):
        dynamic.append((n.lineno, key.id))
    else:
        dynamic.append((n.lineno, "<expr>"))
probs = []
if literals - BEHAVIORAL_ALLOW:
    probs.append(f"literal knob(s) {sorted(literals - BEHAVIORAL_ALLOW)}")
for lineno, var in dynamic:
    cs = loopvar.get(var)
    if not cs:
        probs.append(f"dynamic os.environ read at L{lineno} not an inert-key loop")
    elif cs - INERT_FORWARD:
        probs.append(f"inert loop at L{lineno} grew non-inert key(s) {sorted(cs - INERT_FORWARD)}")
print("OK" if not probs else "KNOB " + " ; ".join(probs))
PY
env_knobs="$(python3 "$TMP/env_knob_allowlist.py" "$SDP_ROOT/scripts/review_gate.py")"
[ "$env_knobs" = "OK" ] \
  && ok "GAP-04/D2: review_gate.py env knobs = {SDP_BASE_DIR, SDP_GATE_OVERRIDE, SDP_MARKER_HUMAN} only (+ inert locale forward)" \
  || bad "GAP-04/D2: unexpected env knob read by review_gate.py -> $env_knobs"

# T43: widening the allowlist must not NEUTER the check. Run the same walker over
# a synthetic file carrying an unlisted knob and require it to still be caught.
cat > "$TMP/knob_regression.py" <<'PY'
import os
allowed = os.environ.get("SDP_BASE_DIR")
smuggled = os.environ.get("SDP_SOMETHING_NEW")
PY
neg_knob="$(python3 "$TMP/env_knob_allowlist.py" "$TMP/knob_regression.py")"
case "$neg_knob" in
  KNOB*SDP_SOMETHING_NEW*) ok "T43: the env-knob check still catches a knob outside the allowlist" ;;
  *) bad "T43: env-knob check is neutered (got $neg_knob)" ;;
esac

# --- REQ-026/027: bash sdp_cfg_get vs review_gate.py _read_gates_yaml parity ----
# The two readers MUST agree on the SAME config: indent-stack nesting (not
# depth=int(indent/2), which collapsed >=2 levels), quote-aware comment strip,
# colonless-line rejection.
PAR="$TMP/parity.yaml"
cat > "$PAR" <<'YAML'
base_dir: .private/sdp-artifacts
output_locale: auto
model: ""
quoted: "a # b"
deep:
  child:
    leaf: hello
cadence:
  escalate_from: 6
halt:
  max_block: 13
YAML
mkdir -p "$TMP/parproj/.sdp"; cp "$PAR" "$TMP/parproj/.sdp/gates.yaml"
parity_ok=1
for k in base_dir output_locale model quoted deep.child.leaf cadence.escalate_from halt.max_block absent; do
  b="$(sdp_cfg_get "$PAR" "$k")"
  p="$(python3 - "$SDP_ROOT/scripts" "$TMP/parproj" "$k" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import review_gate as rg
from pathlib import Path
flat, _ = rg._read_gates_yaml(Path(sys.argv[2]))
print(flat.get(sys.argv[3], ""))
PY
)"
  [ "$b" = "$p" ] || { parity_ok=0; printf '  mismatch key=%s bash=[%s] py=[%s]\n' "$k" "$b" "$p"; }
done
[ "$parity_ok" -eq 1 ] && ok "REQ-026/027: bash & python config readers agree (indent-stack, quote-aware)" \
                       || bad "config reader parity mismatch"

# REQ-027: an unterminated quote on base_dir is FATAL (rc 2), not silently mis-parsed.
printf 'base_dir: "oops\n' > "$TMP/unterm.yaml"
sdp_cfg_base_dir "$TMP/unterm.yaml" >/dev/null 2>&1; urc=$?
[ "$urc" -eq 2 ] && ok "REQ-027: unterminated base_dir quote is fatal (rc 2)" \
                 || bad "REQ-027: unterminated quote not caught (rc=$urc)"

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
