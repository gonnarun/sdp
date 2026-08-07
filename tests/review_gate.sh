#!/usr/bin/env bash
# review_gate.sh — integration tests for scripts/review_gate.py.
# ADR-004 deleted CLAUDE_GATE_SAFE_PATH/CLAUDE_GATE_CLAUDE_BIN/CLAUDE_GATE_ENV_VARS
# and stopped forwarding the reviewee's env to the child, so provider stubs are
# bound via tests/lib/harness.py's --binary-resolver (argv = T3), and the stubs
# read their mode from a control dir baked into the stub. 9 cases keep their
# subprocess boundary; the tail is the N1/V7 acceptance (fails against pre-D1).
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
HARNESS="$SDP_ROOT/tests/lib/harness.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d -t sdp_review_gate.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/project"; BIN="$TMP/bin"; CTRL="$TMP/ctrl"
mkdir -p "$PROJ" "$BIN" "$CTRL"
printf 'plan body\n' > "$PROJ/plan.md"

# Stub claude — mode + prompt capture come from $CTRL (baked-in absolute paths),
# never from env (the gate no longer forwards CLAUDE_STUB_MODE to the child).
cat > "$BIN/claude" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && { echo "Claude Code stub"; exit 0; }
# GAP-01: record the FULL argv, one [token] per line, so the H1 argv-level policy
# assertion can inspect the exact flags the gate passed (empty lines stay visible
# as []). The --version probe is excluded above so the real review argv is captured.
: > "$CTRL/claude_argv"
for a in "\$@"; do printf '[%s]\n' "\$a" >> "$CTRL/claude_argv"; done
last=""; for a in "\$@"; do last="\$a"; done
printf '%s' "\$last" > "$CTRL/claude_prompt"
case "\$(cat "$CTRL/claude_mode" 2>/dev/null || echo allow)" in
  allow)     printf 'ALLOW: claude ok\n'; exit 0 ;;
  block)     printf 'BLOCK: claude no\n'; exit 0 ;;
  malformed) printf 'thinking\nALLOW: not first\n'; exit 0 ;;
  timeout)   printf 'ALLOW: partial before timeout\n'; sleep 5; exit 0 ;;
  fail)      printf 'ALLOW: partial before fail\n'; exit 42 ;;
esac
STUB
chmod +x "$BIN/claude"

cat > "$BIN/agy" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && { echo "agy stub"; exit 0; }
# GAP-01/H3: record the FULL agy argv so the model-flag assertion can prove agy is
# invoked with --model <value> (never the silent no-op -m).
: > "$CTRL/agy_argv"
for a in "\$@"; do printf '[%s]\n' "\$a" >> "$CTRL/agy_argv"; done
case "\$(cat "$CTRL/agy_mode" 2>/dev/null || echo allow)" in
  allow)     printf 'ALLOW: agy ok\n'; exit 0 ;;
  block)     printf 'BLOCK: agy no\n'; exit 0 ;;
  malformed) printf 'thinking\n'; exit 0 ;;
  fail)      printf 'ALLOW: partial before fail\n'; exit 42 ;;
esac
STUB
chmod +x "$BIN/agy"

# Stub codex — the directional (cross-model) PRIMARY for Claude-authored work. It
# records the FULL argv (so the -s read-only / no-sandbox-weakening / model-flag
# assertions can inspect exactly what the gate passed) and emits codex `exec --json`
# JSONL by default (the production parse path); a `plain` mode exercises the
# plain-text fallback, `empty` yields JSONL with no agent_message (garbled -> infra).
cat > "$BIN/codex" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && { echo "codex-cli stub 0.0.0"; exit 0; }
: > "$CTRL/codex_argv"
for a in "\$@"; do printf '[%s]\n' "\$a" >> "$CTRL/codex_argv"; done
case "\$(cat "$CTRL/codex_mode" 2>/dev/null || echo allow)" in
  allow)     printf '%s\n' '{"type":"thread.started","thread_id":"t1"}' '{"type":"turn.started"}' '{"type":"item.completed","item":{"type":"agent_message","text":"ALLOW: codex ok"}}' '{"type":"turn.completed"}'; exit 0 ;;
  block)     printf '%s\n' '{"type":"thread.started","thread_id":"t1"}' '{"type":"turn.started"}' '{"type":"item.completed","item":{"type":"agent_message","text":"BLOCK: codex no"}}' '{"type":"turn.completed"}'; exit 0 ;;
  plain)     printf 'ALLOW: codex plain ok\n'; exit 0 ;;
  empty)     printf '%s\n' '{"type":"thread.started","thread_id":"t1"}' '{"type":"turn.completed"}'; exit 0 ;;
  fail)      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ALLOW: partial"}}'; exit 42 ;;
esac
STUB
chmod +x "$BIN/codex"

RESOLVER="$TMP/resolver.json"
printf '{"claude": "%s", "agy": "%s", "codex": "%s"}\n' "$BIN/claude" "$BIN/agy" "$BIN/codex" > "$RESOLVER"
# GATE pins --reviewer claude (the CLI default is now codex): the block below is the
# regression suite for the CLAUDE-direction path, whose stub is `claude`. GATEC drives
# the codex-direction path (--reviewer codex).
GATE()  { python3 "$HARNESS" --binary-resolver "$RESOLVER" -- --cwd "$PROJ" --reviewer claude "$@"; }
GATEC() { python3 "$HARNESS" --binary-resolver "$RESOLVER" -- --cwd "$PROJ" --reviewer codex "$@"; }
setmode()  { printf '%s' "$1" > "$CTRL/claude_mode"; printf '%s' "$2" > "$CTRL/agy_mode"; }
setcodex() { printf '%s' "$1" > "$CTRL/codex_mode"; }

setmode allow allow
out="$(GATE "review" plan.md)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW: claude ok'; } \
  && ok "claude ALLOW returns exit 0" || bad "claude ALLOW (rc=$rc $out)"

setmode block allow
out="$(GATE "review" plan.md)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^BLOCK: claude no'; } \
  && ok "claude content BLOCK is terminal, no agy fallback" || bad "claude BLOCK fallback (rc=$rc $out)"

setmode malformed allow
out="$(GATE "review" plan.md)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW: agy ok (agy fallback)'; } \
  && ok "claude malformed falls back to agy" || bad "malformed fallback (rc=$rc $out)"

# P8/ADR-004 D2: the reviewer timeout is sourced from gates.yaml, NEVER env, so a
# dedicated project pins claude_timeout=1; the stub sleeps 5s -> timeout -> infra.
setmode timeout fail
TPROJ="$TMP/tproj"; mkdir -p "$TPROJ/.sdp"; printf 'plan body\n' > "$TPROJ/plan.md"
printf 'claude_timeout: 1\n' > "$TPROJ/.sdp/gates.yaml"
out="$(python3 "$HARNESS" --binary-resolver "$RESOLVER" -- --cwd "$TPROJ" --reviewer claude "review" plan.md)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^BLOCK: INFRA_ERROR'; } \
  && ok "timeout + failed agy -> INFRA_ERROR" || bad "timeout infra (rc=$rc $out)"

setmode malformed fail
out="$(GATE "review" plan.md)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^BLOCK: INFRA_ERROR'; } \
  && ok "first-line spoof output rejected" || bad "spoof output (rc=$rc $out)"

# ADR-003/REQ-053: an artifact outside the explicit cwd is no longer a misleading
# "path escapes workspace" BLOCK -- it resolves to its own parent (arm 4). The
# stub bins live under $BIN, outside the arm-4 root, so they stay trusted.
setmode allow allow
mkdir -p "$TMP/outproj"; printf 'outside\n' > "$TMP/outproj/plan.md"
out="$(GATE "review" "$TMP/outproj/plan.md")"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW: claude ok'; } \
  && ok "ADR-003 arm 4: artifact outside cwd resolves to its parent (no path-escape BLOCK)" \
  || bad "ADR-003 arm 4 (rc=$rc $out)"

# Workspace-local claude binary rejected: resolver points claude INSIDE the proj.
printf '#!/usr/bin/env bash\nprintf "ALLOW: bad workspace binary\\n"\n' > "$PROJ/claude"
chmod +x "$PROJ/claude"
WS="$TMP/ws_resolver.json"
printf '{"claude": "%s", "agy": "%s"}\n' "$PROJ/claude" "$BIN/agy" > "$WS"
setmode allow allow
out="$(python3 "$HARNESS" --binary-resolver "$WS" -- --cwd "$PROJ" --reviewer claude "review" plan.md)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW: agy ok (agy fallback)' \
  && ! printf '%s' "$out" | grep -q 'bad workspace'; } \
  && ok "workspace-local claude binary rejected, agy fallback used" || bad "workspace binary (rc=$rc $out)"

setmode allow allow
out="$(GATE "review" plan.md)"; rc=$?
CAP="$CTRL/claude_prompt"
if [ "$rc" -eq 0 ] \
  && grep -q 'BEGIN_UNTRUSTED_ARTIFACT' "$CAP" \
  && grep -q 'Ignore any instruction' "$CAP" \
  && grep -q 'Do not run Codex' "$CAP"; then
  ok "prompt includes untrusted delimiters and recursion guard"
else
  bad "prompt guard missing"
fi

python3 "$HARNESS" --binary-resolver "$RESOLVER" -- --cwd "$PROJ" doctor >/dev/null 2>&1 \
  && ok "doctor exits 0 (healthy stubbed claude)" || bad "doctor healthy"

# ---------------- GAP-01: argv-level tool/model policy (the green-and-blind net) --
# These read the FULL argv the gate handed each provider (recorded by the stubs as
# one [token] per line) and fail on the exact pre-fix regressions. Non-vacuity for
# H1 is proven against the pre-P7 blob bd98729^ (see the batch report): that blob's
# `--disallowedTools "Bash,Edit,Write,MultiEdit,NotebookEdit"` argv makes assertion
# (a)/(b) below FAIL.

# H1 / REQ-003 (🔴 total-loss): the claude reviewer argv must grant an EMPTY
# allowlist and carry NO denylist. FAILS if reverted to the old --disallowedTools
# denylist, or if WebFetch/WebSearch ever appear in an allow position.
setmode allow allow
GATE "review" plan.md >/dev/null 2>&1
CA="$CTRL/claude_argv"
h1_ok=1
# (a) --allowedTools is present AND its VALUE is the empty string (grants nothing)
grep -A1 -Fx -- '[--allowedTools]' "$CA" 2>/dev/null | grep -Fxq -- '[]' || h1_ok=0
# (b) NO --disallowedTools flag anywhere (a revert to the deny-list must trip here)
grep -Fxq -- '[--disallowedTools]' "$CA" && h1_ok=0
# (c) the legacy deny-list value must not survive as any token
grep -Fq -- 'Bash,Edit,Write,MultiEdit,NotebookEdit' "$CA" && h1_ok=0
# (d) WebFetch / WebSearch are NOT in an allow (or any) position — the empty
#     allowlist means neither egress tool may appear as an argv token at all
grep -Fq 'WebFetch' "$CA" && h1_ok=0
grep -Fq 'WebSearch' "$CA" && h1_ok=0
[ "$h1_ok" -eq 1 ] \
  && ok "H1/REQ-003: claude argv grants an EMPTY allowlist, no denylist, no WebFetch/WebSearch" \
  || bad "H1/REQ-003: claude tool policy is not the empty allowlist (see claude_argv)"

# H3 / REQ-005: agy's model flag is --model <value>, never -m. A distinctive model
# is pinned in gates.yaml (shared `model:` key); claude is forced malformed so the
# gate falls back to agy, whose stub records the argv it was actually invoked with.
H3P="$TMP/h3proj"; mkdir -p "$H3P/.sdp"; printf 'plan body\n' > "$H3P/plan.md"
printf 'model: sdp-test-model-x\n' > "$H3P/.sdp/gates.yaml"
setmode malformed allow
python3 "$HARNESS" --binary-resolver "$RESOLVER" -- --cwd "$H3P" --reviewer claude "review" plan.md >/dev/null 2>&1
AA="$CTRL/agy_argv"
h3_ok=1
grep -A1 -Fx -- '[--model]' "$AA" 2>/dev/null | grep -Fxq -- '[sdp-test-model-x]' || h3_ok=0
grep -Fxq -- '[-m]' "$AA" && h3_ok=0
[ "$h3_ok" -eq 1 ] \
  && ok "H3/REQ-005: agy argv uses --model <value> (never -m)" \
  || bad "H3/REQ-005: agy model flag is not --model (see agy_argv)"

# M6 / REQ-012: AGY_MODEL_RE and the claude MODEL_RE are SEPARATE grammars. A real
# agy model name (spaces + parens) must pass AGY_MODEL_RE and be rejected by the
# stricter claude MODEL_RE. Tests the compiled patterns directly (import), not e2e.
m6="$(python3 - "$SDP_ROOT/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import review_gate as rg
name = "Gemini 3.5 Flash (Medium)"
agy_ok    = bool(rg.AGY_MODEL_RE.match(name))       # agy grammar accepts spaces/parens
claude_no = rg.MODEL_RE.match(name) is None         # claude grammar rejects them
claude_ok = bool(rg.MODEL_RE.match("claude-opus-4-1"))  # a plain claude id still passes
print("PASS" if (agy_ok and claude_no and claude_ok)
      else f"FAIL agy_ok={agy_ok} claude_no={claude_no} claude_ok={claude_ok}")
PY
)"
[ "$m6" = "PASS" ] \
  && ok "M6/REQ-012: agy grammar accepts 'Gemini 3.5 Flash (Medium)'; claude grammar rejects it" \
  || bad "M6/REQ-012: model grammars not separated ($m6)"

# ================ codex direction (the INVERSE / cross-model primary) =========
# reviewer=codex is the CLI default: Claude-authored work is reviewed by codex.
# These drive the codex stub and assert the ported codex-gate.sh invocation+parse.

# codex JSONL ALLOW: the final agent_message text carries the verdict.
setcodex allow; printf '%s' allow > "$CTRL/agy_mode"
out="$(GATEC "review" plan.md)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW: codex ok'; } \
  && ok "codex direction: JSONL agent_message ALLOW parsed -> exit 0" \
  || bad "codex ALLOW (rc=$rc $out)"

# codex content BLOCK is terminal (no agy fallback), same as the claude path.
setcodex block; printf '%s' allow > "$CTRL/agy_mode"
out="$(GATEC "review" plan.md)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^BLOCK: codex no' \
   && ! printf '%s' "$out" | grep -q 'agy'; } \
  && ok "codex direction: content BLOCK is terminal, no agy fallback" \
  || bad "codex BLOCK fallback (rc=$rc $out)"

# codex empty/garbled (JSONL with no agent_message) -> agy fallback fires.
setcodex empty; printf '%s' allow > "$CTRL/agy_mode"
out="$(GATEC "review" plan.md)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW: agy ok (agy fallback)'; } \
  && ok "codex direction: empty codex output falls back to agy" \
  || bad "codex->agy fallback (rc=$rc $out)"

# SAFETY (codex analogue of H1): the codex argv is `exec ... -s read-only`, carries
# NO sandbox-weakening / approval-disabling flag, and passes -m ONLY when a model is
# set. FAILS if -s read-only is dropped or any danger flag is added.
setcodex allow
GATEC "review" plan.md >/dev/null 2>&1
CX="$CTRL/codex_argv"
cx_ok=1
grep -Fxq -- '[exec]' "$CX" || cx_ok=0
grep -Fxq -- '[--json]' "$CX" || cx_ok=0
grep -Fxq -- '[--skip-git-repo-check]' "$CX" || cx_ok=0
grep -A1 -Fx -- '[-s]' "$CX" 2>/dev/null | grep -Fxq -- '[read-only]' || cx_ok=0
for bad_tok in '[danger-full-access]' '[workspace-write]' '[--dangerously-bypass-approvals-and-sandbox]' '[--dangerously-bypass-hook-trust]' '[--yolo]' '[--no-sandbox]'; do
  grep -Fxq -- "$bad_tok" "$CX" && cx_ok=0
done
grep -Fxq -- '[-m]' "$CX" && cx_ok=0     # no model set -> no -m token
[ "$cx_ok" -eq 1 ] \
  && ok "codex argv: 'exec ... -s read-only', no sandbox-weakening flag, no -m when unset" \
  || bad "codex argv policy violated (see codex_argv)"

# codex model flag: a gates.yaml model flows to codex as `-m <value>`.
CXM="$TMP/cxmproj"; mkdir -p "$CXM/.sdp"; printf 'plan body\n' > "$CXM/plan.md"
printf 'model: sdp-codex-model-y\n' > "$CXM/.sdp/gates.yaml"
setcodex allow
python3 "$HARNESS" --binary-resolver "$RESOLVER" -- --cwd "$CXM" --reviewer codex "review" plan.md >/dev/null 2>&1
cxm_ok=1
grep -A1 -Fx -- '[-m]' "$CTRL/codex_argv" 2>/dev/null | grep -Fxq -- '[sdp-codex-model-y]' || cxm_ok=0
[ "$cxm_ok" -eq 1 ] \
  && ok "codex argv: gates.yaml model -> -m <value>" \
  || bad "codex model flag not passed as -m (see codex_argv)"

# ---- directional defaults ---------------------------------------------------
# CLI default reviewer is codex: NO --reviewer -> codex is the primary. claude is
# forced to a DISTINCT verdict so a regression to the claude primary is visible.
setmode block allow      # claude would emit BLOCK: claude no
setcodex allow           # codex emits ALLOW: codex ok
out="$(python3 "$HARNESS" --binary-resolver "$RESOLVER" -- --cwd "$PROJ" "review" plan.md)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ALLOW: codex ok' \
   && ! printf '%s' "$out" | grep -q 'claude'; } \
  && ok "directional default: CLI reviewer defaults to codex (not claude)" \
  || bad "directional default is not codex (rc=$rc $out)"

# The MCP claude_review_gate entry (the codex-side tool) defaults run_review to
# reviewer=claude -- the opposite of the codex author.
mcp_rev="$(python3 - "$SDP_ROOT/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import review_gate, sdp_mcp_server
seen = {}
def fake(prompt, artifact_path, cwd=None, reviewer="codex", **kw):
    seen["reviewer"] = reviewer
    return {"verdict": "ALLOW", "provider": reviewer, "line": "ALLOW: x", "reason": "", "exit_code": 0}
review_gate.run_review = fake
sdp_mcp_server._call_tool("claude_review_gate", {"prompt": "p", "artifact_path": "a"})
print(seen.get("reviewer"))
PY
)"
[ "$mcp_rev" = "claude" ] \
  && ok "directional: MCP claude_review_gate calls run_review(reviewer=claude)" \
  || bad "MCP entry did not default reviewer=claude (got $mcp_rev)"

# ---------------- ADR-004 acceptance: N1 (REQ-032), deleted knobs, V7 --------
# A legit stub at the fixture PASSWD home; an attacker fake at $HOME and via the
# deleted knobs. The gate must resolve the passwd-home binary and ignore both.
EVIL="$TMP/evilhome"; HOMEFIX="$TMP/homefix"; FAKEBIN="$TMP/fakebin"
mkdir -p "$EVIL/.local/bin" "$HOMEFIX/.local/bin" "$FAKEBIN"
mkver() { printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo v; exit 0; }\nprintf "ALLOW: %s\\n"\n' "$2" > "$1"; chmod +x "$1"; }
mkver "$EVIL/.local/bin/claude" "PWNED_BY_HOME"     # planted at $HOME/.local/bin
mkver "$HOMEFIX/.local/bin/claude" "fixture-legit"  # the passwd-home binary
mkver "$FAKEBIN/claude" "KNOB_PWNED"                # planted at the deleted-knob path

# NO --binary-resolver here: exercise the REAL resolver over the Class-0 safe path.
out="$(HOME="$EVIL" \
       CLAUDE_GATE_CLAUDE_BIN="$FAKEBIN/claude" \
       CLAUDE_GATE_SAFE_PATH="$FAKEBIN" \
       CLAUDE_GATE_ENV_VARS="LD_PRELOAD,ANTHROPIC_BASE_URL" \
       LD_PRELOAD="/tmp/eeevil.so" \
       python3 "$HARNESS" --passwd-home "$HOMEFIX" -- --cwd "$PROJ" --reviewer claude "review" plan.md)"; rc=$?
{ printf '%s' "$out" | grep -q 'fixture-legit'; } \
  && ok "N1/V7: resolution is from the passwd home (getpwnam)" \
  || bad "N1/V7: passwd-home binary not used (rc=$rc $out)"
{ ! printf '%s' "$out" | grep -q 'PWNED_BY_HOME'; } \
  && ok "V7: HOME=<attacker> ignored (D1 fix: fake at \$HOME/.local/bin not resolved)" \
  || bad "V7: HOME poisoning resolved the fake -- D1 OPEN (rc=$rc $out)"
{ ! printf '%s' "$out" | grep -q 'KNOB_PWNED'; } \
  && ok "N1: CLAUDE_GATE_CLAUDE_BIN/SAFE_PATH/ENV_VARS deleted knobs ignored" \
  || bad "N1: a deleted env knob was honored (rc=$rc $out)"

# V7 doctor fail verdict: empty passwd home + HOME=<attacker> -> claude
# unresolvable -> UNHEALTHY, exit non-zero. Pre-D1 resolved the fake at $HOME and
# certified it HEALTHY (exit 0).
EMPTY="$TMP/emptyhome"; mkdir -p "$EMPTY/.local/bin"
HOME="$EVIL" python3 "$HARNESS" --passwd-home "$EMPTY" -- --cwd "$PROJ" doctor >/dev/null 2>&1; drc=$?
[ "$drc" -ne 0 ] && ok "V7: doctor exits non-zero when claude is not trustably resolvable" \
                 || bad "V7: doctor certified a missing/fake claude as healthy (rc=$drc)"

# ---------------- N1 codex: the codex reviewer faces the SAME getpwnam hardening
# The N1 property extends to codex: a legit codex at the fixture PASSWD home, an
# attacker fake at $HOME. reviewer=codex must resolve from the passwd home (getpwnam
# safe path) and ignore the fake, and doctor must not certify the fake.
mkver "$EVIL/.local/bin/codex"    "CODEX_PWNED_BY_HOME"   # planted at $HOME/.local/bin
mkver "$HOMEFIX/.local/bin/codex" "codex-fixture-legit"   # the passwd-home binary
cout="$(HOME="$EVIL" python3 "$HARNESS" --passwd-home "$HOMEFIX" -- --cwd "$PROJ" --reviewer codex "review" plan.md)"; crc=$?
{ printf '%s' "$cout" | grep -q 'codex-fixture-legit'; } \
  && ok "N1 codex: reviewer=codex resolves from the passwd home (getpwnam)" \
  || bad "N1 codex: passwd-home codex not used (rc=$crc $cout)"
{ ! printf '%s' "$cout" | grep -q 'CODEX_PWNED_BY_HOME'; } \
  && ok "N1 codex: HOME=<attacker> fake codex not resolved" \
  || bad "N1 codex: HOME poisoning resolved the fake codex (rc=$crc $cout)"
# doctor must report the fake codex as NOT FOUND (never certify it): empty passwd
# home + HOME=<attacker> -> codex is unresolvable on the Class-0 safe path.
cdout="$(HOME="$EVIL" python3 "$HARNESS" --passwd-home "$EMPTY" -- --cwd "$PROJ" doctor 2>/dev/null)"
{ printf '%s' "$cdout" | grep -Eq 'codex[[:space:]]*:[[:space:]]*NOT FOUND' \
   && ! printf '%s' "$cdout" | grep -q 'CODEX_PWNED_BY_HOME'; } \
  && ok "N1 codex: doctor reports the fake codex NOT FOUND (does not certify it)" \
  || bad "N1 codex: doctor certified/omitted the fake codex ($cdout)"

# Tool-use taint: a codex reviewer run that executed ANY shell command is refused
# (verdict dropped, its output never trusted or stored) -- closes the local-file
# disclosure channel that `-s read-only` alone leaves open. Verified at the
# _codex_extract layer with synthetic JSONL: a command_execution + an ALLOW that
# carries a secret must yield the refusal string, no verdict, and no leaked bytes.
if python3 - "$SDP_ROOT" <<'PY'
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts")
import review_gate as r
TS = '{"type":"turn.started"}'
TC = '{"type":"turn.completed"}'
AM = '{"type":"item.completed","item":{"id":"2","type":"agent_message","text":"ALLOW: ok root:x:0:0:SECRET"}}'
CE0 = '{"type":"item.started","item":{"id":"1","type":"command_execution","command":"cat /etc/passwd"}}'
CE1 = '{"type":"item.completed","item":{"id":"1","type":"command_execution","aggregated_output":"root:x:0:0:SECRET"}}'
# A tool-tainted run is refused even though it is otherwise well-formed and completed
# (one turn.started -> agent_message -> turn.completed); only the command items differ.
tainted = "\n".join([TS, CE0, CE1, AM, TC])
out = r._codex_extract(tainted)
assert r._first_verdict(out) is None, ("tainted run produced a verdict", out)
assert "SECRET" not in out, ("secret leaked through extract", out)
# Fail-CLOSED on an unverifiable stream, each otherwise valid but for one anomaly:
assert r._first_verdict(r._codex_extract(TS + "\n" + AM)) is None, "truncated (no turn.completed) trusted"
assert r._first_verdict(r._codex_extract(TS + "\n" + AM + "\n{bad\n" + TC)) is None, "malformed line trusted"
UNK = '{"type":"item.completed","item":{"type":"web_search"}}'
assert r._first_verdict(r._codex_extract(TS + "\n" + UNK + "\n" + AM + "\n" + TC)) is None, "unknown item type trusted"
# Unknown TOP-LEVEL event with no `item` (an item-type-only check would miss it):
TOP = '{"type":"tool_call","name":"read_file"}'
assert r._first_verdict(r._codex_extract(TS + "\n" + TOP + "\n" + AM + "\n" + TC)) is None, "unknown top-level event trusted"
# item.* event without a valid item object must not be vacuously accepted:
NULLITEM = '{"type":"item.completed","item":null}'
assert r._first_verdict(r._codex_extract(TS + "\n" + NULLITEM + "\n" + AM + "\n" + TC)) is None, "null item trusted"
# Ordering / binding: trailing event, double completion, agent_message outside the turn.
assert r._first_verdict(r._codex_extract(TS + "\n" + AM + "\n" + TC + "\n" + AM)) is None, "trailing event trusted"
assert r._first_verdict(r._codex_extract(TS + "\n" + AM + "\n" + TC + "\n" + TC)) is None, "double completion trusted"
assert r._first_verdict(r._codex_extract(AM + "\n" + TS + "\n" + TC)) is None, "agent_message before turn.started trusted"
# A clean, completed, tool-free run keeps its verdict.
clean = "\n".join([TS, '{"type":"item.completed","item":{"id":"2","type":"agent_message","text":"ALLOW: clean"}}', TC])
assert r._first_verdict(r._codex_extract(clean)) == "ALLOW: clean", "compliant run lost its verdict"
PY
then ok "codex tool-use taint: command run -> verdict refused, no secret leak; clean run passes"
else bad "codex tool-use taint not refused (disclosure channel open)"; fi

# TOCTOU-safe exec: a binary in a group/world-writable dir is usable (agy in
# Homebrew's /opt/homebrew/bin) because the gate execs a hardlink of the validated
# inode from a uid-only dir -- a path swap cannot substitute it. The linked-inode
# fstat still rejects a group/world-writable or wrong-owner file, and world-writable
# PARENTS are still refused early by _trusted_binary.
if python3 - "$SDP_ROOT" <<'PY'
import sys, os, stat, tempfile
sys.path.insert(0, f"{sys.argv[1]}/scripts")
import review_gate as r
from pathlib import Path
# group-writable PARENT no longer refuses (the exec-time hardlink closes the swap):
d = tempfile.mkdtemp(); os.chmod(d, 0o775)          # group-writable dir
b = os.path.join(d, "tool"); open(b, "w").write("#!/bin/sh\necho ok\n"); os.chmod(b, 0o755)
p, e = r._trusted_binary("tool", Path("/tmp/nope")) if False else (None, None)
# _trusted_binary uses the safe path, so exercise the exec helper directly:
ep, td, err = r._toctou_safe_exec(Path(b))
assert ep is not None, ("group-writable-parent binary refused", err)
assert td and os.path.isdir(td), "no uid-only tmpdir created"
assert os.stat(td).st_mode & 0o077 == 0, "tmpdir is not 0700"
assert os.stat(ep).st_ino == os.stat(b).st_ino, "hardlink is not the validated inode"
r._cleanup_exec(td); assert not os.path.exists(td), "tmpdir not cleaned"
# a group/world-writable FILE is still refused at the linked-inode fstat:
os.chmod(b, 0o777)
ep2, td2, err2 = r._toctou_safe_exec(Path(b))
assert ep2 is None and "writable" in err2, ("group/world-writable file accepted", err2)
# world-writable PARENT is still refused early:
os.chmod(d, 0o777); os.chmod(b, 0o755)
# (drive _trusted_binary via its resolver seam so the world-writable dir is the one checked)
r._BINARY_RESOLVER = lambda n: b
tp, te = r._trusted_binary("tool", Path("/tmp/nope"))
r._BINARY_RESOLVER = None
assert tp is None and "world writable" in te, ("world-writable parent accepted", te)
import shutil; shutil.rmtree(d, ignore_errors=True)
# Ancestry: a temp exec dir under a group/world-writable ancestor is unraceable
# only if every ancestor is uid-owned and non-writable. Simulate a writable parent.
gw = tempfile.mkdtemp(); os.chmod(gw, 0o775)
child = os.path.join(gw, "c"); os.mkdir(child); os.chmod(child, 0o700)
assert r._path_ancestry_trusted(child) is False, "writable ancestor accepted"
assert r._path_ancestry_trusted(os.path.expanduser("~")) is True, "normal home rejected"
shutil.rmtree(gw, ignore_errors=True)
PY
then ok "TOCTOU-safe exec: group-writable-parent binary usable via validated hardlink; writable file/world-parent/ancestry refused"
else bad "TOCTOU-safe exec check failed"; fi

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
