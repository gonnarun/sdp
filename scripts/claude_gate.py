"""Deprecated alias for review_gate. Remove at P12. See REQ-046 / ADR-002.

This module exists only for the agent's file-by-file edit window and any caller
that still imports ``claude_gate``. It delegates every name (privates included)
to ``review_gate`` via a ``sys.modules`` alias, so ``import claude_gate`` keeps
returning a working ``run_review`` until the drop criterion is met.
"""

import sys

import review_gate as _rg

_rg._record_shim_hit()               # unconditional, durable — feeds P12 criterion (b)
if __name__ != "__main__":           # guard: do NOT clobber sys.modules["__main__"]
    sys.modules[__name__] = _rg      # exact alias: privates included, identity preserved
else:
    raise SystemExit(_rg.main())
