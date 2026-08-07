#!/usr/bin/env python3
"""Minimal stdio MCP server for the SDP review gate."""

from __future__ import annotations

import json
import sys
import traceback
from pathlib import Path
from typing import Any, BinaryIO, Literal

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import review_gate  # noqa: E402


SERVER_NAME = "sdp-review-gate"
SERVER_VERSION = "0.1.0"
Framing = Literal["jsonl", "content-length"]


class MessageReadError(ValueError):
    """Protocol parse failure with response framing when it is known."""

    def __init__(self, message: str, framing: Framing | None = None) -> None:
        super().__init__(message)
        self.framing = framing


def _read_message(stream: BinaryIO) -> tuple[dict[str, Any], Framing] | None:
    while True:
        line = stream.readline()
        if line == b"":
            return None
        stripped = line.strip(b" \t\r\n")
        if not stripped:
            continue
        break

    if stripped.startswith(b"{"):
        try:
            return json.loads(stripped.decode("utf-8")), "jsonl"
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MessageReadError(f"invalid JSONL message: {exc}", "jsonl") from exc

    header_lines = [line]
    while True:
        line = stream.readline()
        if line == b"":
            raise MessageReadError("unexpected EOF in Content-Length headers", "content-length")
        if line in (b"\r\n", b"\n"):
            break
        header_lines.append(line)

    length = None
    for line in header_lines:
        key, _, value = line.decode("ascii", errors="ignore").partition(":")
        if key.lower() == "content-length":
            try:
                length = int(value.strip())
            except ValueError as exc:
                raise MessageReadError("invalid Content-Length", "content-length") from exc
            break
    if length is None:
        raise MessageReadError("missing Content-Length")
    if length < 1:
        raise MessageReadError("Content-Length must be positive", "content-length")
    body = stream.read(length)
    if len(body) != length:
        raise MessageReadError("unexpected EOF in message body", "content-length")
    try:
        return json.loads(body.decode("utf-8")), "content-length"
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MessageReadError(f"invalid JSON message: {exc}", "content-length") from exc


def _send_message(stream: BinaryIO, payload: dict[str, Any], framing: Framing) -> None:
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if framing == "jsonl":
        stream.write(body + b"\n")
    else:
        stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
        stream.write(body)
    stream.flush()


def _result(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def _tools() -> list[dict[str, Any]]:
    return [
        {
            "name": "claude_review_gate",
            "description": "Run the SDP directional review gate. This tool is invoked BY codex on codex-authored work, so the primary reviewer is Claude Code -- the OPPOSITE model; agy is the fallback only on infrastructure failure. BLOCK is returned as data, not a transport error.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["prompt", "artifact_path"],
                "properties": {
                    "prompt": {"type": "string"},
                    "artifact_path": {"type": "string"},
                    "cwd": {"type": "string"},
                    # OPTIONAL directional override; defaults to "claude" (this tool
                    # reviews codex-authored work with the opposite model). Never
                    # required -- the wire contract stays {prompt, artifact_path}.
                    "reviewer": {"type": "string", "enum": ["codex", "claude"]},
                },
            },
        },
        {
            "name": "sdp_prepare_team_marker",
            "description": (
                "PREPARE ONLY -- this tool NEVER writes gate state. It composes the team-review "
                "marker a human would record and writes exactly one file, "
                "<gate>/review_gate_<key>.marker-request (mode 0600, atomically published); it "
                "touches no gate log, no .halt, no .infra_flag, no .needs_human, no .inflight and "
                "no audit file, and takes no lock. The result payload is REDACTED: it carries the "
                "request file path and the PASS/FAIL checklist only, never the composed marker "
                "line and never the record-marker command. Recording the marker is a human action "
                "at a terminal via `review_gate.py record-marker`, which refuses without a TTY and "
                "a human-provisioned token. decision= is not exposed here: only the default "
                "`continue` can be prepared through MCP."
            ),
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["artifact_path"],
                "properties": {
                    "artifact_path": {"type": "string"},
                    "cwd": {"type": "string"},
                    "roster": {"type": "string"},
                    "outputs": {"type": "string"},
                    "added": {"type": "string"},
                    "removed": {"type": "string"},
                    "rootcause": {"type": "string"},
                    "summary": {"type": "string"},
                },
            },
        },
        {
            "name": "sdp_gate_doctor",
            "description": "Report local codex/Claude/agy gate toolchain and gate-state status.",
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "cwd": {"type": "string"},
                },
            },
        },
    ]


_MARKER_ARG_FIELDS = ("roster", "outputs", "added", "removed", "rootcause", "summary")


def _call_tool(name: str, args: dict[str, Any]) -> dict[str, Any]:
    if name == "sdp_gate_doctor":
        # The two-axis health line comes from _doctor's text, so an agent asking a
        # wedged gate is no longer told it is healthy.
        text = review_gate.doctor(args.get("cwd"))
        return {"content": [{"type": "text", "text": text}], "isError": False}

    if name == "sdp_prepare_team_marker":
        artifact_path = args.get("artifact_path")
        cwd = args.get("cwd")
        if not isinstance(artifact_path, str):
            return {"content": [{"type": "text", "text": "artifact_path must be a string"}], "isError": True}
        # ADR-003 (3): cwd is type-checked at the MCP boundary, as at :145.
        if cwd is not None and not isinstance(cwd, str):
            return {"content": [{"type": "text", "text": "cwd must be a string"}], "isError": True}
        fields: dict[str, str] = {}
        for field in _MARKER_ARG_FIELDS:
            value = args.get(field, "")
            if value is None:
                value = ""
            if not isinstance(value, str):
                return {"content": [{"type": "text", "text": f"{field} must be a string"}], "isError": True}
            fields[field] = value
        try:
            # redact=True is the ENFORCEMENT, in code rather than by convention:
            # this path structurally cannot return the composed line or the
            # record-marker command. decision= is deliberately NOT exposed, so a
            # pivot/halt request file can only be composed by a human at the CLI.
            request_path, ok, checklist = review_gate.prepare_marker(
                artifact_path, cwd, redact=True, **fields
            )
        except Exception as exc:  # noqa: BLE001 - MCP result must fail closed as data.
            return {
                "content": [{"type": "text", "text": f"BLOCK: INFRA_ERROR ({exc})"}],
                "isError": False,
            }
        text = "\n".join([
            f"request_file: {request_path}",
            f"status: {'PREPARED' if ok else 'REFUSED'}",
            *checklist,
        ])
        return {"content": [{"type": "text", "text": text}], "isError": False}

    if name != "claude_review_gate":
        return {"content": [{"type": "text", "text": f"Unknown tool: {name}"}], "isError": True}

    prompt = args.get("prompt")
    artifact_path = args.get("artifact_path")
    cwd = args.get("cwd")
    if not isinstance(prompt, str) or not isinstance(artifact_path, str):
        return {"content": [{"type": "text", "text": "prompt and artifact_path must be strings"}], "isError": True}
    # ADR-003 (3): cwd is type-checked at the MCP boundary. Untyped, a non-string
    # cwd reached run_review and surfaced a raw TypeError as the operator reason.
    if cwd is not None and not isinstance(cwd, str):
        return {"content": [{"type": "text", "text": "cwd must be a string"}], "isError": True}
    # Directional: this MCP tool runs INSIDE codex (codex-authored work), so the
    # author identity IS known at this boundary -- it is codex. The PRIMARY reviewer
    # must therefore be the OPPOSITE model, Claude Code. `reviewer` defaults to
    # "claude"; agy remains the shared infra fallback.
    reviewer = args.get("reviewer", "claude")
    if reviewer not in ("codex", "claude"):
        return {"content": [{"type": "text", "text": "reviewer must be 'codex' or 'claude'"}], "isError": True}
    # ENFORCE same-model exclusion at the one boundary where the author is known.
    # This tool is the codex-authored entry point, so reviewer="codex" would be
    # self-review. Refuse it as data (fail-closed) rather than trust the caller not
    # to ask for it -- the inversion is enforced here, not left to a default.
    if reviewer == "codex":
        return {
            "content": [{"type": "text", "text": (
                "BLOCK: INFRA_ERROR (self-review refused: this codex-side gate cannot "
                "use codex as the reviewer of codex-authored work; the inverse gate "
                "requires the opposite model)"
            )}],
            "isError": False,
        }

    try:
        review = review_gate.run_review(prompt, artifact_path, cwd, reviewer=reviewer)
    except Exception as exc:  # noqa: BLE001 - MCP result must fail closed as data.
        review = {
            "verdict": "INFRA_ERROR",
            "provider": "none",
            "line": f"BLOCK: INFRA_ERROR ({exc})",
            "reason": str(exc),
            "exit_code": 1,
        }

    text = review["line"] + "\n" + json.dumps(
        {
            "verdict": review.get("verdict"),
            "provider": review.get("provider"),
            "reason": review.get("reason", ""),
            "exit_code": review.get("exit_code", 1),
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    return {"content": [{"type": "text", "text": text}], "isError": False}


def _handle(message: dict[str, Any]) -> dict[str, Any] | None:
    request_id = message.get("id")
    method = message.get("method")
    params = message.get("params") or {}

    if request_id is None:
        return None
    if method == "initialize":
        return _result(
            request_id,
            {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "instructions": (
                    "Use claude_review_gate for SDP plan/test gates. It returns ALLOW/BLOCK/INFRA_ERROR as data. "
                    "Do not treat BLOCK as MCP transport failure."
                ),
            },
        )
    if method == "tools/list":
        return _result(request_id, {"tools": _tools()})
    if method == "ping":
        return _result(request_id, {})
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if not isinstance(args, dict):
            return _error(request_id, -32602, "arguments must be an object")
        return _result(request_id, _call_tool(name, args))
    return _error(request_id, -32601, f"method not found: {method}")


def main() -> int:
    inp = sys.stdin.buffer
    out = sys.stdout.buffer
    while True:
        framing: Framing | None = None
        try:
            incoming = _read_message(inp)
            if incoming is None:
                return 0
            message, framing = incoming
            response = _handle(message)
            if response is not None:
                _send_message(out, response, framing)
        except MessageReadError as exc:
            traceback.print_exc(file=sys.stderr)
            if exc.framing is None:
                return 1
            _send_message(out, _error(None, -32700, str(exc)), exc.framing)
        except Exception as exc:  # noqa: BLE001 - keep server alive only by returning JSON-RPC error.
            traceback.print_exc(file=sys.stderr)
            request_id = message.get("id") if "message" in locals() and isinstance(message, dict) else None
            if framing is not None:
                _send_message(out, _error(request_id, -32603, str(exc)), framing)
            else:
                return 1


if __name__ == "__main__":
    raise SystemExit(main())
