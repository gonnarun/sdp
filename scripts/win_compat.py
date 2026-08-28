#!/usr/bin/env python3
"""Platform layer for the SDP plugin: POSIX identity/permission primitives, and
their Windows substitutes.

Every platform difference in the plugin lives here. Callers import this module and
call its functions unconditionally; the branch is internal. Three rules govern it,
and each one exists because breaking it produced a real failure:

1. ``os.getuid`` is NEVER defined, polyfilled, or assigned -- here or anywhere
   else, in shipped code or in tests. The engine's ownership checks are written as
   ``os.getuid() if hasattr(os, "getuid") else None`` and skip themselves where the
   attribute is absent. Windows reports ``st_uid == 0`` for every file, so waking
   those checks makes ``st.st_uid != uid`` true for correct files and turns the gate
   into a permanent INFRA_ERROR whose symptom is a false forgery accusation.

2. Home and user name are resolved from the OS identity API, never from the
   environment. ``review_gate.py`` states the control: ``$HOME`` is "simultaneously
   load-bearing ... and attacker-settable, so it is resolved from the password DB,
   not os.environ". These resolvers decide where ``~/.sdp/override.token`` and
   ``~/.sdp/marker.token`` are read from, so on Windows they use Win32
   (``SHGetKnownFolderPath`` / ``GetUserNameW``), never ``%USERPROFILE%``.

3. No synthetic module is placed in ``sys.modules``. ``pwd`` and ``fcntl`` are
   imported here, inside the POSIX branch, and never reach a Windows interpreter.

Windows loses POSIX ownership verification entirely (rule 1) and POSIX mode
semantics (NTFS synthesises ``st_mode``, so ordinary files read as 0o666/0o777).
``reject_reparse_chain`` is the replacement control, not a supplement: it is what
stops a junction at ``~/.sdp`` from redirecting a token path, which on POSIX is
caught by the uid check. See ADR-W02/W03/W05 in design_windows-support.md, and the
scope statement in docs/KNOWN_GAPS.md NC-30: Windows support is sound for a
single-account workstation and is NOT equivalent to POSIX on a shared host.

Standard library only (README: no pip installs). Python 3.9 floor.
"""

from __future__ import annotations

import os
import stat as _stat
import sys
from pathlib import Path

IS_WINDOWS = os.name == "nt"

if not IS_WINDOWS:
    import pwd


class WinCompatError(OSError):
    """A platform-layer failure. Callers translate this into their own fail-closed
    error (InfraError in the gate); it is an OSError so existing ``except OSError``
    handlers keep working."""


# ------------------------------------------------------------------- identity

def _win_profile_dir() -> str:
    """User profile directory via Win32. Deliberately not %USERPROFILE%."""
    import ctypes
    from ctypes import wintypes

    class _GUID(ctypes.Structure):
        _fields_ = [
            ("Data1", wintypes.DWORD),
            ("Data2", wintypes.WORD),
            ("Data3", wintypes.WORD),
            ("Data4", ctypes.c_ubyte * 8),
        ]

    # FOLDERID_Profile {5E6C858F-0E22-4760-9AFE-EA3317B67173}
    folderid = _GUID(
        0x5E6C858F,
        0x0E22,
        0x4760,
        (ctypes.c_ubyte * 8)(0x9A, 0xFE, 0xEA, 0x33, 0x17, 0xB6, 0x71, 0x73),
    )

    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    ole32 = ctypes.WinDLL("ole32", use_last_error=True)
    shell32.SHGetKnownFolderPath.argtypes = [
        ctypes.POINTER(_GUID),
        wintypes.DWORD,
        wintypes.HANDLE,
        ctypes.POINTER(ctypes.c_wchar_p),
    ]
    shell32.SHGetKnownFolderPath.restype = ctypes.HRESULT
    ole32.CoTaskMemFree.argtypes = [ctypes.c_void_p]
    ole32.CoTaskMemFree.restype = None

    out = ctypes.c_wchar_p()
    try:
        hr = shell32.SHGetKnownFolderPath(ctypes.byref(folderid), 0, None, ctypes.byref(out))
    except OSError as exc:                       # HRESULT restype raises on failure
        raise WinCompatError(f"SHGetKnownFolderPath failed: {exc}") from exc
    if hr != 0:
        raise WinCompatError(f"SHGetKnownFolderPath failed (hr=0x{hr & 0xFFFFFFFF:08X})")
    try:
        value = out.value
    finally:
        ole32.CoTaskMemFree(out)
    if not value:
        raise WinCompatError("SHGetKnownFolderPath returned an empty path")
    return str(value)


def _win_user_name() -> str:
    """Account name via Win32. Deliberately not %USERNAME%."""
    import ctypes
    from ctypes import wintypes

    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    advapi32.GetUserNameW.argtypes = [wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    advapi32.GetUserNameW.restype = wintypes.BOOL

    size = wintypes.DWORD(0)
    advapi32.GetUserNameW(None, ctypes.byref(size))     # sizing call; always fails
    if size.value <= 0:
        size = wintypes.DWORD(257)                      # UNLEN + 1
    buf = ctypes.create_unicode_buffer(size.value)
    if not advapi32.GetUserNameW(buf, ctypes.byref(size)):
        raise WinCompatError(f"GetUserNameW failed (err={ctypes.get_last_error()})")
    return buf.value


def passwd_home() -> str:
    """Home directory, from the OS identity API. Never from os.environ."""
    if IS_WINDOWS:
        return _win_profile_dir()
    return pwd.getpwuid(os.getuid()).pw_dir


def passwd_name(default: str = "sdp") -> str:
    """Account name, from the OS identity API. Never from os.environ."""
    if IS_WINDOWS:
        try:
            return _win_user_name()
        except OSError:
            return default
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return default


# ----------------------------------------------------------------- permissions

def posix_perms_meaningful() -> bool:
    """True where POSIX mode bits and uid ownership actually mean something.

    Callers gate BOTH halves of a permission check on this -- the ``st_mode``
    test and the ``st_uid`` test together. Gating only the uid half (which is what
    the bare ``hasattr(os, "getuid")`` idiom did) leaves the mode test live on
    NTFS, where every ordinary file reads as group- and world-writable, and the
    gate rejects every correctly installed reviewer binary.
    """
    return hasattr(os, "getuid") and not IS_WINDOWS


def _is_reparse_point(path: Path) -> bool:
    """True if `path` is a symlink, junction, or any other reparse point.

    ``Path.is_symlink()`` alone is not enough on Windows: a directory junction --
    the cheapest substitution primitive there -- is a reparse point that is not
    reported as a symlink.
    """
    try:
        st = os.lstat(path)
    except OSError:
        return False                                  # absent: the caller's own check reports it
    attrs = getattr(st, "st_file_attributes", 0)
    if attrs & getattr(_stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
        return True
    return _stat.S_ISLNK(st.st_mode)


def reject_reparse_chain(base: str | os.PathLike, target: str | os.PathLike) -> None:
    """Raise if any existing component from `base` down to `target` is a reparse point.

    This is the Windows replacement for the uid ownership check, not an addition to
    it. Testing only `target` is insufficient: if ``~/.sdp`` is a junction, statting
    ``~/.sdp/override.token`` follows the junction and the token file itself carries
    no reparse attribute, so a file-only test passes while the path has been
    redirected. On POSIX the uid check catches that redirection; Windows has no uid
    check, so the whole chain must be walked.

    Non-following ``lstat`` throughout. Components that do not exist are skipped --
    absence is the caller's concern, not this function's.
    """
    base_p = Path(base)
    target_p = Path(target)
    if _is_reparse_point(base_p):
        raise WinCompatError(f"path component is a reparse point: {base_p}")
    try:
        rel = target_p.relative_to(base_p)
    except ValueError:
        # target is not under base: walk target's own ancestry instead of silently
        # checking nothing.
        chain = [target_p, *target_p.parents]
        for component in reversed(chain):
            if _is_reparse_point(component):
                raise WinCompatError(f"path component is a reparse point: {component}")
        return
    current = base_p
    for part in rel.parts:
        current = current / part
        if _is_reparse_point(current):
            raise WinCompatError(f"path component is a reparse point: {current}")


# ------------------------------------------------------------------ file locks

LOCK_BYTES = 1                                        # the byte range both backends lock


def lock_exclusive(fd: int) -> None:
    """Take an exclusive, non-blocking lock. Raise OSError if it is held.

    The retry loop, the deadline, and the timeout error stay in the caller
    (``review_gate._state_lock``) so the D-15 serialize-and-both-succeed contract
    is not platform-dependent. This function only has to (1) raise ``OSError`` on
    contention and (2) address the same byte range every time.
    """
    if IS_WINDOWS:
        import msvcrt

        os.lseek(fd, 0, os.SEEK_SET)                  # msvcrt locks from the file position
        msvcrt.locking(fd, msvcrt.LK_NBLCK, LOCK_BYTES)
        return
    import fcntl

    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)


def unlock(fd: int) -> None:
    """Release a lock taken by lock_exclusive. Best-effort; closing also releases."""
    if IS_WINDOWS:
        import msvcrt

        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, LOCK_BYTES)
        return
    import fcntl

    fcntl.flock(fd, fcntl.LOCK_UN)


def open_flags(*extra: int) -> int:
    """OR together open() flags, adding O_BINARY where the platform has it."""
    flags = 0
    for value in extra:
        flags |= value
    return flags | getattr(os, "O_BINARY", 0)


# ------------------------------------------------------------- reviewer search

def safe_path_dirs(home: str) -> list[str]:
    """Reviewer search directories, derived from the passed-in passwd `home`.

    `home` is supplied by the caller from the passwd resolver. This function never
    reads os.environ -- not %USERPROFILE%, not $HOME, not $PATH, not $NVM_DIR. That
    is the D1 property: a poisoned environment cannot move the first entry of the
    search path to an attacker directory.
    """
    import glob

    if IS_WINDOWS:
        dirs = [
            os.path.join(home, "AppData", "Roaming", "npm"),
            os.path.join(home, "AppData", "Local", "Volta", "bin"),
            os.path.join(home, ".volta", "bin"),
            os.path.join(home, ".local", "bin"),
            r"C:\Program Files\nodejs",
            r"C:\Program Files (x86)\nodejs",
        ]
        for pattern in (
            os.path.join(home, "AppData", "Roaming", "nvm", "v*"),
            os.path.join(home, ".nvm", "versions", "node", "*"),
        ):
            dirs.extend(sorted(glob.glob(pattern), reverse=True))
        return [d for d in dirs if os.path.isdir(d)]

    dirs = [
        os.path.join(home, ".local", "bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/opt/local/bin",
    ]
    # Per-user Node tool dirs: codex (and other reviewers) ship via nvm/npm/volta,
    # which install under version-pinned dirs no fixed list can name. Globbed from
    # the PASSWD home ONLY (never $HOME / $NVM_DIR), so a poisoned env cannot
    # redirect resolution; every hit still faces all of _trusted_binary's checks
    # (uid-owned, not group/world-writable, uid-owned parent, outside workspace).
    for pattern in (
        os.path.join(home, ".nvm", "versions", "node", "*", "bin"),
        os.path.join(home, ".npm-global", "bin"),
        os.path.join(home, ".volta", "bin"),
    ):
        dirs.extend(sorted(glob.glob(pattern), reverse=True))
    return dirs


# --------------------------------------------------------------- process teardown

def kill_process_tree(proc, signal_module) -> None:
    """Terminate a timed-out child as forcefully as the platform allows.

    On Windows neither ``os.killpg`` nor ``signal.SIGKILL`` exists, so the engine's
    ``os.killpg(proc.pid, signal.SIGKILL)`` raised AttributeError -- which escapes
    ``except OSError`` and skips the designed ``proc.kill()`` fallback entirely.
    """
    if not hasattr(os, "killpg"):
        proc.kill()
        return
    try:
        os.killpg(proc.pid, signal_module.SIGTERM)
    except OSError:
        proc.kill()


def kill_process_tree_hard(proc, signal_module) -> None:
    """The SIGKILL rung of the same ladder."""
    if not hasattr(os, "killpg") or not hasattr(signal_module, "SIGKILL"):
        proc.kill()
        return
    try:
        os.killpg(proc.pid, signal_module.SIGKILL)
    except OSError:
        proc.kill()


# ------------------------------------------------------------------- diagnostics

def trust_mode() -> str:
    """Audit label for the permission regime in force. An ALLOW produced without
    POSIX ownership verification must be distinguishable after the fact."""
    return "posix" if posix_perms_meaningful() else "degraded-windows"


def warn_degraded_trust(stream=None) -> None:
    """Announce, once per process, which controls are not in force."""
    global _WARNED
    if posix_perms_meaningful() or _WARNED:
        return
    _WARNED = True
    print(
        "[sdp] windows: file ownership and POSIX mode checks are not enforced; "
        "reparse-point rejection is the substitute (KNOWN_GAPS NC-30)",
        file=stream or sys.stderr,
    )


_WARNED = False
