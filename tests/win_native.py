#!/usr/bin/env python3
"""Native Windows acceptance for the SDP port -- ADR-W10's matrix, executed.

Everything else about this port is verified by simulating Windows inside a POSIX
process, which cannot substantiate msvcrt locking, the ctypes Win32 calls, NTFS
attributes or process teardown. This file is the part that only a real Windows
interpreter can answer, so it refuses to pretend anywhere else.

Each check names the ADR-W10 case it discharges. A1-A10 and A15 are GATES: they
must pass before Windows support may be claimed. A12-A14 are MEASUREMENTS -- they
record what the host does and never fail the run, because their outcome updates
KNOWN_GAPS NC-30 rather than blocking. A11 (substitution by a second local
account) cannot be automated on a shared CI runner and stays unrun.

Run:  python tests/win_native.py
"""

from __future__ import annotations

import base64
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

GATE_FAILURES: list[str] = []
MEASUREMENTS: list[str] = []


def gate(ok: bool, case: str, msg: str) -> None:
    print(("ok   - [%s] %s" if ok else "FAIL - [%s] %s") % (case, msg))
    if not ok:
        GATE_FAILURES.append("%s: %s" % (case, msg))


def measure(case: str, msg: str) -> None:
    print("meas - [%s] %s" % (case, msg))
    MEASUREMENTS.append("%s: %s" % (case, msg))


def make_junction(link: Path, target: Path) -> bool:
    """mklink /J needs no administrator rights, unlike a symlink."""
    r = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)],
                       capture_output=True, text=True)
    return r.returncode == 0 and link.exists()


def main() -> int:
    if os.name != "nt":
        print("SKIP - not a Windows host; this file asserts nothing elsewhere "
              "(that is the whole point of it)")
        return 0

    # This script's OWN stdout is cp1252 on a stock Windows runner, so printing a
    # non-ASCII measurement kills the harness before it can report -- which is the
    # very failure class A12 exists to measure. Fix the reporter, and never echo raw
    # non-ASCII into it: the measurement is what survived the CHILD pipe, not what
    # this console can render.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass
    print("python: %s" % sys.version.replace("\n", " "))
    print("stdout encoding: %s" % (getattr(sys.stdout, "encoding", "?"),))

    # ---- A3: every entry point imports ------------------------------------
    try:
        import win_compat, config_discovery, review_gate, precompact_hook  # noqa: F401
        import sdp_mcp_server, claude_gate  # noqa: F401
        gate(True, "A3", "all six modules import on native Windows")
    except BaseException as exc:
        gate(False, "A3", "import failed: %r" % (exc,))
        print("A3 is the precondition for everything below; stopping.")
        return 1

    import win_compat, config_discovery as cd, review_gate as rg, precompact_hook as ph

    # ---- A5: os.getuid must not exist -------------------------------------
    gate(not hasattr(os, "getuid"),
         "A5", "os.getuid is undefined after a full import (ADR-W02)")
    gate(not win_compat.posix_perms_meaningful(),
         "A5", "posix_perms_meaningful() is False, so both halves of every "
               "permission check are skipped together")
    gate(win_compat.trust_mode() == "degraded-windows",
         "A5", "the audit record will carry trust=degraded-windows")

    # ---- A4: identity resolves from Win32, never the environment ----------
    real_home = win_compat.passwd_home()
    real_user = win_compat.passwd_name()
    gate(bool(real_home) and os.path.isdir(real_home),
         "A4", "SHGetKnownFolderPath returned an existing profile dir: %s" % real_home)
    gate(bool(real_user), "A4", "GetUserNameW returned %r" % real_user)
    backup = dict(os.environ)
    os.environ.update({"USERPROFILE": r"C:\evil", "HOME": r"C:\evil",
                       "USERNAME": "evil", "USER": "evil"})
    try:
        gate(win_compat.passwd_home() == real_home,
             "A4", "passwd_home() ignores a poisoned USERPROFILE/HOME")
        gate(win_compat.passwd_name() == real_user,
             "A4", "passwd_name() ignores a poisoned USERNAME/USER")
    finally:
        os.environ.clear()
        os.environ.update(backup)

    # ---- A9: reviewer resolution uses a fixed extension list --------------
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        (d / "faker.cmd").write_text("@echo off\r\n")
        os.environ["PATHEXT"] = ".EVIL"
        try:
            found = win_compat.which_fixed("faker", path=str(d))
            gate(found is not None and found.lower().endswith("faker.cmd"),
                 "A9", "which_fixed resolves a .cmd with a hostile ambient PATHEXT")
        finally:
            os.environ.pop("PATHEXT", None)

    # ---- A10: junction substitution is refused ----------------------------
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        real = d / "real"; real.mkdir()
        (real / "tok").write_text("x")
        link = d / "link"
        if not make_junction(link, real):
            measure("A10", "mklink /J unavailable on this runner; junction cases unrun")
        else:
            try:
                win_compat.reject_reparse_chain(d, link / "tok")
                gate(False, "A10", "a junction in the path was accepted")
            except OSError:
                gate(True, "A10", "reject_reparse_chain refuses a junctioned ancestor")
            try:
                win_compat.reject_reparse_chain(d, real / "tok")
                gate(True, "A10", "the same file by its real path is accepted")
            except OSError as exc:
                gate(False, "A10", "real path rejected: %s" % exc)
            # through the CALLER, not the helper
            os.environ["SDP_BASE_DIR"] = str(link)
            try:
                rg._audit_base(d)
                gate(False, "A10", "_audit_base accepted a junctioned SDP_BASE_DIR")
            except rg.InfraError:
                gate(True, "A10", "_audit_base refuses a junctioned SDP_BASE_DIR")
            except BaseException as exc:
                gate(False, "A10", "_audit_base raised %r" % (exc,))
            finally:
                os.environ.pop("SDP_BASE_DIR", None)

    # ---- A6/A7/A8: msvcrt locking, for real -------------------------------
    with tempfile.TemporaryDirectory() as td:
        lock = Path(td) / "s.lock"
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import sys,time; sys.path.insert(0, r'%s')\n"
             "import review_gate as rg\n"
             "from pathlib import Path\n"
             "with rg._state_lock(Path(r'%s'), time.monotonic()+60):\n"
             "    print('held', flush=True); time.sleep(60)\n"
             % (REPO / "scripts", lock)],
            stdout=subprocess.PIPE, text=True)
        try:
            ready = holder.stdout.readline().strip() if holder.stdout else ""
            gate(ready == "held", "A6", "a child process acquired the state lock")
            t0 = time.monotonic()
            try:
                with rg._state_lock(lock, time.monotonic() + 1):
                    gate(False, "A7", "the held lock was acquired twice")
            except rg.InfraError as exc:
                gate("state lock wait timed out" in str(exc),
                     "A7", "contention raises InfraError, unmasked by the unlock path")
                gate(time.monotonic() - t0 < 30,
                     "A7", "the deadline is honoured rather than blocking")
            except BaseException as exc:
                gate(False, "A7", "timeout was masked by %r" % (exc,))
        finally:
            holder.kill()
            holder.wait(timeout=30)
        try:
            with rg._state_lock(lock, time.monotonic() + 10):
                gate(True, "A8", "a killed holder releases the lock")
        except BaseException as exc:
            gate(False, "A8", "lock not released after the holder died: %r" % (exc,))

    # ---- A15: teardown reaches the descendant -----------------------------
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        pidfile = d / "grandchild.pid"
        sleeper = d / "sleep.py"
        sleeper.write_text(
            "import os,sys,time\n"
            "open(sys.argv[1],'w').write(str(os.getpid()))\n"
            "time.sleep(120)\n")
        wrapper = d / "w.cmd"
        wrapper.write_text('@echo off\r\n"%s" "%s" "%s"\r\n'
                           % (sys.executable, sleeper, pidfile))
        proc = subprocess.Popen([str(wrapper)], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 30
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not pidfile.exists():
            measure("A15", "the grandchild never started; teardown case unrun")
            proc.kill()
        else:
            gpid = int(pidfile.read_text().strip())
            import signal as _sig
            win_compat.kill_process_tree_hard(proc, _sig)
            time.sleep(2)
            alive = subprocess.run(["tasklist", "/FI", "PID eq %d" % gpid],
                                   capture_output=True, text=True).stdout
            gate(str(gpid) not in alive,
                 "A15", "the Node-style descendant of a .cmd wrapper is reaped, "
                        "not just the wrapper")
            if str(gpid) in alive:
                subprocess.run(["taskkill", "/PID", str(gpid), "/F"],
                               capture_output=True)

    # ---- A13: a prompt over 8191 characters survives ----------------------
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        echo = d / "echo.cmd"
        reader = d / "r.py"
        # Emit a real verdict line: _run_argv classifies anything else as infra and
        # parks the text in .reason, so a stub that prints bare text would be
        # asserting against the error path rather than the working one.
        reader.write_text("import sys; d=sys.stdin.read(); print('ALLOW: BYTES', len(d))\n")
        echo.write_text('@echo off\r\n"%s" "%s"\r\n' % (sys.executable, reader))
        big = "x" * 20000
        res = rg._run_argv([str(echo)], cwd=d, timeout_s=60, max_output=100000,
                           stdin_text=big)
        got = "BYTES 20000" in (res.line or "")
        gate(got, "A13", "a 20000-character prompt reaches the child over stdin "
                         "(the argv route caps at 8191); child said %r"
                         % ((res.line or res.reason or "").strip()[:48],))

    # ---- A12: non-ASCII reviewer output decodes --------------------------
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        emit = d / "e.py"
        emit.write_text("import sys; sys.stdout.reconfigure(encoding='utf-8'); "
                        "print('ALLOW: \\uc548\\ub155 \\u65e5\\u672c\\u8a9e')\n")
        wrapper = d / "e.cmd"
        wrapper.write_text('@echo off\r\n"%s" "%s"\r\n' % (sys.executable, emit))
        res = rg._run_argv([str(wrapper)], cwd=d, timeout_s=60, max_output=100000)
        seen = res.line or res.reason or ""
        ok = "\uc548\ub155" in seen and "\u65e5\u672c\u8a9e" in seen
        # Report codepoints, not glyphs: what matters is whether the bytes survived
        # the child pipe, and echoing the glyphs makes the report depend on the
        # console codepage -- a different question from the one being measured.
        measure("A12", "UTF-8 reviewer output %s; non-ASCII codepoints seen: %s"
                % ("decoded intact" if ok else "did NOT survive",
                   [hex(ord(c)) for c in seen if ord(c) > 127][:8] or "none"))

    # ---- A14: os.replace under a concurrent open handle ------------------
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        src = d / "s"; src.write_text("new")
        dst = d / "d"; dst.write_text("old")
        handle = open(dst, "r")
        try:
            os.replace(src, dst)
            measure("A14", "os.replace SUCCEEDED with a reader handle open")
        except OSError as exc:
            measure("A14", "os.replace FAILED with a reader handle open: %s" % exc)
        finally:
            handle.close()

    print()
    for m in MEASUREMENTS:
        print("measurement: %s" % m)
    if GATE_FAILURES:
        print("\n%d gate case(s) FAILED:" % len(GATE_FAILURES))
        for f in GATE_FAILURES:
            print("  %s" % f)
        return 1
    print("\nall gate cases passed (A11 and the Codex hook E2E remain unrun)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
