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


def _selection(path: Path, raw: bytes) -> ConfigSelection:
    return ConfigSelection(
        path=path,
        text=raw.decode("utf-8", errors="replace"),
        sha256=hashlib.sha256(raw).hexdigest(),
    )


def _read_fd_bytes(fd: int, shown: Path, max_bytes: int) -> bytes:
    """Read an already-opened config fd, enforcing regular-file and size limits."""
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ConfigDiscoveryError(f"config is not a regular file: {shown}")
        if st.st_size > max_bytes:
            raise ConfigDiscoveryError(f"config exceeds {max_bytes} bytes: {shown}")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, min(65_536, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise ConfigDiscoveryError(f"config exceeds {max_bytes} bytes: {shown}")
        return b"".join(chunks)
    finally:
        os.close(fd)


def _read_relative(base: Path, parts: tuple[str, ...], max_bytes: int) -> ConfigSelection | None:
    """Read base/parts without following any symlink below trusted base."""
    if not parts or any(part in ("", ".", "..") or "/" in part for part in parts):
        raise ConfigDiscoveryError("invalid relative config path")
    # Keep the caller's path BEFORE resolution. resolve() follows a symlink or
    # junction, so a check that runs only on the resolved base inspects a path the
    # substitution has already been erased from. The POSIX walk below is unaffected
    # (it descends by descriptor from `base`), but the Windows branch validates by
    # name and must be given the raw path to have anything to validate.
    raw_base = base
    # The base itself must be validated BEFORE it is resolved, on every platform.
    # O_NOFOLLOW on the base open below cannot help once resolve() has already
    # replaced a symlinked base with its target -- and XDG_CONFIG_HOME comes from the
    # environment, so a symlinked base is attacker-reachable, not hypothetical.
    # Anchor the walk at the passwd home, NOT at raw_base itself: chaining a path to
    # itself makes the relative part empty, so only the final component would be
    # lstat'd and a symlinked INTERMEDIATE ancestor would pass. Where the base is not
    # under the home (an out-of-home project root), the helper falls back to walking
    # the base's own full ancestry.
    # The rule is about TRUST ANCHORS, not about any particular filesystem.
    #
    # Chaining a path to itself leaves the relative part empty, so only the final
    # component gets lstat'd and a symlinked INTERMEDIATE ancestor slips through.
    # Each base therefore gets the strongest anchor that is actually justified:
    #
    #   base under the passwd home  -> anchor at the home. These are the bases the
    #       ENVIRONMENT can influence (XDG_CONFIG_HOME, ~/.config/sdp, ~/.sdp), and
    #       the home is a trusted origin, so the whole chain below it is walked.
    #   base outside the home       -> anchor at the base. That base is the caller's
    #       own workspace root, supplied by the host, and is trusted by construction
    #       the same way `root` is everywhere else in the gate. Its ancestry belongs
    #       to whoever laid out the machine, not to this process.
    #
    # Walking to the filesystem root for the second case would reject ordinary
    # layouts -- on macOS /tmp is itself a symlink to /private/tmp, so any project
    # under a symlinked path would fail closed. That consequence corroborates the
    # anchor rule; it is not the reason for it. The residual -- an out-of-home base
    # reached through a symlinked ancestor -- is recorded in KNOWN_GAPS NC-30.
    anchor = Path(win_compat.passwd_home())
    try:
        inside = raw_base == anchor or anchor in raw_base.parents
    except (OSError, ValueError):
        inside = False
    try:
        win_compat.reject_reparse_chain(anchor if inside else raw_base, raw_base)
    except OSError as exc:
        raise ConfigDiscoveryError(f"config base is unsafe: {raw_base}: {exc}") from exc
    base = base.resolve(strict=False)
    dir_flags = win_compat.open_flags(os.O_RDONLY, getattr(os, "O_DIRECTORY", 0), getattr(os, "O_NOFOLLOW", 0))
    # O_NONBLOCK prevents a planted FIFO from hanging before fstat rejects it.
    # O_BINARY (0 on POSIX): without it MSVCRT opens in TEXT mode, translating CRLF
    # and stopping at 0x1A, so both the text and the sha256 provenance digest would
    # differ from the bytes actually on disk.
    file_flags = win_compat.open_flags(os.O_RDONLY, getattr(os, "O_NOFOLLOW", 0), getattr(os, "O_NONBLOCK", 0))
    if win_compat.IS_WINDOWS:
        # Windows has neither O_DIRECTORY nor dir_fd: os.supports_dir_fd is empty
        # there, and CPython's own os.open docstring says an unavailable dir_fd
        # raises NotImplementedError -- a RuntimeError subclass, which the
        # `except OSError` clauses below would NOT catch. The openat walk below is
        # therefore unrunnable, not merely slower.
        #
        # This substitute is WEAKER, deliberately and unavoidably. The POSIX walk
        # descends by descriptor, so the directory it validated is the directory it
        # reads; this validates by name and then opens by path, so a component
        # swapped between those two steps is NOT detected. Closing that would need
        # NtCreateFile-class handle-relative traversal. Recorded in KNOWN_GAPS NC-30.
        try:
            # raw_base first: a reparse point AT the base is the substitution the
            # resolved path can no longer show.
            win_compat.walk_checked(raw_base, parts)
            target = win_compat.walk_checked(base, parts)
        except OSError as exc:
            raise ConfigDiscoveryError(
                f"unsafe config path component: {base.joinpath(*parts)}: {exc}"
            ) from exc
        try:
            fd = os.open(str(target), file_flags)
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise ConfigDiscoveryError(
                f"unsafe config path component: {target}: {exc}"
            ) from exc
        raw = _read_fd_bytes(fd, target, max_bytes)
        return _selection(target, raw)
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
        raw = _read_fd_bytes(fd, base.joinpath(*parts), max_bytes)
    finally:
        os.close(current)
    return _selection(base.joinpath(*parts), raw)


def _candidates(
    project: Path,
    basename: str,
    *,
    home_resolver: Callable[[], Path],
    environ: dict[str, str],
) -> Iterable[tuple[Path, tuple[str, ...]]]:
    # Yield the RAW base, not a resolved one. _read_relative resolves internally and
    # needs the pre-resolve path to have anything to validate: resolve() follows a
    # junction, so handing it an already-resolved base erases exactly the
    # substitution the Windows chain check exists to catch. The resolve() calls here
    # stay only as existence checks (strict=True), and their results are discarded.
    project.resolve(strict=True)
    yield project, (".sdp", basename)
    yield project, ("scripts", "sdp", basename)
    home_raw = Path(home_resolver())
    home_raw.resolve(strict=True)
    xdg = environ.get("XDG_CONFIG_HOME")
    if xdg:
        xdg_path = Path(xdg)
        if not xdg_path.is_absolute():
            raise ConfigDiscoveryError("XDG_CONFIG_HOME must be absolute")
        yield xdg_path, ("sdp", basename)
    else:
        yield home_raw, (".config", "sdp", basename)
    yield home_raw, (".sdp", basename)


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
    root.resolve(strict=True)   # existence check only; _read_relative needs the raw path
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
    if win_compat.IS_WINDOWS:
        # A junction is S_ISDIR and NOT S_ISLNK, so the test above passes it. The
        # whole chain has to be walked, not just this component.
        try:
            win_compat.reject_reparse_chain(win_compat.passwd_home(), parent)
        except OSError as exc:
            raise ConfigDiscoveryError(f"provenance directory is unsafe: {parent}: {exc}") from exc
    data = {
        "version": 1,
        "gates": None if selected is None else {"path": str(selected.path), "sha256": selected.sha256},
    }
    encoded = (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    tmp = parent / f".{PROVENANCE_NAME}.{os.getpid()}.tmp"
    flags = win_compat.open_flags(os.O_WRONLY, os.O_CREAT, os.O_EXCL, getattr(os, "O_NOFOLLOW", 0))
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
