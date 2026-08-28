#!/usr/bin/env python3
"""Generate the repo-root plugin mirror from the canonical ``plugins/sdp/`` tree.

ADR-005: ``plugins/sdp/`` is the single source of truth. During the interim
window (P2 -> P11) this generator emits the root mirror so every payload edit
lands once, in the canonical tree, instead of twice. Option A deletes this
generator together with the root mirror at P12.

Scope: ``scripts/``, ``skills/``, ``commands/``, ``hooks/``. ``core/`` is EXCLUDED from the
mirror: the two ``core/`` trees are host-specialized on reviewer DIRECTION only
(root/Claude host -> codex reviewer via ``review_gate.py``; plugin/codex host ->
Claude reviewer via the MCP ``claude_review_gate``). The 3-state POLICY semantics
(the INFRA_ERROR merge/push interlock, the escalate_from/max_block halt limits,
and the sanctioned record-marker path) are reconciled to be identical across both
trees (P6 step-0). ``tests/docs.sh`` guard (xi) BOUNDS the divergence -- it (a)
pins those policy sentences in both trees, (b) requires each host's gate command
block to name the OPPOSITE reviewer so an MCP-unavailable fallback cannot
self-review, and (c) pins the per-file divergent-line count and requires every
divergent line to be a reviewer-direction line, so an added contradiction trips
it. It is a bound, not a proof of full equivalence. Full text-unification
(dropping the direction divergence entirely) awaits the cross-provider gate and is
deferred; mirroring today would clobber the direction specialization.

Host divergence is explicit, never implicit:

* ``{{HOST_GATES}}`` substitutes per host ("codex gates" for the root/Claude
  mirror). Dormant until ``run_segment_tmux.sh`` is tokenised (P10).
* Files that legitimately diverge per host beyond a token are REGISTERED in
  ``HOST_DIVERGENT`` and NOT generated -- they are hand-maintained in both trees
  until their content is reconciled (P6/P10) or the trees merge (P11). Silently
  mirroring them would clobber the divergence (that is exactly N8).
* Root-only tooling (this file, the bumper) is REGISTERED in ``ROOT_ONLY`` and
  has no canonical counterpart.
* The **MCP manifest is host-divergent** (OQ-1 resolution): Claude reads
  ``plugins/sdp/.mcp.json`` (``${CLAUDE_PLUGIN_ROOT}`` -- Claude expands it to the
  install dir); codex reads ``plugins/sdp/.mcp.codex.json`` (``cwd:"."`` +
  relative ``args`` -- codex does NOT expand ``${VAR}`` and resolves a relative
  ``cwd`` against the installed plugin cache dir). The codex copy is DERIVED from
  the Claude manifest here so the two never drift; ``.codex-plugin/plugin.json``
  points its ``mcpServers`` at the codex copy.

``--check`` regenerates into a temp dir and ``diff``s against the worktree (and
recomputes the derived codex manifest); it never writes the worktree and never
stages anything. A pre-commit hook that regenerated-and-``git add``ed would
launder a hand-edit -- verify only.
"""

from __future__ import annotations

import argparse
import base64
import filecmp
import json
import shutil
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CANONICAL = ROOT / "plugins" / "sdp"

SUBTREES = ("scripts", "skills", "commands", "hooks")

# Host-divergent MCP manifests: the codex copy is DERIVED from the Claude copy.
CLAUDE_MCP = CANONICAL / ".mcp.json"          # ${CLAUDE_PLUGIN_ROOT}, no cwd
CODEX_MCP = CANONICAL / ".mcp.codex.json"     # cwd:".", relative args, no ${VAR}
CODEX_HOOKS = CANONICAL / "hooks" / "hooks.codex.json"
WIN_HOOK_PS1 = CANONICAL / "hooks" / "precompact_windows.ps1"
WIN_PS_EXE = r"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

# rel-path (from repo root) -> reason. Not generated; hand-maintained per host.
HOST_DIVERGENT = {
    "scripts/run_segment_tmux.sh": "host gate clause differs; {{HOST_GATES}} token lands P10",
    "commands/sdp.md": "host gate semantics (CODEX_GATE_MODE vs INFRA_ERROR) reconciled P6/P10",
    "commands/batch-sdp.md": "host gate semantics reconciled P6/P10",
    "commands/worktree-dispatch.md": "host gate semantics reconciled P6/P10",
}

# rel-path (from repo root) -> reason. Root-only; no canonical source.
ROOT_ONLY = {
    "scripts/bump_codex_plugin_version.py",
    "scripts/build_plugin_tree.py",
}

# Substituted when emitting the root mirror from the canonical tree.
SUBSTITUTIONS = {"{{HOST_GATES}}": "codex gates"}

SKIP_DIR_NAMES = {"__pycache__"}


def _canonical_files() -> list[Path]:
    files: list[Path] = []
    for subtree in SUBTREES:
        base = CANONICAL / subtree
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if any(part in SKIP_DIR_NAMES for part in path.relative_to(CANONICAL).parts):
                continue
            if path.is_file():
                files.append(path)
    return files


def _rel_from_root(canonical_file: Path) -> str:
    # plugins/sdp/skills/x -> skills/x
    return str(canonical_file.relative_to(CANONICAL))


def _render(canonical_file: Path) -> bytes:
    data = canonical_file.read_bytes()
    for token, value in SUBSTITUTIONS.items():
        data = data.replace(token.encode("utf-8"), value.encode("utf-8"))
    return data


def _emit_into(dest_root: Path) -> list[str]:
    """Write the generated mirror under dest_root. Returns the rel paths written."""
    written: list[str] = []
    for canonical_file in _canonical_files():
        rel = _rel_from_root(canonical_file)
        if rel in HOST_DIVERGENT or rel in ROOT_ONLY:
            continue
        target = dest_root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(_render(canonical_file))
        shutil.copymode(canonical_file, target)
        written.append(rel)
    return written


def _codex_manifest_bytes() -> bytes:
    """Derive the codex-visible MCP manifest from the Claude manifest.

    codex does not expand ``${VAR}`` and resolves a relative ``cwd`` against the
    installed plugin cache dir, so the codex copy strips ``${CLAUDE_PLUGIN_ROOT}/``
    from ``args`` and pins ``cwd:"."``. Everything else (command, timeouts) is
    carried verbatim, so a change to the Claude manifest propagates here.
    """
    data = json.loads(CLAUDE_MCP.read_text(encoding="utf-8"))
    for cfg in data.get("mcpServers", {}).values():
        cfg["args"] = [a.replace("${CLAUDE_PLUGIN_ROOT}/", "./") for a in cfg.get("args", [])]
        cfg["cwd"] = "."
    return (json.dumps(data, indent=2) + "\n").encode("utf-8")


def _ps_payload(verb: str) -> str:
    """precompact_windows.ps1, comment-stripped, with the verb substituted.

    Comment and blank lines are dropped before encoding because base64 over UTF-16LE
    inflates ~2.67x and the whole reason the payload exists is a command-line length
    ceiling. The rationale stays in the reviewable .ps1.
    """
    text = WIN_HOOK_PS1.read_text(encoding="utf-8")
    body = "\n".join(
        line for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )
    return body.replace("__SDP_VERB__", verb)


def _codex_hooks_bytes() -> bytes:
    """Derive the codex hook manifest's Windows commands from the .ps1 source.

    Same contract as the codex MCP manifest above: one source of truth, derived
    rather than hand-maintained, and --check reports a stale payload. Codex's Windows
    hook runtime wraps the whole command line for ``cmd.exe /C`` (openai/codex#38168),
    so the derived command must contain no double quote at all -- which a base64
    payload and an absolute %SystemRoot% path satisfy.
    """
    data = json.loads(CODEX_HOOKS.read_text(encoding="utf-8"))
    for entries in data.get("hooks", {}).values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                verb = hook["command"].rsplit(" ", 1)[-1]
                payload = base64.b64encode(
                    _ps_payload(verb).encode("utf-16-le")
                ).decode("ascii")
                hook["commandWindows"] = (
                    f"{WIN_PS_EXE} -NoProfile -NonInteractive -EncodedCommand {payload}"
                )
                if '"' in hook["commandWindows"]:
                    raise SystemExit("derived commandWindows contains a quote")
    return (json.dumps(data, indent=2) + "\n").encode("utf-8")


def build() -> int:
    # Canonical hook payloads are refreshed BEFORE the mirror is emitted, so the root
    # copy is generated from the up-to-date canonical file rather than a stale one.
    CODEX_HOOKS.write_bytes(_codex_hooks_bytes())
    written = _emit_into(ROOT)
    CODEX_MCP.write_bytes(_codex_manifest_bytes())
    print(f"generated {len(written)} file(s) into the root mirror")
    print(f"derived host-divergent codex manifest {CODEX_MCP.name}")
    print(f"derived Windows hook payloads in {CODEX_HOOKS.name} from {WIN_HOOK_PS1.name}")
    return 0


def check() -> int:
    with tempfile.TemporaryDirectory(prefix="sdp_regen.") as tmp:
        tmp_root = Path(tmp)
        written = _emit_into(tmp_root)
        mismatches: list[str] = []
        for rel in written:
            generated = tmp_root / rel
            actual = ROOT / rel
            if not actual.exists():
                mismatches.append(f"{rel}: missing in root mirror")
            elif not filecmp.cmp(generated, actual, shallow=False):
                mismatches.append(f"{rel}: root mirror differs from canonical")
        # HOST_DIVERGENT files are deliberately not generated, but silently
        # omitting either host copy is never legitimate. Semantic parity remains
        # a mandatory manual/review checklist item because these pairs differ by
        # design and byte comparison would erase that distinction.
        for rel in sorted(HOST_DIVERGENT):
            canonical = CANONICAL / rel
            root_copy = ROOT / rel
            if not canonical.is_file():
                mismatches.append(f"{rel}: missing canonical host-divergent copy")
            if not root_copy.is_file():
                mismatches.append(f"{rel}: missing root host-divergent copy")
        # host-divergent codex manifest must match what the Claude manifest derives
        if not CODEX_MCP.exists():
            mismatches.append(f"{CODEX_MCP.name}: missing (run build to derive it)")
        elif CODEX_MCP.read_bytes() != _codex_manifest_bytes():
            mismatches.append(f"{CODEX_MCP.name}: stale vs the codex form derived from .mcp.json")
        if not CODEX_HOOKS.exists():
            mismatches.append(f"{CODEX_HOOKS.name}: missing (run build to derive it)")
        elif CODEX_HOOKS.read_bytes() != _codex_hooks_bytes():
            mismatches.append(
                f"{CODEX_HOOKS.name}: commandWindows is stale vs {WIN_HOOK_PS1.name}"
            )
    if mismatches:
        sys.stderr.write("regen check FAILED — root mirror is stale:\n")
        for line in mismatches:
            sys.stderr.write(f"  {line}\n")
        sys.stderr.write("run: python3 scripts/build_plugin_tree.py && git add <paths>\n")
        return 1
    print(
        f"regen check OK — {len(written)} generated file(s) match canonical; "
        f"{len(HOST_DIVERGENT)} host-divergent pair(s) present (manual parity required)"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the root mirror matches canonical; never writes the worktree",
    )
    args = parser.parse_args(argv)
    return check() if args.check else build()


if __name__ == "__main__":
    raise SystemExit(main())
