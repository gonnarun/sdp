#!/usr/bin/env bash
# win_compat.sh — the platform layer (scripts/win_compat.py) and the POSIX-parity
# contract of plan_windows-support.md §6.1.
#
#   W1  simulated Windows  — with pwd/fcntl blocked and the POSIX-only os attributes
#                            removed, all five entry points still import, and
#                            os.getuid is NOT defined afterwards (ADR-W02).
#   W2  POSIX parity       — the predicate is True here, and each COVERED guard site
#                            still produces its exact current outcome for a
#                            group-writable fixture AND accepts a clean one. Both
#                            halves matter: a predicate stuck at False would reject
#                            nothing and pass the rejection cases vacuously.
#   W3  resolvers          — no environment variable can move home/user, the
#                            _PASSWD_HOME seam still overrides, _safe_path is still
#                            os.pathsep-joined and rooted at the passwd home.
#   W4  reparse chain      — rejection at the base, at an intermediate ancestor, and
#                            at the target itself (ADR-W05 W05-b(1)).
#   W5  static bans        — no shipped script assigns os.getuid or resolves home
#                            from the environment.
#   W7-W13 (block WX)      — _state_lock timeout not masked by the unlock; end-to-end
#                            reparse rejection through the CALLERS, not the helper;
#                            codex prompt off argv; config discovery on the Windows
#                            surface; a fully derived child environment; the recorded
#                            check-then-use weakness; and batch dispatch via argv only.
#   W6  0777 parent        — the condition NTFS produces for EVERY directory. This
#                            is the case the uid-idiom enumeration missed once
#                            already (review_gate.py:295 has a mode test with no uid
#                            test beside it), so it is asserted behaviourally in both
#                            directions rather than by inspecting the source.
#
# Fixture location is load-bearing: _path_ancestry_trusted walks to the filesystem
# root and /tmp is 0o1777 on macOS and Linux, so fixtures live under a directory
# inside the passwd home. If that home's own ancestry is group/world-writable (an
# unusual runner), W2 SKIPs rather than reporting a failure it did not cause.
set -u
# shellcheck source=tests/lib/paths.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n' "$1"; }

# ---- W1: simulated Windows surface -----------------------------------------
if python3 - "$SDP_ROOT/scripts" <<'PY'
import builtins, importlib, os, sys, traceback

BLOCKED = {"pwd", "grp", "fcntl", "termios", "resource"}
# Present on POSIX, absent on Windows CPython. os.chmod/umask/symlink/readlink/
# link/getlogin are deliberately NOT removed -- Windows has them, and removing
# them produces failures Windows would never see.
MISSING = ("getuid", "geteuid", "getgid", "getegid", "setuid", "setgid", "fork",
           "forkpty", "setsid", "getpgid", "getpgrp", "setpgid", "killpg",
           "O_NOFOLLOW", "O_CLOEXEC", "getgroups", "initgroups")

sys.path.insert(0, sys.argv[1])
_real = builtins.__import__
def _fake(name, *a, **kw):
    if name.split(".")[0] in BLOCKED:
        raise ModuleNotFoundError("No module named %r" % name.split(".")[0])
    return _real(name, *a, **kw)
builtins.__import__ = _fake
for m in BLOCKED:
    sys.modules.pop(m, None)
for attr in MISSING:
    if hasattr(os, attr):
        delattr(os, attr)

# Warm every stdlib module the targets touch BEFORE os.name is flipped. Some of them
# freeze a platform decision in a class body at import time -- pathlib defines
# PosixPath.__new__ to refuse instantiation when os.name == "nt" -- so a stdlib module
# first imported inside the flipped window stays poisoned after the flip is undone.
# On a real Windows interpreter these are Windows builds and the problem cannot arise;
# it is purely an artifact of simulating the platform inside a POSIX process.
import argparse, contextlib, dataclasses, datetime, errno, functools, glob, hashlib  # noqa: E401
import json, pathlib, re, secrets, shutil, signal, stat, subprocess, tempfile, time  # noqa: E401

# The platform layer decides its branch from os.name, exactly as it will on a real
# Windows interpreter. Present "nt" for the duration of ITS import only: setting it
# process-wide would make the stdlib itself try to import the `nt` builtin, which a
# POSIX build does not have -- a failure real Windows never sees. Restoring it
# afterwards costs nothing, because IS_WINDOWS is captured at import time, which is
# the whole point of the seam.
_real_name = os.name
os.name = "nt"
try:
    import win_compat
finally:
    os.name = _real_name

if not win_compat.IS_WINDOWS:
    print("win_compat did not select the Windows branch", file=sys.stderr)
    raise SystemExit(1)

failures = []
for mod in ("config_discovery", "review_gate",
            "precompact_hook", "sdp_mcp_server", "claude_gate"):
    try:
        importlib.import_module(mod)
    except BaseException:
        failures.append("%s: %s" % (mod, traceback.format_exc().strip().splitlines()[-1]))
if failures:
    print("import failures: " + "; ".join(failures), file=sys.stderr)
    raise SystemExit(1)
# The whole point of ADR-W02: nothing may have put getuid back.
if hasattr(os, "getuid"):
    print("os.getuid was defined during import -- ADR-W02 violated", file=sys.stderr)
    raise SystemExit(1)
if win_compat.posix_perms_meaningful():
    print("posix_perms_meaningful() is True on the simulated surface", file=sys.stderr)
    raise SystemExit(1)
if win_compat.trust_mode() != "degraded-windows":
    print("trust_mode() = %r" % win_compat.trust_mode(), file=sys.stderr)
    raise SystemExit(1)
PY
then ok "W1: all entry points import with pwd/fcntl blocked; os.getuid stays undefined"
else bad "W1: simulated-Windows import surface failed"
fi

# ---- W2/W3/W4: parity, resolvers, reparse chain ------------------------------
python3 - "$SDP_ROOT/scripts" <<'PY'
import os, stat, sys, tempfile
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import win_compat
import review_gate as rg

PASS, FAIL, SKIP = [], [], []
def ok(m): PASS.append(m)
def bad(m): FAIL.append(m)
def skip(m): SKIP.append(m)

# --- W2 precondition: the predicate must be True here. A predicate stuck at
# False would make every rejection case pass by rejecting nothing.
if not win_compat.posix_perms_meaningful():
    bad("W2: posix_perms_meaningful() is False on a POSIX host")
else:
    ok("W2: posix_perms_meaningful() is True on this host")

home = Path(win_compat.passwd_home())

def ancestry_clean(p):
    cur = Path(p)
    while True:
        try:
            st = cur.stat()
        except OSError:
            return False
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            return False
        if st.st_uid not in (0, os.getuid()):
            return False
        if cur.parent == cur:
            return True
        cur = cur.parent

if not ancestry_clean(home):
    skip("W2: passwd home ancestry is group/world-writable on this runner")
    tmp = None
else:
    tmp = Path(tempfile.mkdtemp(prefix=".sdp-wintest-", dir=str(home)))
    os.chmod(tmp, 0o700)

def cleanup():
    if tmp is not None:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

try:
    if tmp is not None:
        root = Path(tempfile.mkdtemp(prefix="ws-", dir=str(tmp)))

        # -- site 1: _trusted_binary (needs an EXECUTABLE fixture: os.access(X_OK)
        #    runs before the mode guard, so 0o600 could never reach it)
        bindir = tmp / "bin"; bindir.mkdir(); os.chmod(bindir, 0o700)
        exe = bindir / "faker"; exe.write_text("#!/bin/sh\nexit 0\n"); os.chmod(exe, 0o700)
        rg._BINARY_RESOLVER = lambda name, _p=str(exe): _p if name == "faker" else None
        got, reason = rg._trusted_binary("faker", root)
        if got is not None and reason == "":
            ok("W2.1: _trusted_binary accepts a 0700 binary outside the workspace")
        else:
            bad("W2.1: clean binary rejected (%r)" % (reason,))
        os.chmod(exe, 0o720)
        got, reason = rg._trusted_binary("faker", root)
        if got is None and reason == "faker binary is group/world writable":
            ok("W2.1: _trusted_binary still rejects g+w with the unchanged message")
        else:
            bad("W2.1: g+w binary gave (%r, %r)" % (got, reason))
        os.chmod(exe, 0o700)
        rg._BINARY_RESOLVER = None

        # -- site 3: _path_ancestry_trusted
        chain = tmp / "a" / "b"; chain.mkdir(parents=True)
        os.chmod(tmp / "a", 0o700); os.chmod(chain, 0o700)
        if rg._path_ancestry_trusted(str(chain)):
            ok("W2.3: _path_ancestry_trusted accepts a 0700 chain")
        else:
            bad("W2.3: clean chain rejected")
        os.chmod(tmp / "a", 0o770)
        if not rg._path_ancestry_trusted(str(chain)):
            ok("W2.3: _path_ancestry_trusted still rejects a g+w ancestor")
        else:
            bad("W2.3: g+w ancestor accepted")
        os.chmod(tmp / "a", 0o700)

        # -- site 4: _toctou_safe_exec, and the POSIX hardlink path itself
        execpath, tmpdir, reason = rg._toctou_safe_exec(exe)
        if execpath is not None and reason == "" and execpath != str(exe):
            ok("W2.4: _toctou_safe_exec still hardlinks into a temp dir on POSIX")
        elif execpath == str(exe) and reason == "":
            ok("W2.4: _toctou_safe_exec fell back to exec-by-path (EXDEV)")
        else:
            bad("W2.4: clean binary gave (%r, %r)" % (execpath, reason))
        if tmpdir:
            rg._cleanup_exec(tmpdir)
        os.chmod(exe, 0o720)
        execpath, tmpdir, reason = rg._toctou_safe_exec(exe)
        if execpath is None and reason == "binary is group/world writable":
            ok("W2.4: _toctou_safe_exec still rejects g+w with the unchanged message")
        elif execpath == str(exe) and reason == "":
            skip("W2.4: cross-filesystem fallback, mode guard not reached")
        else:
            bad("W2.4: g+w binary gave (%r, %r)" % (execpath, reason))
        if tmpdir:
            rg._cleanup_exec(tmpdir)
        os.chmod(exe, 0o700)

        # -- sites 6/7: the two token readers, via the _PASSWD_HOME seam
        fake_home = tmp / "home"; (fake_home / ".sdp").mkdir(parents=True)
        os.chmod(fake_home, 0o700); os.chmod(fake_home / ".sdp", 0o700)
        rg._PASSWD_HOME = str(fake_home)
        try:
            tokfile = fake_home / ".sdp" / "override.token"
            tokfile.write_text("s3cret\n"); os.chmod(tokfile, 0o600)
            env_backup = dict(os.environ)
            os.environ["SDP_GATE_OVERRIDE"] = "s3cret"
            if rg._override_requested("attended"):
                ok("W2.6: _override_requested accepts a 0600 token")
            else:
                bad("W2.6: clean 0600 token rejected")
            os.chmod(tokfile, 0o620)
            if not rg._override_requested("attended"):
                ok("W2.6: _override_requested still rejects a g+w token")
            else:
                bad("W2.6: g+w token accepted")
            os.chmod(tokfile, 0o600)
            if not rg._override_requested("unattended"):
                ok("W2.6: override stays refused in unattended mode")
            else:
                bad("W2.6: override accepted in unattended mode")
            os.environ.clear(); os.environ.update(env_backup)

            mtok = fake_home / ".sdp" / "marker.token"
            mtok.write_text("m4rker\n"); os.chmod(mtok, 0o600)
            os.environ["SDP_MARKER_HUMAN"] = "m4rker"
            try:
                if rg._marker_token_ok():
                    ok("W2.7: _marker_token_ok accepts a 0600 token")
                else:
                    bad("W2.7: clean 0600 marker token rejected")
                os.chmod(mtok, 0o620)
                if not rg._marker_token_ok():
                    ok("W2.7: _marker_token_ok still rejects a g+w token")
                else:
                    bad("W2.7: g+w marker token accepted")
            finally:
                os.environ.pop("SDP_MARKER_HUMAN", None)

            # -- W3: the seam still overrides, and _safe_path is derived from it
            if rg._passwd_home() == str(fake_home):
                ok("W3: the _PASSWD_HOME seam still overrides the resolver")
            else:
                bad("W3: _PASSWD_HOME seam no longer overrides")
            sp = rg._safe_path()
            if sp.split(os.pathsep)[0] == os.path.join(str(fake_home), ".local", "bin"):
                ok("W3: _safe_path is os.pathsep-joined and rooted at the passwd home")
            else:
                bad("W3: _safe_path[0] = %r" % sp.split(os.pathsep)[0])
            if os.pathsep == ":" and ":" in sp or os.pathsep != ":":
                ok("W3: _safe_path separator matches os.pathsep on this platform")
            else:
                bad("W3: separator mismatch")
        finally:
            rg._PASSWD_HOME = None

        # -- W3: no environment variable can move home or user
        env_backup = dict(os.environ)
        os.environ["HOME"] = "/tmp/evil-home"
        os.environ["USERPROFILE"] = r"C:\evil"
        os.environ["USERNAME"] = "evil"
        os.environ["USER"] = "evil"
        try:
            if win_compat.passwd_home() == str(home):
                ok("W3: passwd_home() ignores HOME/USERPROFILE")
            else:
                bad("W3: passwd_home() moved with the environment")
            if win_compat.passwd_name() != "evil":
                ok("W3: passwd_name() ignores USER/USERNAME")
            else:
                bad("W3: passwd_name() came from the environment")
        finally:
            os.environ.clear(); os.environ.update(env_backup)

        # -- W4: reparse/symlink chain rejection at all three levels
        base = tmp / "chain"; (base / "mid").mkdir(parents=True)
        target = base / "mid" / "tok"; target.write_text("x")
        try:
            win_compat.reject_reparse_chain(base, target)
            ok("W4: an ordinary chain is accepted")
        except OSError as exc:
            bad("W4: ordinary chain rejected (%s)" % exc)

        link_mid = base / "linkmid"
        os.symlink(base / "mid", link_mid)
        try:
            win_compat.reject_reparse_chain(base, link_mid / "tok")
            bad("W4: an intermediate symlinked ancestor was accepted")
        except OSError:
            ok("W4: rejects a symlinked intermediate ancestor")

        link_tgt = base / "mid" / "toklink"
        os.symlink(target, link_tgt)
        try:
            win_compat.reject_reparse_chain(base, link_tgt)
            bad("W4: a symlinked target was accepted")
        except OSError:
            ok("W4: rejects a symlinked target")

        link_base = tmp / "linkbase"
        os.symlink(base, link_base)
        try:
            win_compat.reject_reparse_chain(link_base, link_base / "mid" / "tok")
            bad("W4: a symlinked base was accepted")
        except OSError:
            ok("W4: rejects a symlinked base")
finally:
    cleanup()

for m in PASS: print("ok   - %s" % m)
for m in SKIP: print("SKIP - %s" % m)
for m in FAIL: print("FAIL - %s" % m)
print("__COUNTS__ %d %d %d" % (len(PASS), len(FAIL), len(SKIP)))
raise SystemExit(1 if FAIL else 0)
PY
rc=$?
if [ "$rc" -eq 0 ]; then ok "W2/W3/W4: POSIX parity, resolvers and reparse-chain rejection"
else bad "W2/W3/W4: see the FAIL lines above"; fi


# ---- W7..W13 -----------------------------------------------------------------
if python3 - "$SDP_ROOT/scripts" <<'WXPY'
import builtins, os, sys, tempfile, time
from pathlib import Path

BLOCKED = {"pwd", "grp", "fcntl", "termios", "resource"}
MISSING = ("getuid", "geteuid", "getgid", "getegid", "setuid", "setgid", "fork",
           "forkpty", "setsid", "getpgid", "getpgrp", "setpgid", "killpg",
           "O_NOFOLLOW", "O_CLOEXEC", "getgroups", "initgroups")

sys.path.insert(0, sys.argv[1])
import argparse, contextlib, dataclasses, datetime, errno, functools, glob, hashlib  # noqa: E401,F401
import json, pathlib, re, secrets, shutil, signal, stat, subprocess, tempfile as _t, time as _time  # noqa: E401,F401

import win_compat as _real_wc
home = Path(_real_wc.passwd_home())
tmp = Path(tempfile.mkdtemp(prefix=".sdp-wx-", dir=str(home))); os.chmod(tmp, 0o700)

FAIL = []
def check(cond, msg):
    print(("ok   - %s" if cond else "FAIL - %s") % msg)
    if not cond:
        FAIL.append(msg)

try:
    # ---------- W7: POSIX contention, then the Windows-critical property -------
    import review_gate as rgp
    lockp = tmp / "l1.lock"
    with rgp._state_lock(lockp, _time.monotonic() + 5):
        try:
            with rgp._state_lock(lockp, _time.monotonic() - 1):
                check(False, "W7: a held lock was acquired twice")
        except rgp.InfraError as exc:
            check("state lock wait timed out" in str(exc),
                  "W7: POSIX contention raises InfraError('state lock wait timed out')")
        except BaseException as exc:
            check(False, "W7: contention raised %s: %s" % (type(exc).__name__, exc))
    with rgp._state_lock(lockp, _time.monotonic() + 5):
        pass
    check(True, "W7: the lock is released after the timeout path")

    # ---------- W2.2: _gate_env_conf, the guard site never covered before -------
    envhome = tmp / "envhome"; (envhome / ".sdp").mkdir(parents=True)
    os.chmod(envhome, 0o700); os.chmod(envhome / ".sdp", 0o700)
    conf = envhome / ".sdp" / "gate-env.conf"
    conf.write_text("CODEX_HOME=/tmp/x\n"); os.chmod(conf, 0o600)
    _hb = rgp._PASSWD_HOME
    rgp._PASSWD_HOME = str(envhome)
    try:
        got = rgp._gate_env_conf()
        check(isinstance(got, dict) and got.get("CODEX_HOME") == "/tmp/x",
              "W2.2: _gate_env_conf reads a 0600 conf owned by the user")
        os.chmod(conf, 0o620)
        _gw = rgp._gate_env_conf()
        check(_gw == {},
              "W2.2: _gate_env_conf still returns the empty result for a g+w conf (got %r, mode %s)"
              % (_gw, oct(os.stat(conf).st_mode & 0o777)))
        os.chmod(conf, 0o600)
    finally:
        rgp._PASSWD_HOME = _hb

    # ---------- switch to the simulated Windows surface -------------------------
    for m in ("win_compat", "review_gate", "config_discovery", "precompact_hook"):
        sys.modules.pop(m, None)
    _r = builtins.__import__
    def _f(n, *a, **k):
        if n.split(".")[0] in BLOCKED:
            raise ModuleNotFoundError("No module named %r" % n.split(".")[0])
        return _r(n, *a, **k)
    builtins.__import__ = _f
    for m in BLOCKED:
        sys.modules.pop(m, None)
    for a in MISSING:
        if hasattr(os, a):
            delattr(os, a)
    _n = os.name; os.name = "nt"
    try:
        import win_compat
    finally:
        os.name = _n
    import review_gate as rg
    import config_discovery as cd
    rg._PASSWD_HOME = str(home)

    # ---------- W7b: the property that only exists on Windows -------------------
    # POSIX flock(LOCK_UN) on an unlocked fd is a harmless no-op, so the POSIX case
    # above cannot show the defect. On Windows msvcrt LK_UNLCK on an unlocked region
    # RAISES, and raising from the `finally` would replace the timeout. Force that
    # shape directly: acquisition always fails, and unlock must never be called.
    calls = {"unlock": 0}
    real_lock, real_unlock = win_compat.lock_exclusive, win_compat.unlock
    win_compat.lock_exclusive = lambda fd: (_ for _ in ()).throw(OSError("held"))
    def _counting_unlock(fd):
        calls["unlock"] += 1
        raise OSError("LK_UNLCK on an unlocked region")
    win_compat.unlock = _counting_unlock
    try:
        try:
            with rg._state_lock(tmp / "l2.lock", _time.monotonic() - 1):
                check(False, "W7b: acquisition should have failed")
        except rg.InfraError as exc:
            check("state lock wait timed out" in str(exc),
                  "W7b: the timeout survives -- unlock does not replace it")
        except BaseException as exc:
            check(False, "W7b: timeout was masked by %s: %s" % (type(exc).__name__, exc))
        check(calls["unlock"] == 0,
              "W7b: unlock is never called for a lock that was never acquired")
    finally:
        win_compat.lock_exclusive, win_compat.unlock = real_lock, real_unlock

    # ---------- W11 seam: no Win32 on this host, so pin the derived source ------
    # system_windows_dir() calls ctypes.WinDLL, which does not exist on POSIX. The
    # point under test is the DERIVATION rule, not Microsoft's API, so the function
    # is replaced here. That the real one calls GetSystemWindowsDirectoryW is
    # unexecuted -- native case A4/A9 in ADR-W10.
    win_compat.system_windows_dir = lambda: r"C:\Windows"
    # Same reason for the user name: _win_user_name() calls advapi32 through ctypes.
    win_compat._win_user_name = lambda: "winuser"
    win_compat._win_profile_dir = lambda: str(home)   # SHGetKnownFolderPath, same reason

    # ---------- W8: reparse rejection through the CALLERS ----------------------
    realbin = tmp / "real" / "bin"; realbin.mkdir(parents=True)
    exe = realbin / "faker"; exe.write_text("#!/bin/sh\nexit 0\n"); os.chmod(exe, 0o700)
    linkbin = tmp / "linkbin"; os.symlink(realbin, linkbin)
    rg._BINARY_RESOLVER = lambda n, _p=str(linkbin / "faker"): _p if n == "faker" else None
    got, reason = rg._trusted_binary("faker", tmp / "ws")
    check(got is None and "not trusted" in reason,
          "W8: _trusted_binary refuses a reviewer reached through a symlinked bin dir")
    rg._BINARY_RESOLVER = lambda n, _p=str(exe): _p if n == "faker" else None
    got, reason = rg._trusted_binary("faker", tmp / "ws")
    check(got is not None, "W8: _trusted_binary still accepts the same binary by its real path")
    rg._BINARY_RESOLVER = None

    realbase = tmp / "realbase"; realbase.mkdir(); os.chmod(realbase, 0o700)
    linkbase = tmp / "linkbase"; os.symlink(realbase, linkbase)
    os.environ["SDP_BASE_DIR"] = str(linkbase)
    try:
        rg._audit_base(tmp / "ws")
        check(False, "W8: _audit_base accepted a symlinked SDP_BASE_DIR")
    except rg.InfraError as exc:
        check("not trusted" in str(exc), "W8: _audit_base refuses a symlinked SDP_BASE_DIR")
    os.environ["SDP_BASE_DIR"] = str(realbase)
    try:
        rg._audit_base(tmp / "ws")
        check(True, "W8: _audit_base still accepts the same directory by its real path")
    except BaseException as exc:
        check(False, "W8: real base rejected: %s" % exc)
    os.environ.pop("SDP_BASE_DIR", None)

    # ---------- W10: config discovery on the Windows surface -------------------
    proj = tmp / "proj"; (proj / ".sdp").mkdir(parents=True)
    body = b"base_dir: .private/x\r\noutput_locale: en\r\n\x1aTRAILING\r\n"
    (proj / ".sdp" / "defaults.yaml").write_bytes(body)
    src_cd = pathlib.Path(sys.argv[1], "config_discovery.py").read_text()
    sel = cd._read_relative(proj, (".sdp", "defaults.yaml"), 100000)
    check(sel is not None, "W10: config discovery runs on the Windows surface (no dir_fd)")
    if sel is not None:
        import hashlib as _h
        check(sel.sha256 == _h.sha256(body).hexdigest(),
              "W10: sha256 matches the exact bytes on this host")
        check("TRAILING" in sel.text, "W10: text past a 0x1A byte is not truncated")
    # The CRLF/0x1A fixture above cannot fail on POSIX, where O_BINARY is 0 and no
    # translation happens -- it would not catch a removed guard. What IS assertable
    # here is that the flag is actually requested and actually reaches the reader.
    _sentinel = 0x8000
    _had = getattr(os, "O_BINARY", None)
    os.O_BINARY = _sentinel
    try:
        check(win_compat.open_flags(os.O_RDONLY) & _sentinel == _sentinel,
              "W10: open_flags() ORs in O_BINARY wherever the platform defines it")
    finally:
        if _had is None:
            del os.O_BINARY
        else:
            os.O_BINARY = _had
    check("win_compat.open_flags(" in src_cd and "file_flags = os.O_RDONLY" not in src_cd,
          "W10: the config reader builds its flags through open_flags, not raw ORs")
    # NOT VERIFIED HERE: that MSVCRT text mode would in fact have corrupted the
    # digest. That needs a native Windows run (ADR-W10 A1/A3).
    # NOT "os.supports_dir_fd is empty" -- this host is POSIX and the simulation does
    # not model that set. What IS assertable, and is the actual reason the original
    # code could not survive Windows: NotImplementedError is not an OSError, so the
    # `except OSError` around the openat walk could never have caught it.
    check(not issubclass(NotImplementedError, OSError),
          "W10: NotImplementedError is not an OSError, so the openat walk's handler could not catch it")
    check("dir_fd=" not in src_cd.split("if win_compat.IS_WINDOWS:")[1].split("try:\n        current = os.open")[0],
          "W10: the Windows branch uses no dir_fd")

    # config discovery must refuse a symlinked base AND a symlinked intermediate
    linkproj = tmp / "linkproj"; os.symlink(proj, linkproj)
    try:
        cd._read_relative(linkproj, (".sdp", "defaults.yaml"), 100000)
        check(False, "W10: a symlinked config base was accepted")
    except cd.ConfigDiscoveryError:
        check(True, "W10: _read_relative refuses a symlinked config base")
    proj2 = tmp / "proj2"; (proj2 / "realsdp").mkdir(parents=True)
    (proj2 / "realsdp" / "defaults.yaml").write_bytes(b"x: 1\n")
    os.symlink(proj2 / "realsdp", proj2 / ".sdp")
    try:
        cd._read_relative(proj2, (".sdp", "defaults.yaml"), 100000)
        check(False, "W10: a symlinked intermediate component was accepted")
    except cd.ConfigDiscoveryError:
        check(True, "W10: _read_relative refuses a symlinked intermediate component")

    # ---------- W11: the child environment is fully derived ---------------------
    hostile = {"SystemRoot": r"C:\evil", "windir": r"C:\evil", "ComSpec": r"C:\evil\cmd.exe",
               "USERPROFILE": r"C:\evil", "PATHEXT": ".EVIL", "USERNAME": "evil",
               "NODE_OPTIONS": "--require=/tmp/evil.js"}
    backup = dict(os.environ); os.environ.update(hostile)
    try:
        env = rg._base_env()
    finally:
        os.environ.clear(); os.environ.update(backup)
    check(all(env.get(k) != v for k, v in hostile.items()),
          "W11: no ambient Windows value survives into the child environment")
    check(env.get("USERPROFILE") == str(home), "W11: USERPROFILE is derived from the passwd home")
    check("NODE_OPTIONS" not in env, "W11: no loader variable is passed through")
    check(env.get("PATHEXT") == ".COM;.EXE;.BAT;.CMD", "W11: PATHEXT is the fixed list, not inherited")
    check(env.get("SystemRoot") == r"C:\Windows" and env.get("windir") == r"C:\Windows",
          "W11: SystemRoot/windir come from the derived system directory, not the environment")
    check(env.get("SystemDrive") == "C:", "W11: SystemDrive is derived from that directory")
    check("ComSpec" not in env,
          "W11: ComSpec is omitted when the derived cmd.exe does not exist (fail-closed, not guessed)")

    # ---------- W12: the recorded check-then-use weakness -----------------------
    swapdir = tmp / "swap"; (swapdir / "real").mkdir(parents=True)
    (swapdir / "real" / "f.yaml").write_bytes(b"ok: 1\n")
    (swapdir / "d").mkdir(); (swapdir / "d" / "f.yaml").write_bytes(b"ok: 1\n")
    validated = win_compat.walk_checked(swapdir, ("d", "f.yaml"))
    os.rename(swapdir / "d", swapdir / "gone"); os.symlink(swapdir / "real", swapdir / "d")
    still_reads = os.path.exists(validated)
    check(still_reads,
          "W12: RECORDED WEAKNESS -- a component swapped after validation is not detected "
          "(check-then-use; POSIX openat has no such window; KNOWN_GAPS NC-30)")

    # ---------- W13: batch dispatch goes by argv, not lpApplicationName ---------
    seen = {}
    class _P:
        def __init__(self, argv, **kw):
            seen.clear(); seen["argv"] = argv; seen.update(kw)
            raise OSError("spawn intercepted")
    real_popen = subprocess.Popen
    subprocess.Popen = _P
    try:
        cmdpath = tmp / "bin.cmd"; cmdpath.write_text("@echo off\n")
        rg._run_argv([str(cmdpath), "x"], cwd=tmp, timeout_s=5, max_output=1000)
        check("executable" in seen and seen["executable"] is None,
              "W13: a .cmd target is spawned with executable=None (lpApplicationName NULL)")
        check(seen.get("argv", [None])[0] == str(cmdpath),
              "W13: argv[0] is still the resolved, chain-checked path")
        exepath = tmp / "bin.exe"; exepath.write_text("x")
        rg._run_argv([str(exepath)], cwd=tmp, timeout_s=5, max_output=1000)
        check(seen.get("executable") == str(exepath),
              "W13: a non-batch target still passes executable=")
        check(seen.get("stdin") is subprocess.DEVNULL,
              "W13: with no stdin_text the stdin wiring is unchanged")
        rg._run_argv([str(exepath)], cwd=tmp, timeout_s=5, max_output=1000, stdin_text="hi")
        check(seen.get("stdin") is subprocess.PIPE,
              "W9: stdin_text switches the child to a pipe")
    finally:
        subprocess.Popen = real_popen

    # ---------- W9: real adapter contracts, not source substrings ---------------
    # Substring counting can pass on a comment or a stale line. Drive each adapter
    # with _trusted_binary and _run_argv replaced, and assert the argv and stdin it
    # actually builds.
    captured = {}
    def _fake_run(argv, *, cwd, timeout_s, max_output, extract=None, stdin_text=None):
        captured["argv"] = list(argv)
        captured["stdin"] = stdin_text
        return rg.ProviderResult("allow", "ALLOW: x", "ALLOW: x", "", "")
    real_tb, real_ra = rg._trusted_binary, rg._run_argv
    rg._trusted_binary = lambda name, root: (Path("/usr/bin/%s" % name), "")
    rg._run_argv = _fake_run
    PROMPT = 'PROMPT-SENTINEL \uac00\ub098 spaces "quotes" & metachars'
    try:
        for adapter, tail in ((rg._codex_result, "-"),
                              (rg._claude_result, "-p"),
                              (rg._agy_result, "-p")):
            captured.clear()
            adapter(tmp, PROMPT, "", 5)
            nm = adapter.__name__
            check(all(PROMPT not in a for a in captured["argv"]),
                  "W9: %s puts no prompt text in argv" % nm)
            check(captured["stdin"] == PROMPT,
                  "W9: %s hands the exact prompt to stdin_text" % nm)
            check(captured["argv"][-1] == tail,
                  "W9: %s argv ends with %r" % (nm, tail))
    finally:
        rg._trusted_binary, rg._run_argv = real_tb, real_ra

    # ---------- W14: Windows teardown attempts the descendants ------------------
    argv = win_compat._taskkill_argv(4321)
    check(argv is None or (argv[0].endswith("taskkill.exe")
                           and argv[1:] == ["/PID", "4321", "/T", "/F"]),
          "W14: the taskkill argv is fixed, numeric, and derived (None where absent here)")
    killed = {"n": 0}
    class _Proc:
        pid = 4321
        def kill(self):
            killed["n"] += 1
    win_compat._windows_tree_kill(_Proc())
    check(killed["n"] == 1,
          "W14: the direct child is killed regardless of whether the tree kill ran")
    # NOT VERIFIED HERE: that taskkill actually reaps a Node descendant. Native only
    # (ADR-W10 A15).
finally:
    import shutil as _s
    _s.rmtree(tmp, ignore_errors=True)

raise SystemExit(1 if FAIL else 0)
WXPY
then ok "W7-W13: lock, caller-level reparse, config discovery, derived env, dispatch"
else bad "W7-W13: see the FAIL lines above"
fi

# ---- W6: a 0777 parent directory, in both directions -------------------------
if python3 - "$SDP_ROOT/scripts" <<'W6PY'
import builtins, os, sys, tempfile
from pathlib import Path

BLOCKED = {"pwd", "grp", "fcntl", "termios", "resource"}
MISSING = ("getuid", "geteuid", "getgid", "getegid", "setuid", "setgid", "fork",
           "forkpty", "setsid", "getpgid", "getpgrp", "setpgid", "killpg",
           "O_NOFOLLOW", "O_CLOEXEC", "getgroups", "initgroups")

sys.path.insert(0, sys.argv[1])
import argparse, contextlib, dataclasses, datetime, errno, functools, glob, hashlib  # noqa: E401,F401
import json, pathlib, re, secrets, shutil, signal, stat, subprocess, time  # noqa: E401,F401

# Build the fixture on the REAL surface first: a binary whose parent is 0777,
# which is what NTFS reports for every directory.
import win_compat as _wc
home = Path(_wc.passwd_home())
tmp = Path(tempfile.mkdtemp(prefix=".sdp-w6-", dir=str(home)))
try:
    os.chmod(tmp, 0o700)
    bindir = tmp / "bin"; bindir.mkdir()
    exe = bindir / "faker"; exe.write_text("#!/bin/sh\nexit 0\n"); os.chmod(exe, 0o700)
    root = tmp / "ws"; root.mkdir()

    # (a) POSIX direction: a world-writable parent must STILL be refused, with the
    # message unchanged. Nothing asserted this before; it is why the regression was
    # invisible.
    import review_gate as rg
    rg._BINARY_RESOLVER = lambda name, _p=str(exe): _p if name == "faker" else None
    os.chmod(bindir, 0o777)
    got, reason = rg._trusted_binary("faker", root)
    if not (got is None and reason == "faker parent directory is world writable"):
        print("POSIX: 0777 parent was not refused: (%r, %r)" % (got, reason), file=sys.stderr)
        raise SystemExit(1)

    # (b) Windows direction: the SAME 0777 parent must be accepted, because every
    # NTFS directory looks like this and refusing it blocks the gate permanently.
    # Re-import the whole engine against the simulated surface in a child-like state.
    for mod in ("review_gate", "config_discovery", "precompact_hook", "win_compat",
                "sdp_mcp_server", "claude_gate"):
        sys.modules.pop(mod, None)
    _real = builtins.__import__
    def _fake(n, *a, **k):
        if n.split(".")[0] in BLOCKED:
            raise ModuleNotFoundError("No module named %r" % n.split(".")[0])
        return _real(n, *a, **k)
    builtins.__import__ = _fake
    for m in BLOCKED:
        sys.modules.pop(m, None)
    for attr in MISSING:
        if hasattr(os, attr):
            delattr(os, attr)
    _real_name = os.name
    os.name = "nt"
    try:
        import win_compat  # noqa: F811
    finally:
        os.name = _real_name
    import review_gate as rgw
    rgw._PASSWD_HOME = str(home)
    rgw._BINARY_RESOLVER = lambda name, _p=str(exe): _p if name == "faker" else None
    got, reason = rgw._trusted_binary("faker", root)
    if got is None:
        print("WINDOWS: a 0777 parent was refused (%r) -- every NTFS directory looks "
              "like this, so the gate would be permanently blocked" % (reason,), file=sys.stderr)
        raise SystemExit(1)
finally:
    import shutil as _sh
    _sh.rmtree(tmp, ignore_errors=True)
W6PY
then ok "W6: a 0777 parent is refused on POSIX and accepted on the Windows surface"
else bad "W6: 0777-parent handling is wrong in one of the two directions"
fi


# ---- W15..W17: the CALLER paths, on the real surface --------------------------
# These guards are platform-unconditional now, so they are exercised directly with
# POSIX symlinks. Every bug in this group reached a commit because only the helper
# was tested and the public entry point resolved its base first.
if python3 - "$SDP_ROOT/scripts" <<'CALLPY'
import os, sys, tempfile
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import win_compat, config_discovery as cd, review_gate as rg, precompact_hook as ph

FAIL = []
def check(c, m):
    print(("ok   - %s" if c else "FAIL - %s") % m)
    if not c:
        FAIL.append(m)

home = Path(win_compat.passwd_home())
tmp = Path(tempfile.mkdtemp(prefix=".sdp-caller-", dir=str(home))); os.chmod(tmp, 0o700)
try:
    # W15: discover() and read_workspace_file() must not launder a link by resolving
    # the base before the reader sees it.
    real = tmp / "realcfg" / "sdp"; real.mkdir(parents=True)
    (real / "gates.yaml").write_text("mode: unattended\n")
    xdg_link = tmp / "xdglink"; os.symlink(tmp / "realcfg", xdg_link)
    env = {"XDG_CONFIG_HOME": str(xdg_link)}
    proj = tmp / "proj"; (proj / ".sdp").mkdir(parents=True)
    try:
        got = cd.discover(proj, "gates.yaml", home_resolver=lambda: tmp, environ=env)
        check(got is None, "W15: discover() does not read through a symlinked XDG_CONFIG_HOME")
    except cd.ConfigDiscoveryError:
        check(True, "W15: discover() fails closed on a symlinked XDG_CONFIG_HOME")
    # An INTERMEDIATE symlinked ancestor, with a perfectly ordinary leaf: the case a
    # base-only check passes.
    mid_real = tmp / "midreal"; (mid_real / "cfg" / "sdp").mkdir(parents=True)
    (mid_real / "cfg" / "sdp" / "gates.yaml").write_text("mode: unattended\n")
    mid_link = tmp / "midlink"; os.symlink(mid_real, mid_link)
    env_mid = {"XDG_CONFIG_HOME": str(mid_link / "cfg")}
    try:
        got = cd.discover(proj, "gates.yaml", home_resolver=lambda: tmp, environ=env_mid)
        check(got is None, "W15: a symlinked INTERMEDIATE ancestor of the base is not read through")
    except cd.ConfigDiscoveryError:
        check(True, "W15: fails closed on a symlinked intermediate ancestor of the base")

    env_ok = {"XDG_CONFIG_HOME": str(tmp / "realcfg")}
    got = cd.discover(proj, "gates.yaml", home_resolver=lambda: tmp, environ=env_ok)
    check(got is not None, "W15: discover() still reads the same file by its real path")

    wsreal = tmp / "wsreal"; wsreal.mkdir(); (wsreal / "r.md").write_text("x\n")
    wslink = tmp / "wslink"; os.symlink(wsreal, wslink)
    try:
        cd.read_workspace_file(wslink, "r.md", 10000)
        check(False, "W15: read_workspace_file read through a symlinked root")
    except cd.ConfigDiscoveryError:
        check(True, "W15: read_workspace_file fails closed on a symlinked root")

    # W16: precompact state paths, including the state dir's OWN last component.
    fakehome = tmp / "ph"; (fakehome / ".sdp").mkdir(parents=True)
    realstate = tmp / "realstate"; realstate.mkdir()
    os.symlink(realstate, fakehome / ".sdp" / "precompact-state")   # STATE_DIRNAME
    _wc_home = win_compat.passwd_home
    win_compat.passwd_home = lambda: str(fakehome)
    ph.passwd_home.cache_clear()
    try:
        try:
            ph.state_dir()
            check(False, "W16: state_dir() returned a symlinked precompact directory")
        except OSError:
            check(True, "W16: state_dir() refuses a symlinked state directory (its own leaf)")
        ph._prune_windows()
        check(os.path.isdir(realstate), "W16: prune deletes nothing through the symlink")
    finally:
        win_compat.passwd_home = _wc_home
        ph.passwd_home.cache_clear()

    # W17: _audit_base default and relative branches, which had no check at all.
    wsroot = tmp / "ws"; wsroot.mkdir()
    outside = tmp / "outside"; outside.mkdir()
    os.symlink(outside, wsroot / ".private")
    os.environ.pop("SDP_BASE_DIR", None)
    try:
        rg._audit_base(wsroot)
        check(False, "W17: the default audit base was accepted through a symlinked .private")
    except rg.InfraError:
        check(True, "W17: the default audit base refuses a symlinked .private")
    os.environ["SDP_BASE_DIR"] = ".private/sdp-artifacts"
    try:
        rg._audit_base(wsroot)
        check(False, "W17: a relative SDP_BASE_DIR was accepted through the same symlink")
    except rg.InfraError:
        check(True, "W17: a relative SDP_BASE_DIR refuses the symlinked component")
    finally:
        os.environ.pop("SDP_BASE_DIR", None)
    clean = tmp / "ws2"; (clean / ".private" / "sdp-artifacts").mkdir(parents=True)
    try:
        rg._audit_base(clean)
        check(True, "W17: an ordinary .private is still accepted")
    except BaseException as exc:
        check(False, "W17: ordinary .private rejected: %s" % exc)

    # W17b: the gate/ leaf under the audit base, which _audit_base does not cover.
    gbase = tmp / "ws3"; (gbase / ".private" / "sdp-artifacts").mkdir(parents=True)
    elsewhere = tmp / "gate-elsewhere"; elsewhere.mkdir()
    os.symlink(elsewhere, gbase / ".private" / "sdp-artifacts" / "gate")
    try:
        rg._state_paths(gbase, "k")
        check(False, "W17b: _state_paths accepted a symlinked gate/ directory")
    except rg.InfraError:
        check(True, "W17b: _state_paths refuses a symlinked gate/ directory")
    except TypeError:
        check(False, "W17b: _state_paths signature mismatch -- test needs updating")
finally:
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
raise SystemExit(1 if FAIL else 0)
CALLPY
then ok "W15-W17: public config discovery, precompact state paths, audit base"
else bad "W15-W17: see the FAIL lines above"
fi


# ---- W18: hook manifests and the launcher contract ---------------------------
if python3 - "$SDP_ROOT" <<'HOOKPY'
import base64, json, os, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts"))
import win_compat as _wc
win_home = _wc.passwd_home()
FAIL = []
def check(c, m):
    print(("ok   - %s" if c else "FAIL - %s") % m)
    if not c:
        FAIL.append(m)

for tree in (root / "hooks", root / "plugins" / "sdp" / "hooks"):
    claude = json.loads((tree / "hooks.json").read_text(encoding="utf-8"))
    codex = json.loads((tree / "hooks.codex.json").read_text(encoding="utf-8"))
    label = tree.parent.name

    # Claude: shell form with shell=bash (exec form would spawn `bash` from PATH,
    # which a Windows host need not have), and no python3 assumption.
    entries = [h for ev in claude["hooks"].values() for grp in ev for h in grp["hooks"]]
    check(len(entries) == 3, "W18[%s]: Claude manifest still declares three hooks" % label)
    check(all(e.get("shell") == "bash" for e in entries),
          "W18[%s]: every Claude hook sets shell=bash so the host picks Git Bash" % label)
    check(all("args" not in e for e in entries),
          "W18[%s]: no Claude hook uses exec form, which would spawn bash from PATH" % label)
    check(not any("python3" in json.dumps(e) for e in entries),
          "W18[%s]: no Claude hook assumes a python3 executable" % label)
    check(all(e["command"].startswith('"${CLAUDE_PLUGIN_ROOT}/scripts/precompact_launcher.sh" ')
              for e in entries),
          "W18[%s]: every Claude command invokes the quoted plugin-root launcher" % label)
    check(sorted(e["command"].rsplit(" ", 1)[-1] for e in entries)
          == ["precompact", "start", "stop"],
          "W18[%s]: the three verbs are stop/precompact/start" % label)

    # Codex: commandWindows must survive cmd.exe /C outer quoting -> no quotes at all.
    centries = [h for ev in codex["hooks"].values() for grp in ev for h in grp["hooks"]]
    # Codex validates the TOP LEVEL strictly: "unknown field `_comment`, expected
    # `description` or `hooks`". A rejected manifest makes codex emit an error item,
    # which the gate's fail-closed tool-purity check reads as contamination and turns
    # into INFRA_ERROR -- so a stray key costs a working gate. Reported from a real
    # Windows install on 2026-08-28; the earlier version of this test checked the
    # hook entries and never looked at the keys around them.
    check(set(codex) <= {"description", "hooks"},
          "W18[%s]: the Codex manifest's top level uses only keys codex accepts (has %s)"
          % (label, sorted(codex)))
    check(len(centries) == 3, "W18[%s]: Codex manifest declares three hooks" % label)
    check(all("commandWindows" in e for e in centries),
          "W18[%s]: every Codex hook carries a commandWindows" % label)
    check(all('"' not in e["commandWindows"] for e in centries),
          "W18[%s]: no commandWindows contains a double quote (codex#38168)" % label)
    check(all(e["commandWindows"].startswith(
              r"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe ")
              for e in centries),
          "W18[%s]: commandWindows uses the absolute powershell path, not a bare name" % label)
    check(all("-NoProfile" in e["commandWindows"] and "-NonInteractive" in e["commandWindows"]
              for e in centries),
          "W18[%s]: commandWindows runs powershell without a profile" % label)

    # The encoded payload must still decode to the reviewable source.
    raw_src = (tree / "precompact_windows.ps1").read_text(encoding="utf-8")
    # The encoded payload is the source with comment and blank lines removed --
    # base64 over UTF-16LE inflates ~2.67x and the command line has an 8191 ceiling.
    src = "\n".join(l for l in raw_src.splitlines()
                    if l.strip() and not l.lstrip().startswith("#"))
    for e in centries:
        b64 = e["commandWindows"].rsplit(" ", 1)[-1]
        decoded = base64.b64decode(b64).decode("utf-16-le")
        verb = e["command"].rsplit(" ", 1)[-1]
        check(decoded == src.replace("__SDP_VERB__", verb),
              "W18[%s]: the %s payload decodes to precompact_windows.ps1 verbatim" % (label, verb))
        check("__SDP_VERB__" not in decoded,
              "W18[%s]: the %s payload has no unsubstituted placeholder" % (label, verb))
        check(len(e["commandWindows"]) < 8000,
              "W18[%s]: the %s command line stays under the 8191-char cmd.exe limit (%d)"
              % (label, verb, len(e["commandWindows"])))
        check("$OutputEncoding" in decoded,
              "W18[%s]: the %s payload sets $OutputEncoding for the native pipe" % (label, verb))
        check("exit 127" in decoded and "exit 0" not in decoded,
              "W18[%s]: the %s payload fails loudly, never silently succeeds" % (label, verb))
        check("version_info >= (3, 9)" in decoded,
              "W18[%s]: the %s payload probes the interpreter version" % (label, verb))

# The Codex plugin manifest must actually point at its own hooks file, or none of
# the above is loaded.
manifest = json.loads((root / "plugins" / "sdp" / ".codex-plugin" / "plugin.json").read_text())
check(manifest.get("hooks") == "./hooks/hooks.codex.json",
      "W18: the Codex plugin manifest declares hooks.codex.json")

# Launcher: real behaviour, not just presence.
launcher = root / "scripts" / "precompact_launcher.sh"
check(os.access(launcher, os.X_OK), "W18: the launcher is executable")
# Isolated: doctor reads config and WRITES a probe under the state dir, so running it
# with the ambient environment would touch the developer's real ~/.sdp and would flake
# on a machine whose mode is not auto. The selftest seam bounds it inside the passwd
# home, which is exactly what that seam exists for.
import tempfile as _tf
with _tf.TemporaryDirectory(prefix=".sdp-hooktest-", dir=win_home) as hk:
    iso = dict(os.environ)
    iso.update({
        "SDP_PRECOMPACT_SELFTEST": "1",
        "SDP_PRECOMPACT_HOME": hk,
        "SDP_PRECOMPACT_STATE_DIR": os.path.join(hk, "state"),
        "SDP_PRECOMPACT_MODE": "auto",
    })
    os.makedirs(os.path.join(hk, "state"), exist_ok=True)
    out = subprocess.run(["bash", str(launcher), "doctor"], input="{}", text=True,
                         capture_output=True, timeout=30, env=iso)
    check(out.returncode == 0 and "state dir" in out.stdout,
          "W18: the launcher runs the hook and passes stdin/stdout/exit through")
    check(hk in out.stdout,
          "W18: the isolated run used the seamed state dir, not the developer's ~/.sdp")
missing = subprocess.run(["/bin/bash", str(launcher), "stop"], input="{}", text=True,
                         capture_output=True, timeout=30,
                         env={"PATH": "/nonexistent"})
check(missing.returncode != 0 and "no Python" in missing.stderr,
      "W18: with no interpreter resolvable the launcher fails LOUDLY (rc=%d) rather than "
      "reporting a hook that did nothing as a success" % missing.returncode)

raise SystemExit(1 if FAIL else 0)
HOOKPY
then ok "W18: hook manifests, encoded payload and launcher contract"
else bad "W18: see the FAIL lines above"
fi

# ---- W5: static bans (ADR-W02 / ADR-W03) ------------------------------------
# AST-based, not grep: every one of these tokens appears in prose in the shipped
# files precisely BECAUSE the code must not do it ("never via $HOME/expanduser",
# "Deliberately not %USERPROFILE%"). A textual scan flags those comments and would
# have to be silenced, which defeats the check.
if python3 - "$SDP_ROOT" <<'W5PY'
import ast, pathlib, sys

root = pathlib.Path(sys.argv[1])
BANNED_ENV = ("HOME", "USERPROFILE", "USERNAME")
problems = []
for tree in ("scripts", "plugins/sdp/scripts"):
    for path in sorted((root / tree).rglob("*.py")):
        if "__pycache__" in path.parts:
            continue
        node = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for n in ast.walk(node):
            if isinstance(n, ast.Assign):
                for t in n.targets:
                    if (isinstance(t, ast.Attribute) and t.attr == "getuid"
                            and isinstance(t.value, ast.Name) and t.value.id == "os"):
                        problems.append("%s:%d: assigns os.getuid" % (path, n.lineno))
            if isinstance(n, ast.Call):
                f = n.func
                if isinstance(f, ast.Name) and f.id == "setattr" and len(n.args) >= 2:
                    a1 = n.args[1]
                    if isinstance(a1, ast.Constant) and a1.value == "getuid":
                        problems.append("%s:%d: setattr(os, 'getuid')" % (path, n.lineno))
                if isinstance(f, ast.Attribute) and f.attr == "expanduser":
                    problems.append("%s:%d: calls expanduser()" % (path, n.lineno))
                if (isinstance(f, ast.Attribute) and f.attr == "home"
                        and isinstance(f.value, ast.Name) and f.value.id == "Path"):
                    problems.append("%s:%d: calls Path.home()" % (path, n.lineno))
                if (isinstance(f, ast.Attribute) and f.attr == "get"
                        and isinstance(f.value, ast.Attribute) and f.value.attr == "environ"
                        and n.args and isinstance(n.args[0], ast.Constant)
                        and n.args[0].value in BANNED_ENV):
                    problems.append("%s:%d: reads os.environ.get(%r)" % (path, n.lineno, n.args[0].value))
            if isinstance(n, ast.Subscript):
                v = n.value
                if (isinstance(v, ast.Attribute) and v.attr == "environ"
                        and isinstance(n.slice, ast.Constant)
                        and n.slice.value in BANNED_ENV):
                    problems.append("%s:%d: reads os.environ[%r]" % (path, n.lineno, n.slice.value))
if problems:
    print("\n".join(problems), file=sys.stderr)
    raise SystemExit(1)
W5PY
then ok "W5: no shipped script defines os.getuid or resolves home/user from the environment"
else bad "W5: a shipped script violates ADR-W02 or ADR-W03 (see above)"
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
