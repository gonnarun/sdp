#!/usr/bin/env python3
"""Canonical SDP config discovery and safe file reads (stdlib only)."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

import win_compat


MAX_CONFIG_BYTES = 1_048_576
MAX_PROVENANCE_BYTES = 16_384
PROVENANCE_NAME = "sdp-config-provenance.json"
CONFIG_NAMES = frozenset({"defaults.yaml", "gates.yaml"})


class ConfigDiscoveryError(RuntimeError):
    """Unsafe or unreadable configuration state."""


@dataclass(frozen=True)
class ConfigSelection:
    path: Path
    text: str
    sha256: str


def passwd_home() -> Path:
    # Resolved from the OS identity API, never os.environ. The platform branch
    # (and the POSIX-only module it needs) lives in win_compat; see ADR-W03.
    return Path(win_compat.passwd_home()).resolve(strict=True)


def _read_relative(base: Path, parts: tuple[str, ...], max_bytes: int) -> ConfigSelection | None:
    """Read base/parts without following any symlink below trusted base."""
    if not parts or any(part in ("", ".", "..") or "/" in part for part in parts):
        raise ConfigDiscoveryError("invalid relative config path")
    base = base.resolve(strict=False)
    dir_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    # O_NONBLOCK prevents a planted FIFO from hanging before fstat rejects it.
    file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        current = os.open(str(base), dir_flags)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise ConfigDiscoveryError(f"config base unusable: {base}: {exc}") from exc
    try:
        for part in parts[:-1]:
            try:
                nxt = os.open(part, dir_flags, dir_fd=current)
            except FileNotFoundError:
                return None
            except OSError as exc:
                raise ConfigDiscoveryError(
                    f"unsafe config path component: {base.joinpath(*parts)}: {exc}"
                ) from exc
            os.close(current)
            current = nxt
        try:
            fd = os.open(parts[-1], file_flags, dir_fd=current)
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise ConfigDiscoveryError(
                f"unsafe or unreadable config: {base.joinpath(*parts)}: {exc}"
            ) from exc
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                raise ConfigDiscoveryError(
                    f"config is not a regular file: {base.joinpath(*parts)}"
                )
            if st.st_size > max_bytes:
                raise ConfigDiscoveryError(
                    f"config exceeds {max_bytes} bytes: {base.joinpath(*parts)}"
                )
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(fd, min(65_536, max_bytes + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > max_bytes:
                    raise ConfigDiscoveryError(
                        f"config exceeds {max_bytes} bytes: {base.joinpath(*parts)}"
                    )
            raw = b"".join(chunks)
        finally:
            os.close(fd)
    finally:
        os.close(current)
    path = base.joinpath(*parts)
    return ConfigSelection(
        path=path,
        text=raw.decode("utf-8", errors="replace"),
        sha256=hashlib.sha256(raw).hexdigest(),
    )


def _candidates(
    project: Path,
    basename: str,
    *,
    home_resolver: Callable[[], Path],
    environ: dict[str, str],
) -> Iterable[tuple[Path, tuple[str, ...]]]:
    project = project.resolve(strict=True)
    yield project, (".sdp", basename)
    yield project, ("scripts", "sdp", basename)
    home = Path(home_resolver()).resolve(strict=True)
    xdg = environ.get("XDG_CONFIG_HOME")
    if xdg:
        xdg_path = Path(xdg)
        if not xdg_path.is_absolute():
            raise ConfigDiscoveryError("XDG_CONFIG_HOME must be absolute")
        yield xdg_path.resolve(strict=False), ("sdp", basename)
    else:
        yield home, (".config", "sdp", basename)
    yield home, (".sdp", basename)


def discover(
    project: Path,
    basename: str,
    *,
    home_resolver: Callable[[], Path] = passwd_home,
    environ: dict[str, str] | None = None,
) -> ConfigSelection | None:
    if basename not in CONFIG_NAMES:
        raise ConfigDiscoveryError(f"unsupported config basename: {basename}")
    env = dict(os.environ if environ is None else environ)
    try:
        candidates = _candidates(project, basename, home_resolver=home_resolver, environ=env)
        for base, parts in candidates:
            selected = _read_relative(base, parts, MAX_CONFIG_BYTES)
            if selected is not None:
                return selected
    except (OSError, RuntimeError) as exc:
        if isinstance(exc, ConfigDiscoveryError):
            raise
        raise ConfigDiscoveryError(f"config discovery failed: {exc}") from exc
    return None


def read_workspace_file(root: Path, raw_path: str, max_bytes: int) -> ConfigSelection:
    root = root.resolve(strict=True)
    candidate = Path(raw_path)
    if not candidate.is_absolute():
        candidate = root / candidate
    normalized = Path(os.path.normpath(str(candidate)))
    try:
        rel = normalized.relative_to(root)
    except ValueError as exc:
        raise ConfigDiscoveryError(f"path escapes workspace: {raw_path}") from exc
    selected = _read_relative(root, tuple(rel.parts), max_bytes)
    if selected is None:
        raise ConfigDiscoveryError(f"file not found: {raw_path}")
    return selected


def _provenance_path(project: Path) -> Path:
    return project.resolve(strict=True) / ".private" / PROVENANCE_NAME


def write_gate_provenance(project: Path, expected_path: str) -> Path:
    project = project.resolve(strict=True)
    selected = discover(project, "gates.yaml")
    actual = str(selected.path) if selected else ""
    expected = str(Path(expected_path).resolve(strict=False)) if expected_path else ""
    if actual != expected:
        raise ConfigDiscoveryError(
            f"gates selection changed during anchor: expected={expected or '<none>'} actual={actual or '<none>'}"
        )
    dest = _provenance_path(project)
    parent = dest.parent
    try:
        pst = os.lstat(parent)
    except OSError as exc:
        raise ConfigDiscoveryError(f"provenance directory unusable: {parent}: {exc}") from exc
    if not stat.S_ISDIR(pst.st_mode) or stat.S_ISLNK(pst.st_mode):
        raise ConfigDiscoveryError(f"provenance directory is unsafe: {parent}")
    data = {
        "version": 1,
        "gates": None if selected is None else {"path": str(selected.path), "sha256": selected.sha256},
    }
    encoded = (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    tmp = parent / f".{PROVENANCE_NAME}.{os.getpid()}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(str(tmp), flags, 0o600)
        try:
            os.write(fd, encoded)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp, dest)
        os.chmod(dest, 0o600)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise ConfigDiscoveryError(f"provenance write failed: {exc}") from exc
    return dest


def verify_gate_provenance(project: Path, selected: ConfigSelection | None) -> None:
    project = project.resolve(strict=True)
    dest = _provenance_path(project)
    try:
        os.lstat(dest)
    except FileNotFoundError:
        return  # documented standalone gate path
    except OSError as exc:
        raise ConfigDiscoveryError(f"provenance unusable: {exc}") from exc
    record = read_workspace_file(project, str(dest), MAX_PROVENANCE_BYTES)
    try:
        data = json.loads(record.text)
    except (ValueError, TypeError) as exc:
        raise ConfigDiscoveryError("provenance is not valid JSON") from exc
    if not isinstance(data, dict) or set(data) != {"version", "gates"} or data.get("version") != 1:
        raise ConfigDiscoveryError("provenance schema is invalid")
    gates = data.get("gates")
    if gates is not None and (
        not isinstance(gates, dict)
        or set(gates) != {"path", "sha256"}
        or not isinstance(gates.get("path"), str)
        or not isinstance(gates.get("sha256"), str)
    ):
        raise ConfigDiscoveryError("provenance gates record is invalid")
    actual = None if selected is None else {"path": str(selected.path), "sha256": selected.sha256}
    if gates != actual:
        raise ConfigDiscoveryError("gates config path/digest differs from anchor provenance; rerun anchor")


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    try:
        if len(args) == 3 and args[0] == "discover":
            selected = discover(Path(args[1]), args[2])
            if selected:
                print(selected.path)
            return 0
        if len(args) == 3 and args[0] == "write-provenance":
            print(write_gate_provenance(Path(args[1]), args[2]))
            return 0
        raise ConfigDiscoveryError(
            "usage: config_discovery.py discover PROJECT {defaults.yaml|gates.yaml} | "
            "write-provenance PROJECT EXPECTED_GATES_PATH"
        )
    except ConfigDiscoveryError as exc:
        print(f"CONFIG ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
