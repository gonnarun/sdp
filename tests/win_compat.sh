#!/usr/bin/env bash
# win_compat.sh — the platform layer (scripts/win_compat.py) and the POSIX-parity
# contract of plan_windows-support.md §6.1.
#
#   W1  simulated Windows  — with pwd/fcntl blocked and the POSIX-only os attributes
#                            removed, all five entry points still import, and
#                            os.getuid is NOT defined afterwards (ADR-W02).
#   W2  POSIX parity       — the predicate is True here, and every one of the seven
#                            guard sites still produces its exact current outcome for
#                            a group-writable fixture AND accepts a clean one. Both
#                            halves matter: a predicate stuck at False would reject
#                            nothing and pass the rejection cases vacuously.
#   W3  resolvers          — no environment variable can move home/user, the
#                            _PASSWD_HOME seam still overrides, _safe_path is still
#                            os.pathsep-joined and rooted at the passwd home.
#   W4  reparse chain      — rejection at the base, at an intermediate ancestor, and
#                            at the target itself (ADR-W05 W05-b(1)).
#   W5  static bans        — no shipped script assigns os.getuid or resolves home
#                            from the environment.
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
