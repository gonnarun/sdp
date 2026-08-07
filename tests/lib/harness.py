#!/usr/bin/env python3
"""Test-only entrypoint that binds review_gate's ADR-004 seams IN THE CHILD.

The seams (``_BINARY_RESOLVER`` / ``_ENV_CONF_PATH`` / ``_PASSWD_HOME``) are
module attributes. A parent bash process cannot rebind an attribute inside a
python child it spawns, so tests spawn THIS instead of the bare gate. The seam is
bound through **argv** (T3 -- the attacker must control the child's command
line, i.e. already run code as this uid), never through ambient env (T2). That
is the whole T2/T3 distinction ADR-004 rests on.

NEVER shipped in plugins/sdp/. review_gate.py and sdp_mcp_server.py contain zero
references to this file, so no production invocation can reach it.

Usage:
  harness.py [--binary-resolver FIXTURE.json] [--env-conf PATH]
             [--passwd-home DIR] [--isatty true|false] [--append-fail-after N]
             [--entry cli|server] -- <gate argv...>

  FIXTURE.json maps a binary name to an absolute path, e.g.
  {"claude": "/tmp/bin/claude", "agy": "/tmp/bin/agy"}. A missing name resolves
  to None (not found). The resolved path still faces every trust check.
"""

from __future__ import annotations

import argparse
import json
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--binary-resolver")
    ap.add_argument("--env-conf")
    ap.add_argument("--passwd-home")
    # Seam 4 (B1, NC-22): a test-only, argv-bound override of the TTY control
    # ADR-G02b rests on. Consistent with ADR-G02b's posture -- the control is
    # affordance, not capability -- but RECORDED rather than assumed harmless.
    ap.add_argument("--isatty", choices=("true", "false"))
    # Seam 5 (D-2): the first N _APPEND_LINE calls delegate to the real
    # _append_line; every later one returns False. This is the ONLY lever that
    # reaches record_marker's compensating-append failure branch -- both appends
    # target one log path inside one held lock, so no filesystem permission trick
    # can fail the second without failing the first.
    ap.add_argument("--append-fail-after", type=int)
    ap.add_argument("--entry", choices=("cli", "server"), default="cli")
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    scripts = os.path.abspath(os.path.join(here, "..", "..", "scripts"))
    sys.path.insert(0, scripts)

    import review_gate  # noqa: E402

    if args.passwd_home:
        review_gate._PASSWD_HOME = args.passwd_home
    if args.env_conf:
        review_gate._ENV_CONF_PATH = args.env_conf
    if args.binary_resolver:
        with open(args.binary_resolver, encoding="utf-8") as handle:
            table = json.load(handle)
        review_gate._BINARY_RESOLVER = lambda name, _t=table: _t.get(name)
    if args.isatty:
        value = args.isatty == "true"
        review_gate._ISATTY = lambda _fd, _v=value: _v
    if args.append_fail_after is not None:
        real = review_gate._append_line
        budget = {"n": args.append_fail_after}

        def _failing_append(path, line, _real=real, _budget=budget):
            if _budget["n"] <= 0:
                return False
            _budget["n"] -= 1
            return _real(path, line)

        review_gate._APPEND_LINE = _failing_append

    rest = list(args.rest)
    if rest and rest[0] == "--":
        rest = rest[1:]

    if args.entry == "server":
        import sdp_mcp_server  # noqa: E402 -- reuses the already-bound review_gate
        return sdp_mcp_server.main()
    return review_gate.main(rest)


if __name__ == "__main__":
    raise SystemExit(main())
