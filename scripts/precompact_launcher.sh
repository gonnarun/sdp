#!/usr/bin/env bash
# Interpreter resolution for the precompact hooks.
#
# The manifests used to invoke `python3` directly. Windows CPython does not
# guarantee that name: the python.org installer ships `python.exe` and the `py`
# launcher, and `python3.exe` exists only as a Microsoft Store alias.
#
# Resolution order is platform-dependent on purpose. `py` is the official Windows
# launcher, but on POSIX `py` is an unrelated third-party command that must not be
# picked up, so it is only preferred where uname says Windows. On POSIX `python3` is
# the only name guaranteed to be Python 3; bare `python` is a last resort and is
# version-probed, because on an older box it can still be Python 2.
#
# Failure is LOUD. An earlier revision exited 0 when nothing could be resolved,
# which reports "did nothing" as "succeeded" -- the same invisible failure that makes
# the Codex Windows hook bug so hard to notice. A hook must not wedge a session, but
# it must also not lie about having run.
set -eu

# Derived with parameter expansion, not `dirname`/`cd`: a hook can be invoked with a
# minimal PATH, and shelling out for the path would fail before the real work starts
# -- with a misleading message about a missing script.
self="${BASH_SOURCE[0]:-$0}"
here="${self%/*}"
[ "$here" = "$self" ] && here="."
script="$here/precompact_hook.py"

if [ ! -f "$script" ]; then
  printf 'sdp precompact hook: script not found at %s\n' "$script" >&2
  exit 127
fi

_is_windows() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) return 0 ;;
    *) [ "${OS:-}" = "Windows_NT" ] ;;
  esac
}

_py_ok() {   # $1 = interpreter word list; accept only Python >= 3.9
  "$@" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' \
    >/dev/null 2>&1
}

if _is_windows && command -v py >/dev/null 2>&1 && _py_ok py -3; then
  exec py -3 "$script" "$@"
fi
if command -v python3 >/dev/null 2>&1 && _py_ok python3; then
  exec python3 "$script" "$@"
fi
if command -v python >/dev/null 2>&1 && _py_ok python; then
  exec python "$script" "$@"
fi

printf 'sdp precompact hook: no Python >= 3.9 found (tried %s)\n' \
  "$(_is_windows && printf 'py -3, ')python3, python" >&2
exit 127
