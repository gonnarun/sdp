#!/usr/bin/env python3
"""Bump the plugin manifests that act as install-cache keys.

Two manifests, two semantics, one script (ADR-005 sub-decision 1):

  * ``plugins/sdp/.claude-plugin/plugin.json`` — the **Claude** cache key. A real
    ``MAJOR.MINOR.PATCH`` patch increment; Claude ignores any ``+build``
    metadata, so the version must stay a clean semver. (Moved under
    ``plugins/sdp/`` at P11 when it became the one plugin root for both hosts.)
  * ``plugins/sdp/.codex-plugin/plugin.json`` — the **codex** cache key.
    ``<base>+codex.<utc-timestamp>``; codex keys on the literal string.

The dead root ``.codex-plugin/plugin.json`` is **not** a manifest here — it is
consumed by no host and is removed from the tree (REQ-004).

L11 (no partial write): every manifest is read and validated, the next version
is derived for all of them, and only then is anything written. A failure on any
manifest leaves every file on disk untouched.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# (path, semantics) — "patch" = semver patch increment; "codex" = +codex.<ts>.
MANIFESTS: tuple[tuple[Path, str], ...] = (
    (ROOT / "plugins" / "sdp" / ".claude-plugin" / "plugin.json", "patch"),
    (ROOT / "plugins" / "sdp" / ".codex-plugin" / "plugin.json", "codex"),
)


def _base_version(current: str) -> str:
    return current.split("+", 1)[0]


def _bump_patch(current: str) -> str:
    base = _base_version(current)
    parts = base.split(".")
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        raise ValueError(f"not a MAJOR.MINOR.PATCH version: {current!r}")
    parts[2] = str(int(parts[2]) + 1)
    return ".".join(parts)


def _next_version(current: str, semantics: str, cachebuster: str) -> str:
    if semantics == "patch":
        return _bump_patch(current)
    if semantics == "codex":
        return f"{_base_version(current)}+codex.{cachebuster}"
    raise ValueError(f"unknown manifest semantics: {semantics!r}")


def main() -> None:
    cachebuster = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")

    # Phase 1 — read + validate + derive for ALL manifests. Write nothing yet.
    planned: list[tuple[Path, dict, str]] = []
    for path, semantics in MANIFESTS:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        current = manifest.get("version")
        if not isinstance(current, str) or not current.strip():
            raise ValueError(f"{path}: missing non-empty version")
        next_version = _next_version(current, semantics, cachebuster)
        manifest["version"] = next_version
        planned.append((path, manifest, next_version))

    # Phase 2 — write, only after every manifest validated (L11).
    for path, manifest, _ in planned:
        path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    for path, _, next_version in planned:
        print(f"{path.name}: {next_version}")


if __name__ == "__main__":
    main()
