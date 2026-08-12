#!/usr/bin/env bash
# mcp_server.sh — MCP protocol smoke for scripts/sdp_mcp_server.py.
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP="$(mktemp -d -t sdp_mcp_test.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/project"; BIN="$TMP/bin"; GX="$TMP/xdg"
mkdir -p "$PROJ" "$BIN" "$GX/sdp"
printf 'plan body\n' > "$PROJ/plan.md"
printf 'model: mcp-global-model\n' > "$GX/sdp/gates.yaml"

cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "Claude Code stub"; exit 0; }
printf 'ALLOW: mcp claude ok\n'
STUB
chmod +x "$BIN/claude"

cat > "$BIN/agy" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "agy stub"; exit 0; }
printf 'ALLOW: mcp agy ok\n'
STUB
chmod +x "$BIN/agy"

# ADR-004 deleted CLAUDE_GATE_SAFE_PATH/ENV_VARS; the server is spawned via the
# harness (--entry server), which binds the stub resolver in-child via argv.
RESOLVER="$TMP/resolver.json"
printf '{"claude": "%s", "agy": "%s"}\n' "$BIN/claude" "$BIN/agy" > "$RESOLVER"
export SDP_ROOT PROJ BIN RESOLVER XDG_CONFIG_HOME="$GX"
python3 <<'PY'
import json
import os
import subprocess
import sys

root = os.environ["SDP_ROOT"]
proj = os.environ["PROJ"]
resolver = os.environ["RESOLVER"]
proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "tests", "lib", "harness.py"),
     "--binary-resolver", resolver, "--entry", "server"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=dict(os.environ),
)

def send(payload):
    body = json.dumps(payload).encode()
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    proc.stdin.flush()

def send_jsonl(payload):
    proc.stdin.write(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
    proc.stdin.flush()

def recv():
    header = b""
    while b"\r\n\r\n" not in header:
        chunk = proc.stdout.read(1)
        if not chunk:
            raise RuntimeError("server closed")
        header += chunk
    length = None
    for line in header.decode().splitlines():
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    if length is None:
        raise RuntimeError("missing length")
    return json.loads(proc.stdout.read(length).decode())

def recv_jsonl():
    line = proc.stdout.readline()
    if not line:
        raise RuntimeError("server closed")
    return json.loads(line.decode())

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}})
init = recv()
assert init["result"]["serverInfo"]["name"] == "sdp-review-gate", init

send_jsonl({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
tools = recv_jsonl()["result"]["tools"]
assert any(t["name"] == "claude_review_gate" for t in tools), tools

proc.stdin.write(b'{"jsonrpc":"2.0","id":99,"method":}\n')
proc.stdin.flush()
parse_error = recv_jsonl()
assert parse_error["id"] is None, parse_error
assert parse_error["error"]["code"] == -32700, parse_error

send_jsonl({"jsonrpc": "2.0", "id": 4, "method": "ping", "params": {}})
assert recv_jsonl()["result"] == {}, "server did not survive malformed JSONL"

send({
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
        "name": "claude_review_gate",
        "arguments": {"cwd": proj, "prompt": "review", "artifact_path": "plan.md"},
    },
})
call = recv()["result"]
text = call["content"][0]["text"]
assert call["isError"] is False, call
assert text.startswith("ALLOW: mcp claude ok"), text
audit = os.path.join(proj, ".private", "sdp-artifacts", "gate-audit.ndjson")
row = json.loads(open(audit, encoding="utf-8").read().splitlines()[-1])
assert row["config_source"] == os.path.realpath(os.path.join(os.environ["XDG_CONFIG_HOME"], "sdp", "gates.yaml")), row

proc.stdin.close()
proc.wait(timeout=5)
assert proc.returncode == 0, proc.returncode
PY
rc=$?
[ "$rc" -eq 0 ] && ok "MCP initialize/list/call + global gates discovery works" || bad "MCP smoke failed"

# The root/canonical server cmp was deleted at P11: it asserted a byte-identity
# that Option A collapses (the root mirror is a P12 deletion target), and it
# masked C2 -- the manifest-resolution divergence is asserted in codex_plugin.sh.

# Directional inverse gate: this MCP tool is the codex-authored boundary, so
# reviewer="codex" is self-review and MUST be refused at the entry point (not
# left to the caller). Assert the enforcement, not just the default.
if python3 - "$SDP_ROOT" <<'PY'
import sys
sys.path.insert(0, f"{sys.argv[1]}/scripts")
import sdp_mcp_server as s
msg = {"jsonrpc": "2.0", "id": 9, "method": "tools/call",
       "params": {"name": "claude_review_gate",
                  "arguments": {"prompt": "x", "artifact_path": "/tmp/x.md", "reviewer": "codex"}}}
r = s._handle(msg)
text = r["result"]["content"][0]["text"]
assert "self-review refused" in text, text
assert not r["result"].get("isError", False), r          # returned as data, fail-closed
PY
then ok "MCP refuses codex self-review (inversion enforced at the codex boundary)"
else bad "MCP did NOT refuse codex self-review"; fi

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
