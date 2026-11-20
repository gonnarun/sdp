#!/usr/bin/env python3
"""Hook driver that chains a precompact snapshot to the post-compact resume.

Three lifecycle hooks, registered by ``hooks/hooks.json`` in this plugin, turn
``/sdp:precompact`` from "the user remembers to run it, then pastes the resume
prompt by hand" into a closed loop:

1. ``stop``       -- Stop hook. Reads the real context usage out of the session
                     transcript. Above the threshold it answers
                     ``{"decision":"block","reason":...}``, which re-enters the
                     agent loop with the reason appended as a message, so the
                     model takes a full tool-capable turn and writes the
                     snapshot. This is the injection primitive: hooks cannot
                     type into the input box and cannot expand a slash command,
                     but a blocked Stop is a real turn.
2. ``precompact`` -- PreCompact hook. Binds the snapshot this session just wrote
                     to this ``session_id`` before the context is destroyed.
                     Binding is what stops a second session in the same
                     directory from resuming the wrong work.
3. ``resume``     -- SessionStart(``compact``) hook. Emits the snapshot path as
                     ``hookSpecificOutput.additionalContext``, which lands in the
                     post-compact message list, and clears the marker so the
                     cycle can re-arm.

After an AUTO compact the agent loop continues on its own, so the injected
context is acted on with no user input. After a MANUAL ``/compact`` the host
returns to the prompt. An optional terminal driver can close that second gap:
on Codex its detached waiter observes the real ``compacted`` then
``task_complete`` lifecycle in this session's rollout before it submits the
first post-compact message. That message starts the turn on which
``SessionStart(compact)`` injects the bound context.

A typed prompt is only half the contract: the driver reports input acceptance and
submission as separate stages and exits 0 for both, so an Enter the host swallowed
looks exactly like a delivered one. Every send here therefore requires the
``turn_started`` stage, re-observes the same request once when it is missing, and
never re-sends -- a prompt that may already be queued must not be typed twice.

Fail-close: ``mode`` must be ``auto`` before a Stop is ever blocked. Unset is not
auto. Every failure path exits 0 -- a broken hook must never wedge a session.

CLI (also usable by hand):
    precompact_hook.py doctor            health report, loud about half-installs
    precompact_hook.py config get        auto | manual | unset
    precompact_hook.py config set auto   persist the mode
"""

from __future__ import annotations

import functools
import json
import math
import os
import shlex
import shutil
import stat
import subprocess
import sys
import threading
import time
from datetime import datetime
import uuid
from pathlib import Path

import win_compat

STATE_DIRNAME = "precompact-state"
CONFIG_BASENAME = "precompact.json"
SDP_HOME_DIRNAME = ".sdp"

VALID_MODES = ("auto", "manual")
DEFAULT_THRESHOLD_PCT = 78.0
DEFAULT_CONTEXT_TOKENS = 200_000
WIDE_CONTEXT_TOKENS = 1_000_000

# A pending marker older than this is abandoned. Short on purpose: a pending
# marker suppresses all further detection, so a block that produced no snapshot
# must not buy hours of silence during which the real crossing goes unnoticed.
PENDING_EXPIRY_SEC = 20 * 60
# An injected marker older than this is re-armed. Without this a session that
# ended without ever compacting stays permanently blocked from re-detecting.
REARM_SEC = 2 * 3600
# How far back precompact/ is scanned for a snapshot when no marker pins one.
UNBOUND_FRESH_SEC = 60 * 60
# Slack applied to a marker timestamp when matching a snapshot to it.
BOUND_SLACK_SEC = 120
# Largest JSON config this reads. A settings file is kilobytes; anything
# larger is not worth parsing on every Stop.
MAX_JSON_BYTES = 1 << 20
# Cap on the pre-block snapshot inventory. Basenames, not paths, and bounded:
# an unbounded list in the marker could push it past MAX_JSON_BYTES, at which
# point the marker reads back as empty and every turn blocks again.
MAX_INVENTORY = 500

SNAPSHOT_SUBDIR = Path(".private") / "precompact"
SNAPSHOT_PREFIX = "precompact_"

# --- optional terminal driver --------------------------------------------
# A hook cannot expand a slash command and no host exposes a programmatic
# compaction trigger, so the only way to close the loop at the moment the user
# asks for it is to type into the session's own input box. Where a terminal
# driver is present that is possible; where it is not, every branch below is
# skipped and the chain still completes later on the host's own auto-compaction.
# Pane bindings older than this are not trusted: a session can be moved to a
# different pane, and typing into where it used to be is the same mistake as
# guessing.
PANE_BINDING_MAX_AGE_SEC = 12 * 3600
# A self-fire intent covers ONE compaction that is already queued, so it lives
# only as long as the waiter plus slack. Sharing the binding's lifetime would
# leave it armed for hours and let an unrelated later compaction fire a resume.
SELF_FIRE_INTENT_TTL_SEC = 5 * 60
# How long to wait for the session to stop working before giving up on typing.
INJECT_IDLE_TIMEOUT_MS = 120_000
# Codex reports a slash-command compaction as TUI-idle even while the compact
# task is running. Its rollout is the authoritative completion signal instead.
# Keep this below the self-fire intent TTL after the first idle wait.
CODEX_COMPACT_TIMEOUT_SEC = 120.0
CODEX_COMPACT_POLL_SEC = 0.25
# The driver separates INPUT ACCEPTANCE from SUBMISSION, and exits 0 for both.
# A receipt that stops at ``input_accepted`` means the Enter may have been
# swallowed and the text is sitting in the composer -- the exact failure a user
# sees as "/compact appeared but nothing happened". Proof is the ``turn_started``
# stage, observed for this long. The same request is then RE-OBSERVED once, never
# re-sent: the driver's contract is "never resend on silence".
SUBMIT_OBSERVE_SEC = 15
SUBMIT_REOBSERVE_SEC = 15
# The subprocess has to outlast the observation it asked for. Killing the driver
# mid-observation turns a knowable answer into an ambiguous transport failure.
SUBMIT_SUBPROCESS_SLACK_SEC = 10
# Providers whose turn start the driver can observe. A target outside this set is
# not an agent TUI at all -- on a plain shell "/compact" would run as a command --
# so an unobservable provider is a WRONG TARGET, not merely an unproven send.
AGENT_PROVIDERS = ("claude", "codex")
# Submission outcomes. LEGACY is "no proof obtainable here", which is not the same
# as proof of success and is recorded as itself.
SEND_PROVEN = "proven"
SEND_UNPROVEN = "unproven"
SEND_REJECTED = "rejected"
SEND_LEGACY = "legacy-unverified"

RESUME_INJECT_PROMPT = (
    "Continue from the precompact snapshot named in the injected context. Read "
    "that file first, then resume from section 0 (Current Work) and section 2 "
    "(Remaining). Open with one line confirming the precompact cycle completed."
)

# The automation fast-path, and why it reads like a budget rather than a
# workflow. Measured 2026-09-23, Codex session 01a0c2ba, window 258400: the
# block landed at 81.6% and the host compacted at 83.1%, so the turn it bought
# was worth about 2800 tokens. The model spent 3960 of them preparing -- 840
# re-reading the skill it had just been told to follow, 2558 on an agent
# listing, 562 on the git/gh/ssh fan-out that the skill's "gather measured
# context" step asks for -- and the snapshot was never written. Nothing in that
# turn was wrong except its cost. So this text states the budget and forbids
# the preparation, instead of pointing at a workflow whose first step is to go
# out and measure things. The skill's numbered workflow stays as the manual
# path; see its "Automation fast-path" section.
# What the block may claim about the day directory. The hook creates it, but a
# read-only tree, a reparse point in the chain or a vanished cwd all make that
# fail, and the text must then say so rather than assert a directory that is
# not there. The mkdir carve-out exists only on that path.
DIR_READY_NOTE = "That directory already exists -- it was created for you."
DIR_MISSING_NOTE = (
    "That directory could NOT be created for you. Try ONE mkdir -p of it and "
    "then write the file -- that is the only command allowed here. If the "
    "mkdir fails, do not retry and do not look into why: say in one line that "
    "the snapshot directory could not be created, and stop."
)
# The mkdir clause either bans it outright or carves out the single exception
# the fallback above just required. It is never absent: dropping the word is
# how "no commands" quietly stops covering the one command that matters here.
MKDIR_BANNED_NOTE = "no mkdir, "
MKDIR_ALLOWED_NOTE = "no mkdir beyond the one named above, "
# The unsafe path gets its own text rather than a note inside the normal one.
# There is no snapshot to ask for: the location is refused, and every sentence
# about topics, sections and tags would be an instruction to write there anyway.
UNSAFE_DIR_REASON = (
    "Context usage is at {pct:.0f}% of the window, past the SDP precompact "
    "threshold of {threshold:.0f}%, but the snapshot location is REFUSED: a "
    "component of {cwd}/.private/precompact is not a plain directory inside "
    "this workspace. It is a symlink or junction, which would resolve "
    "elsewhere, or a file or other object occupying the name. Snapshots "
    "written there are read back into the next context, so SDP will not "
    "create or use it and you must not create it either.\n"
    "Do not write a snapshot. Tell the user this in one line, name the path, "
    "and say that every component of .private/precompact must be a real "
    "directory inside the workspace before automatic precompact can work "
    "here. Then stop."
)
BLOCK_REASON = (
    "Context usage is at {pct:.0f}% of the window, past the SDP precompact "
    "threshold of {threshold:.0f}%. Auto-compact is imminent and will discard "
    "the working state. This turn is the whole budget: whatever you spend here "
    "is taken from the snapshot, and a compaction can land mid-turn, so a "
    "snapshot written late is a snapshot lost.\n"
    "Write .private/precompact/{today}/precompact_{{topic}}_{tag}.md NOW, from "
    "what is already in this conversation. {dir_note} The _{tag} suffix is "
    "required: it is what binds this snapshot to this session. Infer the topic "
    "from the work in progress; do not ask the user to choose.\n"
    "Run no commands to prepare it, and open no files. No git, no gh, no ssh, "
    "{mkdir_note}no reads, no searches, no agent or task listings, and no "
    "reference or manual pages. This message is the contract; anything you "
    "read instead is charged to the snapshot. The MANUAL procedure, including "
    "its \"gather measured context\" step, does not apply here.\n"
    "Keep the six sections (0 Current Work, 1 Completed, 2 Remaining, 3 Open "
    "Files / Locations, 4 Pitfalls / Rules, 5 Open Questions). Any fact you "
    "cannot supply from memory of this conversation is `unknown` -- an "
    "`unknown` costs nothing and a missing file costs everything. Never invent "
    "a hash, path or result to fill a section.\n"
    "The file is the only deliverable. Do not print the resume prompt, do not "
    "start new work, do not commit or push, and say at most one short line "
    "after the write. The post-compact resume is injected automatically once "
    "the snapshot exists."
)

RESUME_CONTEXT = (
    "[SDP precompact] A snapshot of the in-progress work was written just "
    "before this compaction: {snapshot}\n"
    "Read that file first, then continue the work from section 0 (Current Work) "
    "and section 2 (Remaining), in that order. Check section 4 "
    "(Pitfalls / Rules) and section 5 (Open Questions) before acting; if an "
    "open question is unresolved, ask the user before continuing. Do not commit "
    "or push unless explicitly approved."
)

MISSING_SNAPSHOT_CONTEXT = (
    "[SDP precompact] A precompact snapshot was requested before this "
    "compaction but no snapshot file was found. Tell the user the snapshot is "
    "missing and ask what to resume before doing any work."
)


# --------------------------------------------------------------------------
# home / config
# --------------------------------------------------------------------------


@functools.lru_cache(maxsize=1)
def passwd_home() -> Path:
    """Home from the passwd database, never $HOME.

    Same rule the gate uses: a poisoned $HOME must not be able to move the
    config or the state directory to somewhere an attacker controls.
    """
    return Path(win_compat.passwd_home()).resolve(strict=True)


def _selftest_override(name: str) -> str:
    """A path seam that exists only for the suite.

    The real locations come from the passwd database precisely so a hostile
    environment cannot move them. An unconditional env override hands that
    capability straight back -- and for the state directory it also hands over
    a delete primitive, since window records are pruned there.

    Two conditions, because the flag alone is only hygiene: whoever can set the
    path can set the flag. The override must ALSO resolve inside the user's own
    home, which is what actually bounds the damage -- the suite can point at a
    temp directory under $HOME, and nothing can be relocated or deleted outside
    it.
    """
    if os.environ.get("SDP_PRECOMPACT_SELFTEST") != "1":
        return ""
    raw = os.environ.get(name) or ""
    if not raw:
        return ""
    try:
        home = passwd_home()
        resolved = Path(raw).resolve(strict=False)
        resolved.relative_to(home)
        # resolve() above follows a junction, so containment is checked on a path the
        # substitution has already been erased from. Validate the RAW path too, so an
        # override that merely POINTS inside the home through a link is refused
        # rather than accepted on the strength of where it lands.
        win_compat.reject_reparse_chain(home, Path(raw))
    except (OSError, ValueError, KeyError):
        return ""
    return str(resolved)


def _assert_trusted(path: Path, what: str) -> Path:
    """Refuse a state path reached through a symlink or junction. EVERY platform.

    An earlier revision of this guard ran on Windows only, with a comment claiming
    POSIX was already covered by ``O_NOFOLLOW`` and uid checks. **That claim was
    false.** This module has no uid check anywhere, and ``O_NOFOLLOW`` protects only
    the final component of a write -- neither stops ``~/.sdp`` or the state
    directory itself from being a symlink that every read, write and unlink then
    follows. ``_prune_windows`` unlinks under ``state_dir()``, so this is a delete
    primitive on POSIX exactly as much as on Windows.

    ``reject_reparse_chain`` detects POSIX symlinks as well as Windows junctions, so
    the guard is unconditional.

    BEHAVIOUR CHANGE, deliberate: a deliberately symlinked ``~/.sdp`` -- a plausible
    dotfile-management arrangement -- is now refused on every platform. Failing
    closed was chosen over honouring it because the alternative is an unbounded
    delete primitive. Recorded in KNOWN_GAPS NC-30.
    """
    win_compat.reject_reparse_chain(win_compat.passwd_home(), path)
    return path


def sdp_home() -> Path:
    override = _selftest_override("SDP_PRECOMPACT_HOME")
    if override:
        return _assert_trusted(Path(override), "sdp home override")
    return _assert_trusted(passwd_home() / SDP_HOME_DIRNAME, "sdp home")


def config_path() -> Path:
    # Every returned state path is validated to its OWN last component. Validating
    # only the parent leaves the leaf -- ~/.sdp/precompact, ~/.sdp/precompact.json --
    # free to be a junction, which is the component an attacker would actually plant.
    return _assert_trusted(sdp_home() / CONFIG_BASENAME, "config path")


def state_dir() -> Path:
    override = _selftest_override("SDP_PRECOMPACT_STATE_DIR")
    if override:
        return _assert_trusted(Path(override), "state dir override")
    return _assert_trusted(sdp_home() / STATE_DIRNAME, "state dir")


def read_cycles(limit: int = 2000) -> list:
    """Read the cycle ledger, newest last. Malformed lines are skipped, not fatal.

    Bounded by line count as well as by file size: the ledger is appended to by
    every session on the machine, and doctor must stay cheap enough to run.
    """
    try:
        path = cycles_path()
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            return []
        with open(path, "r", encoding="utf-8") as fh:
            if st.st_size > MAX_CYCLES_BYTES:
                # Concurrent appenders can carry the file past the soft cap.
                # Refusing to read it then would hide every measurement the
                # ledger exists to collect, permanently, which is a worse
                # outcome than the one the cap guards against. Seek to the last
                # window instead and drop the first line, which is almost
                # certainly cut in half.
                fh.seek(st.st_size - MAX_CYCLES_BYTES)
                fh.readline()
            lines = fh.readlines()[-limit:]
    except (OSError, ValueError):
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def cycles_path() -> Path:
    """Where finished cycles accumulate.

    Its own seam, separate from the state directory's. The suite deliberately
    exercises markers in the REAL state directory and sweeps them afterwards by
    session-id pattern -- which works because a marker is one file per session.
    The ledger is a single shared append-only file: it matches no per-session
    pattern, and sweeping it would delete the user's actual measurements along
    with the synthetic ones. So the tests redirect this instead. Without that,
    every suite run silently files its fixtures as real history; two rounds of
    this change did exactly that, 66 rows and then 99.
    """
    override = _selftest_override("SDP_PRECOMPACT_CYCLES")
    if override:
        return _assert_trusted(Path(override), "cycle ledger override")
    return _assert_trusted(state_dir() / CYCLES_BASENAME, "cycle ledger")


def record_cycle(row: dict) -> bool:
    """Append one finished precompact cycle to the ledger. Never raises.

    Why a ledger rather than the marker: the marker is deleted when the cycle
    closes, so the one number that decides the threshold -- what the snapshot
    turn actually cost -- is destroyed at exactly the moment it becomes known.
    Nothing here steers behaviour today; the rows exist so the Codex-side
    absolute-token gate can be set from measurement instead of from the single
    reverse-engineered observation that is all KNOWN_GAPS NC-34 has.

    Honest about what it cannot see: ``used_at_precompact`` is measured when
    PreCompact fires, which is AFTER the snapshot turn, so the recorded cost is
    that turn's whole cost and not the write's alone. No hook runs at the write
    itself, so the narrower number is not observable from here. That makes the
    recorded value an UPPER bound, which is the safe direction: a headroom
    fitted to it is larger than necessary and the threshold fires earlier than
    necessary. Wasting a little context is the failure this trades for losing a
    snapshot. The field is named ``turn_cost_upper_bound`` so nobody has to
    remember which way it errs.

    Append-only and best-effort: a failed append must never cost a compaction,
    so every error is swallowed and reported through the return value. The size
    limit is a soft cap -- see the comment at the size test for what concurrency
    does to it.
    """
    try:
        line = json.dumps(row, sort_keys=True) + "\n"
    except (TypeError, ValueError):
        return False
    if len(line) > MAX_CYCLE_ROW_BYTES:
        return False
    try:
        path = cycles_path()
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    # O_APPEND makes concurrent sessions interleave whole lines rather than
    # overwrite each other; O_NOFOLLOW keeps the ledger from being aimed
    # elsewhere.
    flags = win_compat.open_flags(
        os.O_WRONLY, os.O_CREAT, os.O_APPEND, getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        fd = os.open(path, flags, 0o600)
    except OSError:
        return False
    # Ownership of the descriptor is handed to fdopen only on the success path.
    # Every early return below is a refusal, and a refusal that leaks a
    # descriptor turns a bounded ledger into an unbounded fd leak in a hook
    # that runs on every compaction.
    handed_off = False
    try:
        # Every check below runs on the OPEN DESCRIPTOR, not on the path. An
        # lstat before the open decides about a file that may no longer be the
        # one being written to, and that is the difference between a cap and a
        # suggestion.
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return False
        # The size test includes the row about to be appended, so the cap holds
        # for this writer rather than being discovered one row after it broke.
        # It is still a SOFT cap under concurrency: two appenders can both pass
        # it and both write, so the ledger can exceed the limit by at most one
        # row per concurrent writer. Taking a lock to close that would put a
        # blocking syscall on the compaction path to protect a disk bound, which
        # is the wrong trade; the overshoot is bounded and the cap is what
        # matters.
        if st.st_size + len(line.encode("utf-8")) > MAX_CYCLES_BYTES:
            return False
        # 0600 in os.open applies to CREATION only. A ledger that already
        # existed with wider bits keeps them, and this file records session
        # ids and working-directory-derived names. Narrow it on the descriptor
        # rather than trusting the mode the open did not set.
        # POSIX only. On Windows os.fchmod may be absent entirely, and NTFS
        # reports group/world bits in st_mode that mean nothing -- so this
        # branch would be entered on every append and an AttributeError would
        # escape the OSError handler below, breaking the "never raises"
        # contract inside a PreCompact hook. There, confidentiality rests on
        # the profile directory's ACL, which is what protects every other file
        # this engine writes on that platform.
        if win_compat.posix_perms_meaningful() and stat.S_IMODE(st.st_mode) & 0o077:
            try:
                os.fchmod(fd, 0o600)
            except (OSError, AttributeError):
                return False
        handed_off = True
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        return False
    finally:
        if not handed_off:
            try:
                os.close(fd)
            except OSError:
                pass
    return True


def _read_json(path: Path, max_bytes: int = MAX_JSON_BYTES) -> dict:
    """Read a JSON object, refusing anything that is not a plain regular file."""
    try:
        st = os.lstat(path)
    except OSError:
        return {}
    if not stat.S_ISREG(st.st_mode):
        return {}
    if st.st_size > max_bytes:
        return {}
    # Open without following a symlink and without blocking, then re-check the
    # OPENED file: a FIFO swapped in after the lstat must not hang the hook
    # before any deadline is running. Flags absent on a platform are 0.
    flags = win_compat.open_flags(os.O_RDONLY, getattr(os, "O_NOFOLLOW", 0), getattr(os, "O_NONBLOCK", 0))
    try:
        fd = os.open(path, flags)
    except OSError:
        return {}
    try:
        fst = os.fstat(fd)
        if not stat.S_ISREG(fst.st_mode) or fst.st_size > max_bytes:
            return {}
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            fd = -1
            data = json.load(fh)
    except (OSError, ValueError, RecursionError):
        return {}
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
    return data if isinstance(data, dict) else {}


def _write_json(path: Path, payload: dict) -> bool:
    """Atomically publish a JSON object. Returns whether it landed.

    Temp file in the SAME directory (a different one makes os.replace
    cross-device, therefore non-atomic), O_EXCL|O_NOFOLLOW at 0600, then
    os.replace to swap the directory entry. Callers act on the return value:
    a marker that did not persist cannot suppress the next detection, so
    pretending the write succeeded turns a one-shot block into a repeating one.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    # An existing target must be a plain file. os.replace onto a directory or a
    # FIFO is not a publish.
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            return False
    except OSError:
        pass
    tmp = path.with_name(path.name + ".tmp." + str(os.getpid()))
    # getattr form: a bare os.O_NOFOLLOW raises AttributeError where the constant
    # is absent, and AttributeError escapes the `except OSError` below.
    flags = win_compat.open_flags(os.O_WRONLY, os.O_CREAT, os.O_EXCL, getattr(os, "O_NOFOLLOW", 0))
    try:
        fd = os.open(tmp, flags, 0o600)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def resolve_mode() -> str:
    """auto | manual | unset. Env wins; an invalid env value never promotes."""
    env = os.environ.get("SDP_PRECOMPACT_MODE")
    if env in VALID_MODES:
        return env
    mode = _read_json(config_path()).get("mode")
    return mode if mode in VALID_MODES else "unset"


def is_auto_enabled() -> bool:
    return resolve_mode() == "auto"


def resolve_threshold() -> float:
    raw = os.environ.get("SDP_PRECOMPACT_THRESHOLD")
    for candidate in (raw, _read_json(config_path()).get("threshold")):
        try:
            value = float(candidate)  # type: ignore[arg-type]
        except (TypeError, ValueError):
            continue
        if 0 < value <= 100:
            return value
    return DEFAULT_THRESHOLD_PCT


def write_mode(mode: str) -> str:
    if mode not in VALID_MODES:
        raise ValueError("mode must be auto or manual, got: " + str(mode))
    current = _read_json(config_path())
    current["mode"] = mode
    try:
        float(current.get("threshold"))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        current["threshold"] = DEFAULT_THRESHOLD_PCT
    if not _write_json(config_path(), current):
        raise OSError("could not write " + str(config_path()))
    return mode


# --------------------------------------------------------------------------
# context measurement
# --------------------------------------------------------------------------


def _env_window(name: str) -> int | None:
    try:
        value = int(os.environ.get(name))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def explicit_window() -> int | None:
    """A window the operator stated outright, for this plugin, on any host.

    Deliberately separate from the host's own variable: this one is the
    documented escape hatch and outranks everything, including a window a host
    states exactly.
    """
    return _env_window("SDP_PRECOMPACT_CONTEXT_TOKENS")


def claude_host_window() -> int | None:
    """Claude Code's own window override.

    Applies only where the window has to be inferred. Codex states its window
    on every token_count event, and a Claude-specific variable that happens to
    be exported must not overrule a number the running host just reported --
    that reads a 258400-token session as though it had a million to spare.
    """
    return _env_window("CLAUDE_CODE_MAX_CONTEXT_TOKENS")


def _settings_says_wide(cwd: str = "") -> bool:
    """True when a configured model names a wide-window variant.

    A hint, not proof: a session can pick a different model after start. It
    only ever widens the assumed window, so a wrong hint cannot lose a snapshot
    -- it can only delay one. Worth gathering broadly for that reason: a
    session that has never compacted has no occupancy evidence yet, and without
    a hint it is measured against the narrow window and asks for a snapshot
    earlier than it needs to.
    """
    model = os.environ.get("ANTHROPIC_MODEL") or ""
    if "[1m]" in model:
        return True
    override = _selftest_override("SDP_PRECOMPACT_SETTINGS")
    if override:
        candidates = [Path(override)]
    else:
        home = passwd_home()
        candidates = [
            home / ".claude" / "settings.json",
            home / ".claude" / "settings.local.json",
        ]
        if cwd:
            candidates.append(Path(cwd) / ".claude" / "settings.json")
            candidates.append(Path(cwd) / ".claude" / "settings.local.json")
    for path in candidates:
        configured = _read_json(path).get("model")
        if isinstance(configured, str) and "[1m]" in configured:
            return True
    return False


def context_limit(
    model: str | None,
    observed_tokens: int = 0,
    cwd: str = "",
    declared_window: int = 0,
) -> int:
    """Usable context window in tokens.

    Codex states the window on the same event it reports usage on, and that
    number arrives here as ``declared_window``. Claude states nothing: hook
    stdin carries no context-usage field and a plugin cannot ship a statusLine,
    so on that host the window has to be inferred from what is on disk. The
    model id is NOT usable for that -- a wide-window session records plain
    ``claude-opus-5`` with no ``[1m]`` marker, so trusting it would under-read
    the window by 5x and fire on nearly every turn.

    Precedence, highest first:

    1. ``SDP_PRECOMPACT_CONTEXT_TOKENS`` -- this plugin's own override, the
       documented escape hatch on either host.
    2. ``declared_window`` -- a window the host stated for the request just
       measured. Everything below it is guesswork by comparison.
    3. ``CLAUDE_CODE_MAX_CONTEXT_TOKENS`` -- Claude Code's own override. Below
       the declared window on purpose: exported into a Codex session it must
       not decide that session's window.
    4. The largest occupancy this session has actually reached, which cannot
       lie about being at least that wide.
    5. A configured ``[1m]`` model, from the environment or a settings file.
    6. The narrow default.
    """
    explicit = explicit_window()
    if explicit is not None:
        return explicit
    # A window the host stated for the request just measured. Nothing below can
    # improve on it, and everything below is guesswork by comparison.
    if declared_window > 0:
        return declared_window
    host = claude_host_window()
    if host is not None:
        return host
    # Self-calibration. Occupancy already past the narrow window is proof of a
    # wide one, whatever the model id claims.
    if observed_tokens > DEFAULT_CONTEXT_TOKENS * 0.98:
        return WIDE_CONTEXT_TOKENS
    if model and "[1m]" in model:
        return WIDE_CONTEXT_TOKENS
    if _settings_says_wide(cwd):
        return WIDE_CONTEXT_TOKENS
    return DEFAULT_CONTEXT_TOKENS


def _tail_lines(path: Path, max_bytes: int = 2_000_000) -> list[str]:
    try:
        st = os.lstat(path)
    except OSError:
        return []
    if not stat.S_ISREG(st.st_mode):
        return []
    try:
        with open(path, "rb") as fh:
            if st.st_size > max_bytes:
                fh.seek(st.st_size - max_bytes)
                fh.readline()  # drop the partial line
            blob = fh.read()
    except OSError:
        return []
    return blob.decode("utf-8", "replace").splitlines()


def _codex_model(record: dict) -> str:
    """The model Codex states for a turn, or "".

    Codex never puts the model on the usage event the occupancy comes from, so
    reading it there yields "" -- which is what shipped first, and what made
    the cycle ledger unable to separate one host's samples from another's. It
    is stated on its own records instead, and the newest one wins because the
    reverse scan reaches it first.
    """
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return ""
    if payload.get("type") == "thread_settings_applied":
        settings = payload.get("thread_settings")
        if isinstance(settings, dict):
            model = settings.get("model")
            if isinstance(model, str) and model:
                return model
    if record.get("type") == "turn_context":
        model = payload.get("model")
        if isinstance(model, str) and model:
            return model
    return ""


def _codex_usage(record: dict) -> tuple[int, int]:
    """Occupancy and declared window from one Codex rollout line.

    Codex writes ``{"type":"event_msg","payload":{"type":"token_count", ...}}``.
    Inside ``payload.info``, ``last_token_usage.input_tokens`` is the prompt
    size for the most recent request -- the resident context, cached portion
    included. ``total_token_usage`` is the cumulative bill for the session and
    reaches millions; using it would read every session as instantly full.
    ``model_context_window`` states the window outright.

    This shape is not a documented interface and can change with the CLI. It is
    read defensively and pinned by a recorded fixture in tests/precompact.sh;
    if it ever stops matching, measurement degrades to zero rather than lying,
    and the hook simply never fires on that host.
    """
    if record.get("type") != "event_msg":
        return (0, 0)
    payload = record.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return (0, 0)
    info = payload.get("info")
    if not isinstance(info, dict):
        return (0, 0)
    last = info.get("last_token_usage")
    used = 0
    if isinstance(last, dict):
        try:
            used = int(last.get("input_tokens") or 0)
        except (TypeError, ValueError):
            used = 0
    try:
        window = int(info.get("model_context_window") or 0)
    except (TypeError, ValueError):
        window = 0
    return (used, window)


def measure_context(
    transcript_path: str | None, cwd: str = ""
) -> tuple[float, int, int, str | None, bool]:
    """Return (pct, used_tokens, limit, model, exact) from the newest usage record.

    ``exact`` is True when ``limit`` is a window the host stated for this
    measurement rather than one inferred from history. Callers use it to skip
    the sticky window, which has nothing to add to a number the host reported.

    Two transcript formats, because the plugin runs on two hosts. Claude writes
    per-assistant-message ``message.usage``, where occupancy is
    input + cache_creation + cache_read (output tokens are not resident) and
    the window is never stated. Codex writes ``token_count`` events carrying
    both the occupancy and the window.

    The Codex window is read from the SAME event as the occupancy, never as the
    largest window seen. A session can change model mid-flight, and taking the
    widest window ever reported alongside the newest usage divides the two by
    each other: 210k of a 258400 window reads as 21% instead of 81%, and the
    snapshot is never requested. Pairing them is the whole point.

    Neither format is a stable interface; both are read defensively so an
    unrecognised line measures nothing rather than measuring wrong.
    """
    # Cleared on entry, not only on the success path. Two of the three returns
    # below are failures, and a failure that leaves the previous call's host in
    # place makes the NEXT cycle row claim a host this measurement never read.
    _LAST_MEASURE["host"] = ""
    if not transcript_path:
        return (0.0, 0, DEFAULT_CONTEXT_TOKENS, None, False)

    latest_used: int | None = None
    latest_model: str | None = None
    codex_model: str | None = None
    codex_seen = False
    peak_used = 0
    declared_window = 0

    # Reverse order so the newest usable record is found first, but keep
    # scanning: the peak occupancy over the whole tail is what calibrates the
    # window, and it is the only signal that cannot be wrong by 5x.
    for line in reversed(_tail_lines(Path(transcript_path))):
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        # Codex rollout
        codex_used, codex_window = _codex_usage(record)
        if codex_used:
            codex_seen = True
            if codex_used > peak_used:
                peak_used = codex_used
            if latest_used is None:
                # Newest usable event wins, and its window comes with it.
                latest_used = codex_used
                declared_window = codex_window
            continue
        stated = _codex_model(record)
        if stated:
            codex_seen = True
            if codex_model is None:
                codex_model = stated
            continue
        # A recorded compaction states exactly how much context was resident at
        # the moment it fired. That is the strongest window evidence available
        # and it survives the compaction itself, unlike the usage records.
        meta = record.get("compactMetadata")
        if isinstance(meta, dict):
            try:
                pre = int(meta.get("preTokens") or 0)
            except (TypeError, ValueError):
                pre = 0
            if pre > peak_used:
                peak_used = pre
        if record.get("type") != "assistant":
            continue
        # A subagent's turns are recorded on the same transcript. Their usage
        # is the SUBAGENT's context, not the main thread's, so counting them
        # would read the wrong conversation.
        if record.get("isSidechain"):
            continue
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        usage = message.get("usage")
        if not isinstance(usage, dict):
            continue
        used = 0
        for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
            try:
                used += int(usage.get(key) or 0)
            except (TypeError, ValueError):
                pass
        model = message.get("model")
        model = model if isinstance(model, str) else None
        # API errors and interrupts are recorded as assistant turns with a
        # "<synthetic>" model and all-zero usage. Reading one as the current
        # occupancy would report an empty context.
        if model == "<synthetic>" or used == 0:
            continue
        if used > peak_used:
            peak_used = used
        if latest_used is None:
            latest_used = used
            latest_model = model

    if latest_used is None:
        # A rollout whose records were all unusable still identifies its host,
        # and saying so is more useful than saying nothing.
        _LAST_MEASURE["host"] = "codex" if codex_seen else ""
        return (0.0, 0, DEFAULT_CONTEXT_TOKENS, None, False)

    if latest_model is None and codex_model:
        latest_model = codex_model
    limit = context_limit(latest_model, peak_used, cwd, declared_window)
    exact = declared_window > 0 and limit == declared_window
    pct = (latest_used / limit * 100.0) if limit > 0 else 0.0
    _LAST_MEASURE["host"] = "codex" if codex_seen else "claude"
    return (pct, latest_used, limit, latest_model, exact)


# Which transcript format the last measurement actually parsed. A side channel
# rather than a sixth element because measure_context's tuple is read in a dozen
# places and every one of them would have to change to carry a field only the
# ledger wants. Overwritten on each call and read immediately after one.
_LAST_MEASURE: dict = {"host": ""}


def measured_host() -> str:
    """The host whose format the last ``measure_context`` call read, or "".

    Not a guess from the environment: an agent can run either CLI, and the
    transcript format is the only thing that states which conversation is being
    measured. Cycle rows that cannot say this are useless for a per-host
    threshold, which is the entire reason the ledger exists.
    """
    return _LAST_MEASURE.get("host") or ""


# --------------------------------------------------------------------------
# snapshot discovery
# --------------------------------------------------------------------------


# What ensure_day_dir found. Three states, not two: "could not create it" and
# "refused to create it" call for opposite instructions, and collapsing them is
# how a path that was rejected for following a symlink gets handed back to the
# model with permission to mkdir it.
DAY_DIR_READY = "ready"
# Named for what is known, not for what is hoped. SDP did not create the
# directory and nothing here establishes that the caller can either: the same
# value comes back for a cwd that does not exist, a read-only filesystem and a
# parent the process cannot write to (reproduced with `chmod 0500`). Calling it
# "creatable" promised a mkdir would work, which sends a turn with no budget
# left into retrying one that already failed.
DAY_DIR_RETRYABLE = "retryable"
DAY_DIR_UNSAFE = "unsafe"


def ensure_day_dir(cwd: str | None, today: str) -> str:
    """Create ``<cwd>/.private/precompact/<today>``, or say why not.

    The automated path forbids every preparation command, including ``mkdir``.
    On the first snapshot of a day the directory does not exist yet, so without
    this the model is left with a contradiction: write a file into a directory
    it is not allowed to create. It would either fail the write or disobey --
    and the whole point of the fast-path is that it has no budget for either.

    Returns ``DAY_DIR_READY`` when the directory is there,
    ``DAY_DIR_UNSAFE`` when a component exists but is not a plain directory in
    this workspace -- a symlink or junction, or a file or other object sitting
    on the name -- and ``DAY_DIR_RETRYABLE`` for everything else.

    ``DAY_DIR_RETRYABLE`` means only that nothing unsafe was found and SDP did
    not create the directory. It does NOT mean a ``mkdir`` will succeed: an
    absent cwd, a read-only filesystem and an unwritable parent all land here
    too. The caller may attempt it once and must treat a failure as final,
    because the turn that receives this has no budget for a second attempt.

    The last one is not a milder version of the second, which is why they are
    separate values. A reparse point here resolves somewhere else and the
    snapshot is read back into the next context, so telling the model "create
    it yourself" would walk it straight through the link this function just
    refused, turning a control into an instruction to bypass it. A plain file
    on the name is not an escape, but ``mkdir`` cannot fix it either, so the
    same refusal is the right answer.

    Every component is created and validated individually. ``parents=True``
    would walk through a planted symlink without ever looking at it, and an
    earlier revision that started at ``.private/precompact`` rather than at
    ``.private`` failed outright on every project whose ``.private`` did not
    exist yet.
    """
    if not cwd or not today:
        return DAY_DIR_RETRYABLE
    try:
        root = Path(cwd)
        if not root.is_dir():
            return DAY_DIR_RETRYABLE
    except (OSError, ValueError):
        return DAY_DIR_RETRYABLE

    base = root / SNAPSHOT_SUBDIR
    chain = [root / SNAPSHOT_SUBDIR.parts[0]]
    for part in SNAPSHOT_SUBDIR.parts[1:]:
        chain.append(chain[-1] / part)
    chain.append(base / today)

    for part in chain:
        try:
            existed = part.exists()
        except OSError:
            return DAY_DIR_RETRYABLE
        if not existed:
            try:
                part.mkdir(mode=0o700)
            except FileExistsError:
                pass  # a concurrent session got there first; validate it below
            except OSError:
                return DAY_DIR_RETRYABLE
        # Validated whether it was found or just made: a component created a
        # moment ago can still have been swapped, and the check is cheap.
        try:
            win_compat.reject_reparse_chain(root, part)
        except OSError:
            return DAY_DIR_UNSAFE
        except (ValueError, RuntimeError):
            return DAY_DIR_UNSAFE
        try:
            if not part.is_dir():
                return DAY_DIR_UNSAFE
        except OSError:
            return DAY_DIR_RETRYABLE
    return DAY_DIR_READY


def list_snapshots(cwd: str | None) -> list:
    """Every ``precompact_*.md`` under ``<cwd>/.private/precompact``, as (path, mtime).

    Symlinks are refused outright: a link named ``precompact_x.md`` would
    otherwise be resolved into the injected resume text and point anywhere.
    """
    found = []
    if not cwd:
        return found
    base = Path(cwd) / SNAPSHOT_SUBDIR
    if not base.is_dir():
        return found
    # The leaf lstat below is not enough: a symlink or junction at .private/precompact
    # or at a day directory is followed by iterdir(), so snapshots from outside the
    # workspace would be injected into the resume text. Not Windows-only -- a POSIX
    # symlinked day directory does the same.
    try:
        win_compat.reject_reparse_chain(Path(cwd), base)
    except OSError:
        return found
    try:
        day_dirs = sorted(base.iterdir())
    except OSError:
        return found
    for day_dir in day_dirs:
        if not day_dir.is_dir():
            continue
        try:
            win_compat.reject_reparse_chain(base, day_dir)
        except OSError:
            continue
        try:
            entries = sorted(day_dir.iterdir())
        except OSError:
            continue
        for entry in entries:
            name = entry.name.casefold()
            if not name.startswith(SNAPSHOT_PREFIX) or not name.endswith(".md"):
                continue
            try:
                st = os.lstat(entry)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            found.append((str(entry.resolve()), st.st_mtime))
    return found


def find_snapshot(
    cwd: str | None,
    not_before: float,
    tag: str = "",
    exclude: object = None,
    allow_recency: bool = False,
) -> str | None:
    """The snapshot THIS session wrote, or nothing.

    An mtime floor alone is not binding: two sessions working in one directory
    both write into it, and the newest file is as likely to be the other
    session's. So, strongest test first.

    1. The session tag in the filename, which the block reason asks for.
    2. Novelty. A candidate is this session's if its name was absent from
       ``exclude``, the inventory taken before this session wrote anything.
       That inventory is carried forward across repeated blocks, so a file the
       model updates in place on a later cycle stays novel. ``exclude`` of
       ``None`` means no trustworthy inventory exists, so novelty proves
       nothing and is skipped rather than treated as satisfied by everything.
       Novelty must also be UNAMBIGUOUS: two sessions that each write a new
       file are both novel, and picking the newer one is the exact wrong-work
       resume this function exists to prevent. Note that mtime cannot stand in
       here -- an overwrite and a touched foreign file look identical.
    3. Recency, only where the caller allows it and only when unambiguous.
    4. Otherwise nothing. Reporting a missing snapshot is recoverable; silently
       resuming someone else's work is not.
    """
    candidates = [
        (path, mtime) for path, mtime in list_snapshots(cwd) if mtime >= not_before
    ]
    if not candidates:
        return None
    if tag:
        tagged = [c for c in candidates if tag in Path(c[0]).name.casefold()]
        if tagged:
            return max(tagged, key=lambda c: c[1])[0]
    if exclude is not None:
        fresh = [c for c in candidates if Path(c[0]).name not in exclude]
        if len(fresh) == 1:
            return fresh[0][0]
        return None
    if allow_recency and len(candidates) == 1:
        return candidates[0][0]
    return None


# --------------------------------------------------------------------------
# terminal driver (optional)
# --------------------------------------------------------------------------


def orca_bin() -> str:
    """Resolve the terminal driver exactly once, by the driver's own rule.

    The rule is the driver's, not ours, and it is not a search: pick one name
    and use it. Falling through a candidate list is explicitly forbidden --
    it can silently target a different build.

    The name matters most on Linux. Outside a driver-managed terminal a bare
    ``orca`` normally resolves to ``/usr/bin/orca``, which is the GNOME screen
    reader; sending it terminal commands starts speech on the user's machine.
    This ships to other people's laptops, so that path is never taken.
    """
    override = os.environ.get("ORCA_CLI_COMMAND")
    if override:
        # May carry arguments, not just a name.
        return override
    if os.environ.get("ORCA_DEV_REPO_ROOT"):
        return "orca-dev"
    if sys.platform.startswith("linux") and not os.environ.get("ORCA_PANE_KEY"):
        # Managed terminals export the pane key; without it this is "Linux
        # outside a managed terminal", where bare orca is the screen reader.
        return "orca-ide"
    return "orca"


def match_handle(terminals: object, pane_key: str) -> str:
    """The live handle for a pane key, or "" when it is not unambiguous.

    The pane key is ``<tabId>:<leafId>`` and survives; the PTY handle does not
    -- it rotates and dies across a compaction, which is precisely when this is
    needed. So the handle is re-resolved every time rather than remembered.

    Zero rows means the pane is gone, two means it cannot be told apart, and
    both refuse. There is deliberately no fall back to "most recently active"
    or "the one in this worktree": a wrong guess types into somebody else's
    session, which is worse than not typing at all.

    ``leafId`` may itself contain colons, so the split is on the first one.
    """
    if not pane_key:
        return ""
    tab_id, sep, leaf_id = pane_key.partition(":")
    if not sep or not tab_id or not leaf_id:
        return ""
    rows = [
        row
        for row in (terminals if isinstance(terminals, list) else [])
        if isinstance(row, dict)
        and row.get("connected") is True
        and row.get("tabId") == tab_id
        and row.get("leafId") == leaf_id
    ]
    if len(rows) != 1:
        return ""
    handle = rows[0].get("handle")
    return handle if isinstance(handle, str) else ""


def driver_argv(args: list) -> list:
    """The full argv for a driver call, or [] when the driver is unusable.

    The resolved value may be a command line rather than a bare name, so it is
    split as one; the first word is what has to exist.
    """
    resolved = orca_bin()
    if not resolved:
        return []
    try:
        if os.name == "nt":
            # POSIX splitting eats backslashes as escapes, so a Windows path
            # like C:\Tools\orca.exe --flag comes back as C:Toolsorca.exe.
            # Non-POSIX mode keeps them, but leaves any wrapping quotes on.
            prefix = [w[1:-1] if len(w) > 1 and w[0] == w[-1] == '"' else w
                      for w in shlex.split(resolved, posix=False)]
        else:
            prefix = shlex.split(resolved)
    except ValueError:
        return []
    if not prefix:
        return []
    head = prefix[0]
    if not shutil.which(head) and not Path(head).is_file():
        return []
    return prefix + args


def _orca_json(args: list, timeout_sec: float = 10.0) -> object:
    argv = driver_argv(args)
    if not argv:
        return None
    try:
        done = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout_sec, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        return json.loads(done.stdout)
    except ValueError:
        return None


def resolve_handle(pane_key: str) -> str:
    data = _orca_json(["terminal", "list", "--json"])
    if not isinstance(data, dict):
        return ""
    result = data.get("result")
    terminals = result.get("terminals") if isinstance(result, dict) else None
    return match_handle(terminals, pane_key)


_SUBMIT_PROOF_SUPPORTED = None


def driver_proves_submission() -> bool:
    """Whether this driver can be ASKED for submission proof, decided without typing.

    Round-2 review F1: the first cut learned this from a refused send and then
    retried without the flag. That reads a failure as proof that nothing was
    typed, which the driver's contract nowhere guarantees -- a failure AFTER the
    keystrokes landed would have retyped the prompt. The capability is a property
    of the binary, so it is read from the binary: `terminal send --help` names its
    own flags and types nothing anywhere. Cached, because it cannot change under
    a running process.
    """
    global _SUBMIT_PROOF_SUPPORTED
    if _SUBMIT_PROOF_SUPPORTED is not None:
        return _SUBMIT_PROOF_SUPPORTED
    argv = driver_argv(["terminal", "send", "--help"])
    if not argv:
        _SUBMIT_PROOF_SUPPORTED = False
        return False
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=15, check=False)
    except (OSError, subprocess.SubprocessError):
        # Unknown, not absent. Fail toward "cannot prove", which downgrades a send
        # to unverified rather than inventing a proof.
        _SUBMIT_PROOF_SUPPORTED = False
        return False
    _SUBMIT_PROOF_SUPPORTED = "--wait-submit" in ((done.stdout or "") + (done.stderr or ""))
    return _SUBMIT_PROOF_SUPPORTED


def _send_once(
    handle: str, text: str, observe_sec: int, retry_request: str = ""
) -> tuple[object, int]:
    """One driver send (or one replay of an earlier one). Returns (json, rc).

    ``retry_request`` replays the receipt of a request already accepted; it does
    NOT type the text again. That is the only sanctioned way to learn whether a
    prompt the driver could not prove has since started its turn.
    """
    args = ["terminal", "send", "--terminal", handle, "--text", text, "--enter", "--json"]
    if observe_sec > 0:
        args += ["--wait-submit", str(int(observe_sec))]
    if retry_request:
        args += ["--retry-request", retry_request]
    argv = driver_argv(args)
    if not argv:
        return None, -1
    try:
        done = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=observe_sec + SUBMIT_SUBPROCESS_SLACK_SEC,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None, -1
    try:
        return json.loads(done.stdout), done.returncode
    except ValueError:
        return None, done.returncode


def _receipt_fields(data: object) -> dict:
    result = data.get("result") if isinstance(data, dict) else None
    send = result.get("send") if isinstance(result, dict) else None
    prompt = send.get("prompt") if isinstance(send, dict) else None
    prompt = prompt if isinstance(prompt, dict) else {}
    stages = prompt.get("stages")
    warnings = result.get("warnings") if isinstance(result, dict) else None
    return {
        "accepted": (send or {}).get("accepted") if isinstance(send, dict) else None,
        "stages": [s for s in stages if isinstance(s, str)] if isinstance(stages, list) else [],
        "provider": prompt.get("provider") if isinstance(prompt.get("provider"), str) else "",
        "observation": prompt.get("observation") if isinstance(prompt.get("observation"), str) else "",
        "request_id": prompt.get("requestId") if isinstance(prompt.get("requestId"), str) else "",
        "warnings": [w for w in warnings if isinstance(w, str)] if isinstance(warnings, list) else [],
    }


def send_prompt(
    handle: str, text: str, observe_sec: int = SUBMIT_OBSERVE_SEC
) -> tuple[str, dict]:
    """Type text into a terminal and establish whether it actually SUBMITTED.

    ``--enter`` is not optional: without it the text lands in the input box and
    sits there unsent. What this function adds is that ``--enter`` alone does not
    prove the Enter took. The driver reports acceptance and submission as separate
    stages and exits 0 for both, so the old ``returncode == 0`` test called a
    stranded prompt a success -- the composer kept "/compact", nothing ran, and the
    cycle died without a trace.

    Outcomes, and why they are four and not two:

    * ``SEND_PROVEN`` -- the receipt carries ``turn_started``.
    * ``SEND_LEGACY`` -- an agent target whose turn start this driver cannot watch
      (an older host). No proof is obtainable, so the caller proceeds, but the
      record says unverified rather than success.
    * ``SEND_REJECTED`` -- refused before any input, or a target that is not an
      agent TUI at all. Nothing was typed.
    * ``SEND_UNPROVEN`` -- accepted, not proven, including every ambiguous
      failure. The text may be sitting in the composer. The caller must NOT send
      it again; re-sending on silence is what double-submits.
    """
    info = {"provider": "", "observation": "", "stages": [], "request_id": "",
            "warnings": [], "detail": ""}
    if not handle:
        info["detail"] = "no terminal handle"
        return SEND_REJECTED, info

    # Round-2 review F1: whether proof can be asked for is settled BEFORE any
    # keystroke, so no failure is ever interpreted as "nothing was typed".
    provable = driver_proves_submission()
    data, rc = _send_once(handle, text, observe_sec if provable else 0)

    # Round-2 review F2: missing evidence is never promoted. Only two facts can
    # be read affirmatively -- a refusal the driver states (`accepted: false`),
    # and a turn it observed (`turn_started`). Everything else is UNPROVEN, which
    # stops the cycle and forbids a second send.
    if not isinstance(data, dict):
        info["detail"] = "no parseable receipt from the driver (rc=%s)" % rc
        return SEND_UNPROVEN, info
    fields = _receipt_fields(data)
    info.update(fields)
    if fields["accepted"] is False:
        info["detail"] = "the driver refused the input; nothing was typed"
        return SEND_REJECTED, info
    if data.get("ok") is not True or fields["accepted"] is not True:
        # A failure that names no acceptance says nothing about the keystrokes.
        info["detail"] = "the driver reported no accepted input (rc=%s)" % rc
        return SEND_UNPROVEN, info
    if "turn_started" in fields["stages"]:
        return SEND_PROVEN, info
    if fields["provider"] not in AGENT_PROVIDERS:
        # Not an agent TUI -- on a shell "/compact" is a command line, so this is
        # the wrong target. It is UNPROVEN and not REJECTED because the input WAS
        # accepted: something was typed there, and it must not be typed again.
        info["detail"] = "target provider %r is not an agent TUI" % (fields["provider"],)
        return SEND_UNPROVEN, info
    if not provable or fields["observation"] == "unsupported":
        # Affirmatively unobservable: an agent target on a host that cannot watch
        # a turn start. Proceed, recorded as unverified -- never as proof.
        info["detail"] = "this driver cannot observe submission; proceeding unverified"
        return SEND_LEGACY, info
    if fields["observation"] != "supported":
        info["detail"] = "receipt carries no observation status"
        return SEND_UNPROVEN, info

    # Accepted but unproven on a driver that CAN prove it. Re-observe the same
    # request once. This replays that receipt; it types nothing.
    if fields["request_id"]:
        again, _rc = _send_once(handle, text, SUBMIT_REOBSERVE_SEC, fields["request_id"])
        if isinstance(again, dict):
            second = _receipt_fields(again)
            info.update(second)
            # Round-3 review F2: the replay is judged by the SAME evidence rule as
            # the first receipt. A replay that carries `turn_started` while stating
            # `accepted: false` contradicts itself, and a contradiction proves
            # nothing -- it must not become a stronger verdict than the receipt it
            # replays. Acceptance itself is not re-demanded: the first receipt
            # established it, and the replay need not restate it.
            if (
                again.get("ok") is True
                and second["accepted"] is not False
                and "turn_started" in second["stages"]
            ):
                return SEND_PROVEN, info
    info["detail"] = "accepted, but no turn start was observed"
    return SEND_UNPROVEN, info


def send_text(handle: str, text: str) -> bool:
    """Boolean wrapper for callers that only need go/no-go.

    True means the turn started, or that this host cannot prove it either way.
    Everything else -- stranded in the composer, refused, ambiguous -- is False.
    """
    status, _info = send_prompt(handle, text)
    return status in (SEND_PROVEN, SEND_LEGACY)


def wait_tui_idle(handle: str, timeout_ms: int = INJECT_IDLE_TIMEOUT_MS) -> bool:
    """Block until the session is genuinely idle, or give up.

    The driver exposes this directly, which is the only reliable way to ask.
    Reading the screen does not answer it: the host renders an input box for
    the whole of a running turn, so an empty-looking composer says nothing
    about whether the agent is still working -- and typing on that evidence
    steers the turn in progress instead of starting a new one.

    Judged on the JSON, not the exit status: a timeout is reported as
    ``ok: false`` with ``code: timeout``, and the process exit code is not a
    dependable stand-in for that across hosts.
    """
    if not handle:
        return False
    # Outlive the wait the CLI was asked for; killing it early would report a
    # busy session as merely unreadable and, worse, cap the contract at the
    # subprocess default rather than the requested window.
    deadline = time.monotonic() + (timeout_ms / 1000.0)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        remaining_ms = max(1, int(remaining * 1000))
        data = _orca_json(
            ["terminal", "wait", "--terminal", handle,
             "--for", "tui-idle", "--timeout-ms", str(remaining_ms), "--json"],
            timeout_sec=remaining + 15.0,
        )
        # Every one of these must be present and correct. Accepting a bare
        # ``ok: true``, or a reply with no wait block, treats "I could not tell"
        # as "idle" -- which is the one direction that types into a running turn.
        if not isinstance(data, dict) or data.get("ok") is not True:
            return False
        result = data.get("result")
        if not isinstance(result, dict):
            return False
        wait = result.get("wait")
        if not isinstance(wait, dict):
            return False
        if wait.get("condition") != "tui-idle" or wait.get("handle") != handle:
            return False
        if wait.get("satisfied") is True:
            return True
        # Orca can return this transient state immediately while Codex is
        # changing turns. It is not idle and must never authorize a send, but
        # it also must not collapse a bounded wait into an immediate give-up.
        if wait.get("blockedReason") != "codex-interactive-prompt":
            return False
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(1.0, remaining))


def codex_rollout_watermark(session_id: str) -> tuple[str, int] | None:
    """Locate this Codex session's rollout and capture its current end.

    A Codex slash command is not a model prompt. Orca therefore reports
    ``tui-idle`` throughout ``/compact`` and cannot tell the detached waiter
    when it is safe to submit the resume prompt. The rollout records the real
    lifecycle. Exactly one regular file inside the passwd-owned Codex sessions
    directory must match; ambiguity fails closed.
    """
    safe = _safe_session(session_id)
    if not safe or safe != session_id:
        return None
    try:
        root = (passwd_home() / ".codex" / "sessions").resolve(strict=True)
    except (OSError, RuntimeError):
        return None
    matches = []
    try:
        candidates = root.glob("*/*/*/rollout-*-%s.jsonl" % safe)
        for path in candidates:
            if path.is_symlink():
                continue
            resolved = path.resolve(strict=True)
            resolved.relative_to(root)
            st = resolved.stat()
            if stat.S_ISREG(st.st_mode):
                matches.append((resolved, st.st_size))
    except (OSError, RuntimeError, ValueError):
        return None
    if len(matches) != 1:
        return None
    path, size = matches[0]
    return str(path), size


def wait_codex_compaction_complete(
    path_text: str, offset: int, timeout_sec: float = CODEX_COMPACT_TIMEOUT_SEC
) -> bool:
    """Wait for a new Codex ``compacted`` lifecycle and its task completion."""
    try:
        path = Path(path_text)
        if path.is_symlink() or not path.is_file() or offset < 0:
            return False
        stream = path.open("rb")
    except (OSError, ValueError):
        return False

    deadline = time.monotonic() + timeout_sec
    pending = b""
    saw_compacted = False
    try:
        if path.stat().st_size < offset:
            return False
        stream.seek(offset)
        while time.monotonic() < deadline:
            chunk = stream.read()
            if chunk:
                pending += chunk
                lines = pending.split(b"\n")
                pending = lines.pop()
                for raw in lines:
                    try:
                        event = json.loads(raw)
                    except (UnicodeDecodeError, ValueError):
                        continue
                    if not isinstance(event, dict):
                        continue
                    if event.get("type") == "compacted":
                        saw_compacted = True
                        continue
                    payload = event.get("payload")
                    if (
                        saw_compacted
                        and event.get("type") == "event_msg"
                        and isinstance(payload, dict)
                        and payload.get("type") == "task_complete"
                    ):
                        return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(CODEX_COMPACT_POLL_SEC, remaining))
    except OSError:
        return False
    finally:
        stream.close()
    return False


def driver_ready(pane_key: str = "") -> bool:
    """Whether typing into this session's own input box is possible at all."""
    key = pane_key or os.environ.get("ORCA_PANE_KEY") or ""
    return bool(key) and bool(orca_bin())


def intent_path(session_id: str) -> Path:
    return state_dir() / (_safe_session(session_id) + ".selffire.json")


def set_self_fire_intent(session_id: str, pane_key: str, snapshot: str = "") -> str:
    """Record that THIS cycle asked for the compaction itself.

    The resume injection is keyed off this, not off the global mode. Mode says
    whether detection may fire at all; it says nothing about whether the user
    asked, this once, for the whole cycle to run unattended. Binding to the
    mode gets both halves wrong: an automatic compaction already continues the
    turn on its own, so injecting there produces a second one, while a user who
    runs the command by hand in manual mode gets no injection at all -- which
    is precisely the case that wanted it.
    """
    nonce = uuid.uuid4().hex
    written = _write_json(
        intent_path(session_id),
        {"pane_key": pane_key, "at": time.time(), "nonce": nonce,
         "snapshot": snapshot},
    )
    return nonce if written else ""


def take_self_fire_intent(session_id: str) -> str:
    """Consume the intent, returning the pane it named. One shot."""
    if not session_id:
        return ""
    record = _read_json(intent_path(session_id))
    try:
        os.unlink(intent_path(session_id))
    except OSError:
        pass
    pane_key = record.get("pane_key")
    if not isinstance(pane_key, str) or not pane_key:
        return ""
    try:
        at = float(record.get("at") or 0)
    except (TypeError, ValueError):
        return ""
    now = time.time()
    if at > now + 60 or (now - at) > SELF_FIRE_INTENT_TTL_SEC:
        return ""
    return pane_key


def peek_self_fire_intent(session_id: str, nonce: str = "") -> str:
    """Is the intent still live, without consuming it.

    A nonce pins the answer to ONE queued compaction. Without it two waiters
    started by two calls would both see "an intent exists" and both send, which
    compacts twice.
    """
    if not session_id:
        return ""
    record = _read_json(intent_path(session_id))
    if nonce and record.get("nonce") != nonce:
        return ""
    pane_key = record.get("pane_key")
    if not isinstance(pane_key, str) or not pane_key:
        return ""
    try:
        at = float(record.get("at") or 0)
    except (TypeError, ValueError):
        return ""
    now = time.time()
    if at > now + 60 or (now - at) > SELF_FIRE_INTENT_TTL_SEC:
        return ""
    return pane_key


def clear_self_fire_intent(session_id: str, nonce: str = "") -> None:
    """Release an intent. With a nonce, only if it is still that same one.

    A waiter that gives up late must not delete a NEWER cycle's intent: the
    host may have compacted on its own, a fresh cycle may have queued another
    compaction, and an unscoped unlink would silently disarm it.
    """
    if not session_id:
        return
    if nonce and _read_json(intent_path(session_id)).get("nonce") != nonce:
        return
    try:
        os.unlink(intent_path(session_id))
    except OSError:
        pass


def mark_resume_dispatching(session_id: str, nonce: str) -> bool:
    """Tell ``hook_resume`` the detached Codex waiter owns the next send."""
    if not peek_self_fire_intent(session_id, nonce):
        return False
    record = _read_json(intent_path(session_id))
    if record.get("nonce") != nonce:
        return False
    record["resume_dispatching"] = True
    return _write_json(intent_path(session_id), record)


def submit_path(session_id: str) -> Path:
    return state_dir() / (_safe_session(session_id) + ".submit.json")


def _clip(value: object, limit: int) -> str:
    """One bounded, control-free line. Diagnostics must not grow without limit.

    Round-3 review: "control-free" has to mean C1 as well as C0. `str.split()`
    does not treat U+0080-U+009F as whitespace, so a warning written by another
    process could carry a CSI byte straight through this record and into the
    terminal that `doctor` prints to.
    """
    text = value if isinstance(value, str) else ""
    flat = "".join(
        " " if (ch < " " or "\x7f" <= ch <= "\x9f") else ch for ch in text
    )
    return " ".join(flat.split())[:limit]


def note_submission(
    session_id: str, nonce: str, prompt: str, status: str, info: dict,
    disposition: str = "",
) -> None:
    """Leave a durable, bounded record of what a send actually established.

    The defect this feature hit was invisible: the prompt sat in the composer,
    every exit status was 0, and nothing anywhere said so. Rounds 1-2 of the
    review add two constraints. Every field is CAPPED -- warnings are written by
    another process and are not a place to store unbounded text. And the record
    carries the DISPOSITION that was actually taken, because `doctor` must report
    what happened rather than a sentence chosen at write time: an unproven send
    may release the intent or keep it, and a legacy send proceeds.
    """
    if not session_id:
        return
    stages = info.get("stages")
    stages = [s for s in stages if isinstance(s, str)][:6] if isinstance(stages, list) else []
    warnings = info.get("warnings")
    warnings = warnings if isinstance(warnings, list) else []
    _write_json(
        submit_path(session_id),
        {
            "at": time.time(),
            "nonce": _clip(nonce, 64),
            "prompt": _clip(prompt, 60),
            "status": _clip(status, 32),
            "disposition": _clip(disposition, 80),
            "provider": _clip(info.get("provider"), 32),
            "observation": _clip(info.get("observation"), 32),
            "stages": [_clip(s, 32) for s in stages],
            "request_id": _clip(info.get("request_id"), 64),
            "detail": _clip(info.get("detail"), 200),
            "warnings": [_clip(w, 200) for w in warnings[:2]],
        },
    )


def pane_path(session_id: str) -> Path:
    return state_dir() / (_safe_session(session_id) + ".pane.json")


def bind_pane(session_id: str) -> bool:
    """Record which pane this session is displayed in.

    Hooks can see the pane key; the model's tool environment cannot. On one
    host the launcher's variables reach a tool unchanged, on the other the
    tool environment is rebuilt and the pane key is not in it -- so the tool
    cannot ask the environment where to type. A hook writes it down here, once
    per turn, and the tool looks it up by session id.
    """
    pane_key = os.environ.get("ORCA_PANE_KEY") or ""
    if not session_id or not pane_key:
        return False
    return _write_json(pane_path(session_id), {"pane_key": pane_key, "at": time.time()})


def bound_pane(session_id: str) -> str:
    """The pane this session was last seen in, if that is still trustworthy.

    Stale bindings are refused rather than used: a session can be moved to a
    different pane, and typing into where it used to be is the same mistake as
    guessing which pane to use.
    """
    if not session_id:
        return ""
    record = _read_json(pane_path(session_id))
    pane_key = record.get("pane_key")
    if not isinstance(pane_key, str) or not pane_key:
        return ""
    try:
        at = float(record.get("at") or 0)
    except (TypeError, ValueError):
        return ""
    now = time.time()
    if at > now + 60 or (now - at) > PANE_BINDING_MAX_AGE_SEC:
        return ""
    return pane_key


def tool_session_id() -> str:
    """This session's id, as seen from a tool rather than from a hook."""
    # Measured, not assumed: one host exports CLAUDE_CODE_SESSION_ID (equal to
    # the session id the hooks receive), the other CODEX_SESSION_ID.
    for name in ("CLAUDE_CODE_SESSION_ID", "CODEX_SESSION_ID", "CODEX_THREAD_ID"):
        value = os.environ.get(name)
        if value:
            return value
    return ""


def tool_pane_key() -> str:
    """The pane a tool should type into, or "" to refuse.

    Direct environment first, because where it is present it is current by
    construction. Otherwise the binding a hook recorded for this session.
    """
    direct = os.environ.get("ORCA_PANE_KEY") or ""
    if direct:
        return direct
    return bound_pane(tool_session_id())


# --------------------------------------------------------------------------
# marker state
# --------------------------------------------------------------------------


def _safe_session(session_id: str) -> str:
    return "".join(ch for ch in session_id if ch.isalnum() or ch in "-_")


def marker_path(session_id: str) -> Path:
    return state_dir() / (_safe_session(session_id) + ".json")


def window_path(session_id: str) -> Path:
    return state_dir() / (_safe_session(session_id) + ".window.json")


WINDOW_PRUNE_SEC = 7 * 24 * 3600
# Cycle ledger. Bounded so a long-lived home cannot grow it without limit;
# past the cap the append is skipped rather than rotated, because losing a
# measurement is cheaper than any failure mode of rotating under contention.
CYCLES_BASENAME = "precompact-cycles.ndjson"
MAX_CYCLE_ROW_BYTES = 4096
MAX_CYCLES_BYTES = 4 * 1024 * 1024
# How many measured snapshot turns are wanted before the Codex-side headroom
# is set from data rather than from the provisional value. Agreed with the
# Codex reviewer 2026-09-23; the statistic intended for it is
# p99(turn_cost_upper_bound) plus the larger of 25% and 2000 tokens.
CYCLES_FOR_THRESHOLD = 30
# Bumped whenever the meaning of a recorded field changes. Rows from an
# older revision are not comparable and must not be pooled with newer ones:
# a headroom fitted across a definition change is fitted to an artefact.
CYCLE_CONTRACT_REV = 2
# Files that sit beside a marker but are not one. doctor must not report
# them as pending snapshot requests, and the prune has to reach them or
# they accumulate one per session forever.
SIDECAR_SUFFIXES = (".window.json", ".pane.json", ".selffire.json", ".submit.json", ".run.json")


def sticky_window(session_id: str, inferred: int) -> int:
    """Remember the widest window this session has ever justified.

    Calibration reads the peak occupancy in the transcript TAIL, and after a
    compaction the surviving records are small. Once the pre-compact evidence
    scrolls out of the tail, a genuinely wide session would otherwise read as
    narrow again and block spuriously on the way back up. The window can only
    ever widen within a session.
    """
    explicit = explicit_window()
    if explicit is not None:
        return explicit
    path = window_path(session_id)
    previous = _read_json(path).get("limit")
    best = inferred
    if isinstance(previous, int) and previous > best:
        best = previous
    if best != previous:
        _write_json(path, {"limit": best, "at": time.time()})
        _prune_windows()
    else:
        # Keep the record young. Pruning is by mtime, and a long-lived session
        # that widened once on day one must not have its window pruned out from
        # under it and silently narrow back.
        try:
            os.utime(path, None)
        except OSError:
            pass
    return best


def _prune_windows() -> None:
    """Drop sidecar records for sessions that ended long ago."""
    cutoff = time.time() - WINDOW_PRUNE_SEC
    try:
        # unlink() below is destructive; re-check the exact directory enumerated.
        sdir = _assert_trusted(state_dir(), "state dir")
        entries = list(sdir.iterdir())
    except OSError:
        return
    for entry in entries:
        if not entry.name.endswith(SIDECAR_SUFFIXES):
            continue
        try:
            if entry.stat().st_mtime < cutoff:
                entry.unlink()
        except OSError:
            pass


def read_marker(session_id: str) -> dict:
    return _read_json(marker_path(session_id))


def marker_active(session_id: str) -> bool:
    """Whether THIS session is mid-compaction right now.

    Round-2 review F3: "a marker exists" is too weak to disarm a cycle on -- a
    finished or abandoned one leaves a record behind. Only the two in-flight
    states count as evidence that the compaction this waiter just asked for is
    under way.
    """
    return read_marker(session_id).get("state") in ("pending", "snapshotted")


def session_tag(session_id: str) -> str:
    """Short, filename-safe stamp the model appends to the snapshot name."""
    return (_safe_session(session_id)[:8] or "session").casefold()


def write_marker(session_id: str, payload: dict) -> bool:
    return _write_json(marker_path(session_id), payload)


def clear_marker(session_id: str) -> None:
    try:
        _assert_trusted(marker_path(session_id), "marker")
        os.unlink(marker_path(session_id))
    except OSError:
        pass


def marker_is_live(marker: dict, now: float) -> bool:
    """False when a marker is stale enough that detection should re-arm."""
    state = marker.get("state")
    try:
        at = float(marker.get("at") or 0)
    except (TypeError, ValueError):
        return False
    # A timestamp in the future never expires by subtraction, so a clock step
    # backwards would suppress detection for this session forever.
    if at > now + 60:
        return False
    if state == "pending":
        return (now - at) < PENDING_EXPIRY_SEC
    if state in ("snapshotted", "injected"):
        return (now - at) < REARM_SEC
    return False


# --------------------------------------------------------------------------
# hook entry points
# --------------------------------------------------------------------------


def read_hook_input() -> dict:
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        return {}
    try:
        data = json.loads(raw)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


# ------------------------------------------------------- run-continuation --
# Issue #5. In a DISPATCHED run no operator starts the next turn, so a turn that
# ends with "next I will ..." stalls the run until something outside nudges it.
# Prose did not hold (measured in the issue); this decision blocks such a stop
# at the moment it happens, keyed on state visible on disk -- never on the
# wording of the last message.
#
# Armed ONLY by a run record the dispatcher writes into the worker's worktree
# (`run arm`). Not by gates.yaml `mode: unattended`: that is the gate's override
# policy and also the built-in default, so keying on it would block every
# interactive session. Not by ~/.sdp/precompact.json either.

RUN_RECORD_REL = Path(".private") / "sdp-run.json"
RUN_RECORD_VERSION = 1
RUN_DISPATCH_KINDS = ("tmux", "orca", "manual")
# Below Claude Code's CLAUDE_CODE_STOP_HOOK_BLOCK_CAP default (8) so SDP decides
# before the host overrides; on Codex no host cap is visible, so this is the
# only bound there. A run may lower it in its record.
RUN_MAX_IDLE_BLOCKS = 6
RUN_IDLE_RANGE = (1, 7)
RUN_ANCESTOR_LIMIT = 64
RUN_TRANSCRIPT_SCAN_MAX = 4 * 1024 * 1024
RUN_TRANSCRIPT_BACKTRACK = 1024 * 1024   # re-read before the baseline to the record start
RUN_STATUS_SET = ("SUCCESS", "FAIL_12X", "HALT_BLOCK", "PAUSE_USER_INPUT_REQUIRED")
RUN_STATUS_VALUES = " | ".join(RUN_STATUS_SET)
RUN_STATUS_SCAN_MAX = 16 * 1024 * 1024   # unterminated first line beyond this -> unknown (allow)
RUN_STATUS_VALUE_MAX = 32               # longer than every RUN_STATUS_SET value
RUN_STATUS_PATH_MAX = 1024
RUN_DECISION_MAX_SEC = 8.0
RUN_WALK_MAX_DIRS = 20000
RUN_WALK_MAX_SEC = 3.0
RUN_AUDIT_MAX_BYTES = 16 * 1024 * 1024

RUN_BLOCK_REASON = (
    "SDP dispatched run: do not end this turn. No operator starts the next turn "
    "in a dispatched run, so ending now stalls it. Take the next action now. A "
    "turn may end only when (1) the run's STATUS.md (its path is status_path in "
    ".private/sdp-run.json at the worktree root) has been written as exactly one of "
    + RUN_STATUS_VALUES
    + " (a question for the operator is PAUSE_USER_INPUT_REQUIRED, with the "
    "question in your final message), (2) a review gate has halted (.halt), "
    "(3) a marker or split request is waiting for a human to record it, or (4) "
    "a review gate reported INFRA_ERROR (an infra pause). Knowing "
    "what to do next is not an end condition. [{n}/{max}]"
)


def _ancestors(start: Path, limit: int = RUN_ANCESTOR_LIMIT):
    cur = start
    for _ in range(limit):
        yield cur
        if cur.parent == cur:
            return
        cur = cur.parent


def find_run_root(cwd: str) -> Path | None:
    """Nearest ancestor of cwd (inclusive) holding `.git` (file or dir)."""
    if not cwd:
        return None
    try:
        start = Path(cwd).resolve(strict=True)
    except (OSError, RuntimeError):
        return None
    for cand in _ancestors(start):
        try:
            if os.path.lexists(cand / ".git"):
                return cand
        except OSError:
            return None
    return None


def run_record_path(root: Path) -> Path:
    return root / RUN_RECORD_REL


def _idle_max(record: dict) -> int:
    value = record.get("max_idle_blocks", RUN_MAX_IDLE_BLOCKS)
    if isinstance(value, bool) or not isinstance(value, int):
        return RUN_MAX_IDLE_BLOCKS
    lo, hi = RUN_IDLE_RANGE
    return value if lo <= value <= hi else RUN_MAX_IDLE_BLOCKS


def read_run_record(root: Path) -> dict:
    """The run record, or {} when absent or malformed (= not armed)."""
    record = _read_json(run_record_path(root))
    version = record.get("version")
    if isinstance(version, bool) or version != RUN_RECORD_VERSION:   # True == 1 in Python
        return {}
    status = record.get("status_path")
    if not isinstance(status, str) or not os.path.isabs(status):
        return {}
    # The record is repo content (a clone can ship one). status_path is never
    # echoed (the Stop reason is fixed text) but is printed by `run show` and
    # doctor: no control characters, bounded length, basename STATUS.md.
    if (len(status) > RUN_STATUS_PATH_MAX or os.path.basename(status) != "STATUS.md"
            or any(ord(c) < 32 or ord(c) == 127 for c in status)):
        return {}
    armed = record.get("armed_at")
    if isinstance(armed, bool) or not isinstance(armed, (int, float)):
        return {}
    # A huge JSON integer overflows float(); json also accepts NaN/Infinity,
    # and NaN != NaN would reset the idle budget on every Stop (the
    # arm-mismatch rule), so the bound would never exhaust.
    try:
        armed = float(armed)
    except OverflowError:
        return {}
    if not math.isfinite(armed) or armed > time.time() + 60:
        return {}
    # A FRESH dict of validated fields only: the record is repo content, so no
    # unvalidated key or value reaches `run show`, doctor or any later caller.
    clean = {"version": RUN_RECORD_VERSION, "status_path": status, "armed_at": armed}
    dispatch = record.get("dispatch")
    clean["dispatch"] = dispatch if dispatch in RUN_DISPATCH_KINDS else "?"
    if "max_idle_blocks" in record:
        clean["max_idle_blocks"] = record["max_idle_blocks"]   # _idle_max validates it
    offsets = record.get("audit_offsets")
    if (isinstance(offsets, dict) and all(
            isinstance(k, str) and os.path.isabs(k) and len(k) <= 4096
            and not any(ord(c) < 32 or ord(c) == 127 for c in k)
            and isinstance(v, list) and len(v) == 3
            and all(isinstance(x, int) and not isinstance(x, bool) and x >= 0 for x in v)
            for k, v in offsets.items())):
        clean["audit_offsets"] = offsets
    # malformed offsets: dropped, so every audit file is read from 0 under the cap
    return clean


def _isdir_strict(path: Path) -> bool:
    """is_dir() that reports only absence as False; any other OSError
    propagates (Path.is_dir() swallows it, which would turn an unreadable
    ancestor into "no gate state" and block instead of failing open)."""
    try:
        return stat.S_ISDIR(os.stat(path).st_mode)
    except (FileNotFoundError, NotADirectoryError):
        return False


def _lexists_strict(path: Path) -> bool:
    """os.path.lexists() with the same rule as _isdir_strict."""
    try:
        os.lstat(path)
        return True
    except (FileNotFoundError, NotADirectoryError):
        return False


class _DiscoveryIncomplete(OSError):
    """The gate-root search did not see the whole run root (cap hit or a walk
    error). Raised as an OSError so run_end_state answers "io" -- allow."""


def _walk_caps() -> tuple:
    max_dirs, max_sec = RUN_WALK_MAX_DIRS, RUN_WALK_MAX_SEC
    if os.environ.get("SDP_PRECOMPACT_SELFTEST") == "1":
        try:
            max_dirs = min(max_dirs, int(os.environ.get("SDP_RUN_WALK_MAX_DIRS") or max_dirs))
        except ValueError:
            pass
    return max_dirs, max_sec


def _base_for(cand: Path, raw: str):
    """The audit base review_gate._audit_base would use for root `cand`."""
    if not raw:
        return cand / ".private" / "sdp-artifacts"
    # A leading ~ against the PASSWD home, as review_gate._expand does; never
    # $HOME (ADR-W02). ~user is not a gate base.
    if raw == "~" or raw.startswith("~/"):
        return passwd_home() / raw[2:]
    if raw.startswith("~"):
        return None
    base = Path(raw)
    return base if base.is_absolute() else cand / base


def _gate_bases(cwd_path: Path, root: Path) -> list:
    """Every audit base a gate run inside this run root can have written to.

    review_gate._resolve_root prefers an explicit --cwd that contains the
    artifact, with or without `.sdp/`/`.git`, and resolves it to a real path.
    So the candidates are every ancestor of cwd up to the run root, plus every
    directory of a COMPLETE walk of the run root (nothing pruned, symlinks not
    followed: a gate root's real path is visited where it really is). A walk
    that is cut short by a cap or an error raises _DiscoveryIncomplete: a
    partial view must never force continuation.
    """
    raw = os.environ.get("SDP_BASE_DIR") or ""
    bases: list = []

    def add(base) -> None:
        if base is not None and base not in bases:
            bases.append(base)

    for cand in _ancestors(cwd_path):
        add(_base_for(cand, raw))
        if cand == root:
            break
    max_dirs, max_sec = _walk_caps()
    errors: list = []
    started = time.monotonic()
    seen = 0
    for dirpath, _dirs, _files in os.walk(root, onerror=errors.append, followlinks=False):
        seen += 1
        if seen > max_dirs or time.monotonic() - started > max_sec:
            raise _DiscoveryIncomplete("gate-root search hit its cap at %d dirs" % seen)
        base = _base_for(Path(dirpath), raw)
        if base is not None and base not in bases and _isdir_strict(base):
            bases.append(base)
    if errors:
        raise _DiscoveryIncomplete("gate-root search incomplete: %s" % errors[0])
    return bases


def _iso_ts(raw) -> float | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except (ValueError, OverflowError, OSError):   # Windows: out-of-range ts raise
        return None


def _audit_files(bases: list) -> list:
    """Every gate-audit.ndjson a gate run of this run can append to: each
    candidate base, plus the pre-root sink in the passwd home."""
    files, seen = [], set()
    for path in [b / "gate-audit.ndjson" for b in bases] + [sdp_home() / "gate-audit.ndjson"]:
        # Only a REGULAR file may claim a realpath key. A symlinked leaf is
        # skipped BEFORE reserving its target's key, so an alias to the home
        # sink cannot eclipse the real sink (F27). Absent files are skipped;
        # any other lstat error propagates (the caller allows the stop).
        try:
            st = os.lstat(path)
        except (FileNotFoundError, NotADirectoryError):
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        real = os.path.realpath(path)
        if real not in seen:  # many bases resolving (via symlinked dirs) to one file read it once
            seen.add(real)
            files.append(path)
    return files


def _audit_cap() -> int:
    cap = RUN_AUDIT_MAX_BYTES
    if os.environ.get("SDP_PRECOMPACT_SELFTEST") == "1":
        try:
            cap = min(cap, int(os.environ.get("SDP_RUN_AUDIT_MAX_BYTES") or cap))
        except ValueError:
            pass
    return cap


def audit_offsets_now(bases: list) -> dict:
    """{realpath: [st_dev, st_ino, size]} for every existing audit file -- the
    byte boundary of "before the arm". The files are append-only (O_APPEND),
    so every byte past a recorded size was appended after the arm."""
    offsets = {}
    for path in _audit_files(bases):
        try:
            st = os.lstat(path)
        except (FileNotFoundError, NotADirectoryError):
            continue
        if stat.S_ISREG(st.st_mode):
            offsets[os.path.realpath(path)] = [st.st_dev, st.st_ino, st.st_size]
    return offsets


def _audit_infra_pause(bases: list, root: Path, offsets: dict) -> bool:
    """Whether the latest audited verdict since the arm, for some artifact in
    this run, is INFRA_ERROR. Every INFRA_ERROR is audited -- post-root to
    <base>/gate-audit.ndjson, pre-root (no state paths yet, so no flag file) to
    <passwd home>/.sdp/gate-audit.ndjson. A root-resolution failure is the
    exception: its row carries a null artifact and is not a pause (NC-35). "Since the arm" is the byte offset
    recorded at arm time, never a timestamp (writers are not ordered). A later
    verdict for the same artifact supersedes the error, so a recovered infra
    blip is not a permanent pass. A replaced, truncated, removed or
    symlink-swapped file recorded at arm, or a span past the cap, is
    incomplete coverage: _DiscoveryIncomplete, i.e. allow."""
    cap = _audit_cap()
    total = 0
    latest: dict = {}
    files = _audit_files(bases)
    # Every file recorded at arm must still be read now. One that vanished, or
    # became a symlink (which _audit_files skips), would otherwise drop out of
    # coverage silently and the stop would be blocked on a partial view.
    live = {os.path.realpath(p) for p in files}
    for key in offsets:
        if key not in live:
            raise _DiscoveryIncomplete("gate audit file recorded at arm is no longer readable: %s" % key)
    for path in files:
        try:
            st = os.lstat(path)
        except (FileNotFoundError, NotADirectoryError):
            raise _DiscoveryIncomplete("gate audit file vanished during the check: %s" % path)
        if not stat.S_ISREG(st.st_mode):
            raise _DiscoveryIncomplete("gate audit file changed type during the check: %s" % path)
        start = 0
        recorded = offsets.get(os.path.realpath(path))
        if recorded:
            if [st.st_dev, st.st_ino] != recorded[:2]:
                raise _DiscoveryIncomplete("gate audit file replaced since the arm: %s" % path)
            if st.st_size < recorded[2]:
                raise _DiscoveryIncomplete("gate audit file truncated since the arm: %s" % path)
            start = recorded[2]
        if total + (st.st_size - start) > cap:
            # Checked BEFORE the read, and summed across every file.
            raise _DiscoveryIncomplete("gate audit spans since the arm exceed the cap at %s" % path)
        total += st.st_size - start
        # Open without following a link and confirm the OPENED file is the one
        # just checked: a swap after the lstat is incomplete coverage.
        fd = os.open(path, win_compat.open_flags(os.O_RDONLY, getattr(os, "O_NOFOLLOW", 0), getattr(os, "O_NONBLOCK", 0)))
        with os.fdopen(fd, "rb") as fh:
            fst = os.fstat(fh.fileno())
            if not stat.S_ISREG(fst.st_mode) or (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino):
                raise _DiscoveryIncomplete("gate audit file swapped during the check: %s" % path)
            fh.seek(start)
            blob = fh.read(st.st_size - start)
        if len(blob) != st.st_size - start:
            # Truncated between the size check and the read: rows may be gone.
            raise _DiscoveryIncomplete("gate audit file shrank during the check: %s" % path)
        # NDJSON records end at b"\n" only. str.splitlines() would also split
        # on U+0085/U+2028/U+2029, which ensure_ascii=False writers leave raw.
        for raw in blob.split(b"\n"):
            line = raw.decode("utf-8", "replace")
            try:
                row = json.loads(line)
            except (ValueError, RecursionError):
                continue
            if not isinstance(row, dict):
                continue
            ts = _iso_ts(row.get("ts"))
            artifact = row.get("artifact")
            if ts is None or not isinstance(artifact, str) or not artifact:
                continue
            # One key per artifact however it was spelled (symlink, /var vs
            # /private/var): the root is a resolved path, and supersession
            # must group aliases of the same file together.
            try:
                try:
                    # strict: a resolution error is surfaced, not papered over
                    # with a partially resolved path. Path.resolve(strict=True)
                    # rather than os.path.realpath(strict=...), which is 3.10+;
                    # the supported floor is Python 3.9.
                    key = str(Path(artifact).resolve(strict=True))
                except FileNotFoundError:
                    key = os.path.realpath(artifact)   # deleted since: nothing left to follow
            except (OSError, ValueError, RuntimeError) as exc:   # RuntimeError: symlink loop on 3.9-3.12
                # Cannot tell whether this row belongs to the run: unknown.
                raise _DiscoveryIncomplete("audit row artifact unresolvable: %s" % exc)
            try:
                Path(key).relative_to(root)
            except ValueError:
                continue   # outside the run root: not this run's row
            prev = latest.get(key)
            verdict = row.get("verdict")
            # Equal timestamps (possibly from different sinks, scanned in any order)
            # resolve toward INFRA_ERROR, i.e. toward allowing, so the verdict never
            # depends on file scan order.
            if (prev is None or ts > prev[0]
                    or (ts == prev[0] and (verdict == "INFRA_ERROR" or prev[1] != "INFRA_ERROR"))):
                latest[key] = (ts, verdict)
    return any(verdict == "INFRA_ERROR" for _ts, verdict in latest.values())


def _mtime(path: Path) -> float | None:
    """mtime, or None when the path does not exist. Any other OSError
    propagates so the caller can fail open instead of reading it as absent."""
    try:
        return os.stat(path).st_mtime
    except (FileNotFoundError, NotADirectoryError):
        return None


def _status_written(path: Path, armed: float) -> bool:
    """Whether the run's STATUS.md is written: a regular file, newer than the
    arm, holding exactly one of the four values. Absent -> False; any other
    OSError propagates (fail open in the caller)."""
    try:
        st = os.lstat(path)
    except (FileNotFoundError, NotADirectoryError):
        return False
    if not stat.S_ISREG(st.st_mode) or st.st_mtime < armed:
        return False
    # Read the file just checked, not whatever the path names a moment later:
    # no link following, no blocking, and the OPENED file must be the same
    # regular, fresh file. A swap in between is not a status.
    fd = os.open(path, win_compat.open_flags(os.O_RDONLY, getattr(os, "O_NOFOLLOW", 0), getattr(os, "O_NONBLOCK", 0)))
    with os.fdopen(fd, "rb", buffering=0) as fh:   # unbuffered: no read-ahead past the cap
        fst = os.fstat(fh.fileno())
        if not stat.S_ISREG(fst.st_mode) or (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino):
            # Replaced between the check and the open: unknown, not "no status".
            raise _DiscoveryIncomplete("STATUS.md replaced during the check")
        if fst.st_mtime < armed:
            return False
        # Same reading as both adapters, "$(head -n1 | tr -d '[:space:]')",
        # streamed over BYTES with no line-length bound: the first line ends at
        # the first b"\n" only; ASCII whitespace (the C-locale [:space:] set)
        # and NUL (dropped by command substitution) are removed; bytes after
        # the first newline are never read. Only the kept bytes are held, and
        # once they outgrow the longest value the answer is settled (no).
        # A first line still unterminated after RUN_STATUS_SCAN_MAX bytes is
        # unknown: fail open, as every other cap does.
        kept = bytearray()
        scanned = 0
        while True:
            if scanned >= RUN_STATUS_SCAN_MAX:
                # Checked BEFORE reading on: no byte past the cap is consulted.
                raise _DiscoveryIncomplete("STATUS.md first line exceeds the scan cap")
            chunk = fh.read(min(65536, RUN_STATUS_SCAN_MAX - scanned))
            if not chunk:
                if scanned < fst.st_size:
                    # EOF before the size fstat reported: shrunk in place
                    # during the check -> unknown, not "no status".
                    raise _DiscoveryIncomplete("STATUS.md shrank during the check")
                break
            line_end = chunk.find(b"\n")
            part = chunk if line_end < 0 else chunk[:line_end]
            kept.extend(b for b in part if b not in b" \t\n\r\x0b\x0c\x00")
            if len(kept) > RUN_STATUS_VALUE_MAX:
                return False
            if line_end >= 0:
                break
            scanned += len(chunk)
    return bytes(kept).decode("ascii", "replace") in RUN_STATUS_SET


def run_end_state(cwd_path: Path, root: Path, record: dict) -> str:
    """A tag naming the legal end state that allows this stop, or "".

    Every end state must postdate `armed_at`, so artifacts an earlier dispatch
    left in the same worktree never authorize a stop after a re-arm. Any
    unexpected I/O error answers "io" -- allow, never block on a guess.
    """
    armed = float(record["armed_at"])
    try:
        if _status_written(Path(record["status_path"]), armed):
            return "status"
        bases = _gate_bases(cwd_path, root)
        for base in bases:
            gate = base / "gate"
            if not _isdir_strict(gate):
                continue
            with os.scandir(gate) as it:
                entries = [e for e in it if e.name.startswith("review_gate_")]
            for entry in entries:
                name = entry.name
                # Gate state is written as regular files; anything else (a
                # directory, a symlink) named like one is not an end state.
                est = entry.stat(follow_symlinks=False)
                if not stat.S_ISREG(est.st_mode):
                    continue
                if name.endswith(".halt"):
                    m = est.st_mtime
                    if m >= armed:
                        return "halt"
                # An unattended INFRA_ERROR orders "pause + notify"; the gate
                # records it as .infra_flag / .needs_human.
                if name.endswith((".infra_flag", ".needs_human")):
                    if est.st_mtime >= armed:
                        return "infra"
                for suffix in (".marker-request", ".split-request"):
                    if not name.endswith(suffix):
                        continue
                    m = est.st_mtime
                    if m < armed:
                        continue
                    log_m = _mtime(gate / (name[: -len(suffix)] + ".log"))
                    if log_m is None or m >= log_m:
                        return "request"
        if _audit_infra_pause(bases, root, record.get("audit_offsets") or {}):
            return "infra"
    except OSError as exc:
        if isinstance(exc, _DiscoveryIncomplete):
            sys.stderr.write("sdp run-continuation: %s; allowing this stop\n" % exc)
        return "io"
    return ""


def run_state_path(session_id: str) -> Path:
    return state_dir() / (_safe_session(session_id) + ".run.json")


def read_run_state(session_id: str) -> dict:
    try:
        return _read_json(run_state_path(session_id))
    except OSError:
        return {}


def write_run_state(session_id: str, payload: dict) -> bool:
    try:
        return _write_json(run_state_path(session_id), payload)
    except OSError:
        return False


def read_run_state_strict(session_id: str) -> dict | None:
    """The run state: {} when absent, None when it exists but cannot be read
    or is not a JSON object. None must never be mistaken for a fresh budget."""
    try:
        path = run_state_path(session_id)
        st = os.lstat(path)
    except (FileNotFoundError, NotADirectoryError):
        return {}
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_JSON_BYTES:
        return None
    # Same open as _read_json: no link following, no blocking, and the OPENED
    # file re-checked, so a FIFO swapped in after the lstat cannot hang Stop.
    try:
        fd = os.open(path, win_compat.open_flags(os.O_RDONLY, getattr(os, "O_NOFOLLOW", 0), getattr(os, "O_NONBLOCK", 0)))
    except OSError:
        return None
    try:
        fst = os.fstat(fd)
        if (not stat.S_ISREG(fst.st_mode) or fst.st_size > MAX_JSON_BYTES
                or (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino)):
            return None
        with os.fdopen(fd, "r", encoding="utf-8") as fh:
            fd = -1
            data = json.load(fh)
    except (OSError, ValueError, RecursionError):
        return None
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
    if not isinstance(data, dict) or not data:
        # Every state this hook writes has keys; an existing EMPTY object is
        # malformed, not "absent" -- treating it as a first arm would refill
        # the budget.
        return None
    return data


def note_blocker(session_id: str, who: str) -> None:
    """Record which decision issued the last block for this session. An
    unreadable state is left alone -- rewriting it would hand out a budget."""
    state = read_run_state_strict(session_id)
    if state is None:
        return
    state["last_blocker"] = who
    write_run_state(session_id, state)


def _is_tool_call(record: dict) -> bool:
    if record.get("type") == "assistant":
        message = record.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, list):
            return any(isinstance(c, dict) and c.get("type") == "tool_use" for c in content)
        return False
    if record.get("type") == "response_item":
        payload = record.get("payload")
        kind = payload.get("type") if isinstance(payload, dict) else None
        return isinstance(kind, str) and kind.endswith("_call")
    return False


def _open_transcript(path: str) -> tuple:
    """(fd, (dev, ino, size)) for a readable regular transcript, or (None, None)
    when there is none (no path, or absent). The identity is
    the fstat of the descriptor _work_since then reads, so no swap can fall
    between them. Any other error (EACCES, a non-regular file, ...) propagates: the caller allows
    the stop without writing, so an error never spends or refills the budget."""
    if not path:
        return None, None
    try:
        fd = os.open(path, win_compat.open_flags(os.O_RDONLY, getattr(os, "O_NONBLOCK", 0)))
    except (FileNotFoundError, NotADirectoryError):
        return None, None
    try:
        st = os.fstat(fd)
    except OSError:
        os.close(fd)
        raise
    if not stat.S_ISREG(st.st_mode):
        # It exists but is not a transcript we can read (a directory, a FIFO):
        # an error, not "no transcript", so no count is spent on it.
        os.close(fd)
        raise OSError("transcript is not a regular file")
    return fd, (st.st_dev, st.st_ino, st.st_size)


def _work_since(fd: int | None, state: dict, ident: tuple | None) -> bool | None:
    """Whether the model made a tool call since the last recorded block.

    Only the bytes appended since then are scanned. A replaced file (new
    identity, whatever its size), a shrunk one, or more than the scan cap
    appended all count as work. No transcript at all is NOT work, so the bound
    still holds.
    """
    if ident is None:
        return False
    dev, ino, size = ident
    old_id = state.get("transcript_id")
    old_size = state.get("transcript_size")
    if old_id is None and old_size is None:
        # No baseline is no evidence of work (like "no transcript is not
        # work"); the next block records one. Counting it as work would hand
        # a fresh budget to a state that merely lost its baseline.
        return False
    if not isinstance(old_id, list) or not isinstance(old_size, int):
        return True
    if old_id != [dev, ino] or size < old_size:
        return True
    if size - old_size > RUN_TRANSCRIPT_SCAN_MAX:
        return True
    if size == old_size:
        return False
    # Read from the SAME descriptor whose fstat produced `ident`, so the bytes
    # scanned belong to the identified file. A short read (truncated meanwhile)
    # or a read error is unknown, not work.
    # The baseline may fall INSIDE a JSONL record (the host was mid-write when
    # the block was recorded). Re-read back to the last b"\n" before it, within
    # RUN_TRANSCRIPT_BACKTRACK, so a tool-call record completed after the
    # block is parsed whole rather than as an unparseable suffix.
    back = min(old_size, RUN_TRANSCRIPT_BACKTRACK)
    start = old_size - back
    want = size - start
    chunks, got = [], 0
    try:
        os.lseek(fd, start, os.SEEK_SET)
        while got < want:
            chunk = os.read(fd, want - got)
            if not chunk:
                break
            chunks.append(chunk)
            got += len(chunk)
    except OSError:
        return None
    if got != want:
        return None
    blob = b"".join(chunks)
    if back:
        cut = blob.rfind(b"\n", 0, back)
        if cut < 0 and start > 0:
            # The record began before the backtrack window: its head is unread,
            # so whether it is a tool call is unknown -> allow, no write.
            return None
        blob = blob[cut + 1:]   # cut == -1 with start == 0: the record began at byte 0
    # Only newline-TERMINATED records count. An unterminated tail is still being
    # written; it is scanned once its b"\n" arrives (via the backtrack above),
    # never twice, so one tool call cannot reset the budget twice.
    end = blob.rfind(b"\n")
    blob = blob[:end + 1] if end >= 0 else b""
    for raw in blob.split(b"\n"):  # JSONL: b"\n" only (see _audit_infra_pause)
        try:
            # STRICT decode: a line with invalid UTF-8 is malformed, not a tool
            # call (replacement characters could make it parse as one).
            record = json.loads(raw.decode("utf-8"))
        except (ValueError, RecursionError):   # UnicodeDecodeError is a ValueError
            continue
        if isinstance(record, dict) and _is_tool_call(record):
            return True
    return False


def _decision_deadline() -> float:
    sec = RUN_DECISION_MAX_SEC
    if os.environ.get("SDP_PRECOMPACT_SELFTEST") == "1":
        try:
            sec = min(sec, float(os.environ.get("SDP_RUN_DECISION_MAX_SEC") or sec))
        except ValueError:
            pass
    return sec


def _end_state_with_deadline(cwd_path: Path, root: Path, record: dict) -> str:
    """run_end_state under an ENFORCED deadline. A time check between syscalls
    cannot bound one that blocks, so the evaluation runs in a daemon thread;
    if it is still running at the deadline the stop is allowed and the process
    ends at once (os._exit), so nothing it is stuck in can hold the hook."""
    box: dict = {}

    def work() -> None:
        try:
            box["end"] = run_end_state(cwd_path, root, record)
        except BaseException:  # noqa: BLE001 - any failure is "unknown": allow
            box["end"] = "io"

    worker = threading.Thread(target=work, daemon=True)
    worker.start()
    worker.join(_decision_deadline())
    if worker.is_alive():
        sys.stderr.write("sdp run-continuation: end-state check exceeded its deadline; allowing this stop\n")
        sys.stderr.flush()
        sys.stdout.flush()
        os._exit(0)
    return box.get("end", "io")


def _finite_number(x) -> bool:
    """A non-bool int or float that is finite. A huge int (401 digits) raises
    OverflowError in float(); that is "not finite", not a crash."""
    if not isinstance(x, (int, float)) or isinstance(x, bool):
        return False
    try:
        return math.isfinite(float(x))
    except OverflowError:
        return False


def _is_int(x) -> bool:
    # bool subclasses int; True must not pass as 1.
    return isinstance(x, int) and not isinstance(x, bool)


def _same_arm_state_ok(state: dict) -> bool:
    """Budget fields of a state that claims the current arm (F28):
    idle_blocks a non-bool int >= 0 (required); transcript_id absent or a list
    of exactly two non-bool ints >= 0 (st_dev, st_ino); transcript_size absent
    or a non-bool int >= 0; the two baseline keys present together or not at all."""
    idle = state.get("idle_blocks")
    if not (_is_int(idle) and idle >= 0):
        return False
    if ("transcript_id" in state) != ("transcript_size" in state):
        return False   # the baseline is both keys or neither
    if "transcript_id" in state:
        tid = state["transcript_id"]
        if not (isinstance(tid, list) and len(tid) == 2 and all(_is_int(v) and v >= 0 for v in tid)):
            return False
    if "transcript_size" in state:
        size = state["transcript_size"]
        if not (_is_int(size) and size >= 0):
            return False
    return True


def _run_continuation_reason(payload: dict) -> str:
    """Run-continuation's block reason for this Stop, or "".

    Never consults stop_hook_active (Claude Code keeps it set for the whole
    user turn after the first block) nor the precompact mode file.
    """
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return ""
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd or "\x00" in cwd:
        return ""
    root = find_run_root(cwd)
    if root is None:
        return ""
    record = read_run_record(root)
    if not record:
        return ""
    try:
        cwd_path = Path(cwd).resolve(strict=True)
    except (OSError, RuntimeError):
        return ""
    end = _end_state_with_deadline(cwd_path, root, record)
    if end:
        return ""
    # Precompact's snapshot turn must END: /compact is typed only once the TUI
    # is idle. Stand down while this session's marker is pending AND live
    # (bounded by PENDING_EXPIRY_SEC). Not marker_active(): it has no expiry.
    # snapshotted/injected do not stand down -- compaction is already under way.
    pc_marker = read_marker(session_id)
    if not pc_marker:
        # _read_json answers {} on ANY failure: a marker that exists but cannot
        # be read is "cannot tell", so stand down rather than block and write.
        try:
            os.lstat(marker_path(session_id))
            present = True
        except (FileNotFoundError, NotADirectoryError):
            present = False
        except OSError:
            present = True
        if present:
            sys.stderr.write("sdp run-continuation: precompact marker unreadable; allowing this stop\n")
            return ""
    if pc_marker.get("state") == "pending" and marker_is_live(pc_marker, time.time()):
        return ""
    limit = _idle_max(record)
    state = read_run_state_strict(session_id)
    if state is None:
        # Unreadable or malformed state: allow, and do not replace it -- a
        # replacement would be a fresh budget nobody earned.
        sys.stderr.write("sdp run-continuation: run state unreadable; allowing this stop\n")
        return ""
    # State counts against ONE arm. A re-arm (tmux resume, a reused worktree)
    # starts a new run: drop the idle count and the transcript baseline, so an
    # exhausted budget from the previous arm cannot let this one stop at once.
    budget_keys = ("armed_at", "idle_blocks", "transcript_id", "transcript_size")
    prev_arm = state.get("armed_at")
    if any(k in state for k in budget_keys) and not _finite_number(prev_arm):
        # Budget fields with a missing or malformed armed_at cannot be told
        # apart from the current arm: treating them as a re-arm would refill
        # an exhausted budget. Allow, and do not rewrite.
        sys.stderr.write("sdp run-continuation: run state malformed; allowing this stop\n")
        return ""
    if prev_arm != record["armed_at"]:
        state = {k: v for k, v in state.items() if k == "last_blocker"}
    elif not _same_arm_state_ok(state):
        # Same arm but malformed budget fields: normalizing them would hand out
        # a fresh budget without work (F28). Allow, and do not rewrite.
        sys.stderr.write("sdp run-continuation: run state malformed; allowing this stop\n")
        return ""
    transcript = payload.get("transcript_path")
    if transcript is None:
        transcript = ""
    elif not isinstance(transcript, str):
        # Malformed evidence, not "no transcript": no count is spent on it.
        sys.stderr.write("sdp run-continuation: transcript_path malformed; allowing this stop\n")
        return ""
    try:
        # A transcript that exists must open for reading before it may spend
        # or reset the budget (unchanged-but-unreadable would spend a count; an
        # unreadable replacement would reset it).
        tfd, ident = _open_transcript(transcript)
    except (OSError, ValueError):   # ValueError: an embedded NUL in the path
        sys.stderr.write("sdp run-continuation: transcript unreadable; allowing this stop\n")
        return ""
    try:
        work = _work_since(tfd, state, ident)
    finally:
        if tfd is not None:
            try:
                os.close(tfd)
            except OSError:
                pass
    idle = state.get("idle_blocks")
    idle = idle if isinstance(idle, int) and not isinstance(idle, bool) and idle >= 0 else 0
    if work is None:
        sys.stderr.write("sdp run-continuation: transcript unreadable; allowing this stop\n")
        return ""
    if work:
        idle = 0
    if idle >= limit:
        sys.stderr.write(
            "sdp run-continuation: %d consecutive blocks without tool work; "
            "allowing this stop\n" % idle
        )
        return ""
    idle += 1
    new_state = dict(state)
    new_state.update({"idle_blocks": idle, "last_blocker": "run", "armed_at": record["armed_at"]})
    if ident is not None:
        new_state["transcript_id"] = [ident[0], ident[1]]
        new_state["transcript_size"] = ident[2]
    if not write_run_state(session_id, new_state):
        # Without persisted state nothing bounds the next block. Stay silent.
        return ""
    # Fixed text plus integers only: the record is repo content, so none of it
    # is echoed to the model.
    return RUN_BLOCK_REASON.format(n=idle, max=limit)


def cmd_run(argv: list) -> int:
    """`run arm --status <abs path> [--cwd DIR] [--dispatch KIND] [--max-idle-blocks N]`
    writes the run record at the git root above DIR; `run show [--cwd DIR]`
    prints it with the current end-state verdict."""
    sub = argv[0] if argv else ""
    opts: dict = {}
    rest = list(argv[1:])
    while rest:
        key = rest.pop(0)
        if key not in ("--status", "--cwd", "--dispatch", "--max-idle-blocks") or not rest:
            sys.stderr.write("run: bad argument %r\n" % key)
            return 2
        opts[key] = rest.pop(0)
    cwd = opts.get("--cwd") or os.getcwd()
    root = find_run_root(cwd)
    if root is None:
        sys.stderr.write("run: no git root above %s\n" % cwd)
        return 2
    if sub == "show":
        record = read_run_record(root)
        if not record:
            sys.stdout.write("run record: none (not armed) at %s\n" % run_record_path(root))
            return 0
        end = run_end_state(Path(cwd).resolve(), root, record)
        sys.stdout.write(
            "run record: %s\n%s\nend state: %s\n"
            % (run_record_path(root), json.dumps(record), end or "none (stops are blocked)")
        )
        return 0
    if sub == "disarm":
        # Operator action: a run that ended without STATUS.md (bound exhausted,
        # timeout, crash) otherwise leaves the worktree armed for good.
        try:
            os.unlink(run_record_path(root))
        except FileNotFoundError:
            pass
        except OSError as exc:
            sys.stderr.write("run disarm: %s\n" % exc)
            return 1
        sys.stdout.write("disarmed: %s\n" % run_record_path(root))
        return 0
    if sub != "arm":
        sys.stderr.write("usage: precompact_hook.py run {arm --status PATH | show | disarm} [--cwd DIR]\n")
        return 2
    private = root / RUN_RECORD_REL.parent
    try:
        pst = os.lstat(private)
        if not stat.S_ISDIR(pst.st_mode):
            sys.stderr.write("run arm: %s is not a real directory (symlink?)\n" % private)
            return 2
    except FileNotFoundError:
        pass
    status = opts.get("--status") or ""
    if not os.path.isabs(status):
        sys.stderr.write("run arm: --status must be an absolute path\n")
        return 2
    if (len(status) > RUN_STATUS_PATH_MAX or os.path.basename(status) != "STATUS.md"
            or any(ord(c) < 32 or ord(c) == 127 for c in status)):
        sys.stderr.write("run arm: --status must name a STATUS.md (no control chars, <= %d chars)\n"
                         % RUN_STATUS_PATH_MAX)
        return 2
    dispatch = opts.get("--dispatch") or "manual"
    if dispatch not in RUN_DISPATCH_KINDS:
        sys.stderr.write("run arm: --dispatch must be one of %s\n" % ", ".join(RUN_DISPATCH_KINDS))
        return 2
    # Offsets are captured BEFORE armed_at is taken: a row appended in between
    # then lies past the recorded offset and counts as post-arm (toward
    # allowing). The reverse order could fold a post-armed_at INFRA_ERROR into
    # the "before" span and hide it.
    offsets = None
    try:
        offsets = audit_offsets_now(_gate_bases(root, root))
    except OSError as exc:
        # Without offsets every audit file is read from 0 under the cap; that
        # is still bounded and fail-open, just less precise.
        sys.stderr.write("run arm: audit offsets not recorded (%s)\n" % exc)
    record = {
        "version": RUN_RECORD_VERSION,
        "status_path": status,
        "armed_at": time.time(),
        "dispatch": dispatch,
    }
    if offsets is not None:
        record["audit_offsets"] = offsets
    if "--max-idle-blocks" in opts:
        try:
            record["max_idle_blocks"] = int(opts["--max-idle-blocks"])
        except ValueError:
            sys.stderr.write("run arm: --max-idle-blocks must be an integer\n")
            return 2
        lo, hi = RUN_IDLE_RANGE
        if not lo <= record["max_idle_blocks"] <= hi:
            sys.stderr.write("run arm: --max-idle-blocks must be %d-%d\n" % (lo, hi))
            return 2
    path = run_record_path(root)
    if not _write_json(path, record):
        sys.stderr.write("run arm: could not write %s\n" % path)
        return 1
    if not read_run_record(root):
        sys.stderr.write("run arm: the written record does not read back as armed: %s\n" % path)
        return 2
    sys.stdout.write("%s\n" % path)
    return 0


def hook_stop() -> int:
    """Stop hook: one entry point, two decisions.

    Precompact (context threshold) is evaluated first, because losing a snapshot
    to a continuation nudge is the worse outcome. Run-continuation (issue #5)
    is evaluated only when precompact does not block. At most one block is
    emitted per Stop.
    """
    payload = read_hook_input()
    session_id_for_bind = payload.get("session_id")
    if isinstance(session_id_for_bind, str):
        # Every turn, cheaply: the tool that later queues a compaction cannot
        # read the pane key from its own environment on every host.
        bind_pane(session_id_for_bind)
    # A subagent finishing raises SubagentStop, not Stop, but an agent_id here
    # would still mean this is not the main thread. Never block a subagent --
    # under either decision.
    if payload.get("agent_id"):
        return 0
    reason = _precompact_reason(payload)
    if not reason:
        reason = _run_continuation_reason(payload)
    if reason:
        json.dump({"decision": "block", "reason": reason}, sys.stdout)
    return 0


def _precompact_reason(payload: dict) -> str:
    """Precompact's block reason for this Stop, or "" (detect the threshold,
    block once, demand the snapshot)."""
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return ""
    # The host sets stop_hook_active on the Stop that follows a block, and on
    # Claude Code it then STAYS set for the rest of the user turn. Honouring it
    # is what bounds precompact's own loop. When the block that set it was
    # run-continuation's, honouring it would switch precompact off for the rest
    # of a dispatched run, whose user turn never ends -- so it is honoured only
    # for a block precompact itself issued (or one it cannot attribute).
    if payload.get("stop_hook_active") and read_run_state(session_id).get("last_blocker") != "run":
        return ""
    if not is_auto_enabled():
        return ""

    now = time.time()
    marker = read_marker(session_id)
    if marker and marker_is_live(marker, now):
        return ""

    threshold = resolve_threshold()
    pct, used, limit, model, exact = measure_context(
        payload.get("transcript_path"), payload.get("cwd") or ""
    )
    # The sticky window exists because Claude's window can only be inferred and
    # the evidence for a wide one scrolls out of view. Where the host states the
    # window outright there is nothing to remember, and remembering would be
    # actively wrong: a session that moved to a narrower model would keep being
    # measured against the wider one it used to have.
    if not exact:
        limit = sticky_window(session_id, limit)
        pct = (used / limit * 100.0) if limit > 0 else 0.0
    if pct < threshold:
        if marker:
            clear_marker(session_id)
        return ""

    cwd = payload.get("cwd") or ""
    tag = session_tag(session_id)
    today = time.strftime("%Y%m%d", time.localtime(now))
    # Before the block, not after: the block text names this directory and
    # forbids the command that would create it. What the block is allowed to
    # CLAIM depends on whether that actually worked -- telling a model the
    # directory exists when it does not, while forbidding mkdir, is a
    # contradiction it has no budget to resolve.
    day_dir = ensure_day_dir(cwd, today)
    # Everything already on disk is somebody else's. Recording it now is what
    # lets PreCompact tell "the file this session wrote" from "the newest file".
    # `marker` here is this session's expired marker, if any -- a live one
    # returned above.
    if marker.get("pre_existing") is not None and marker.get("cwd") == cwd:
        existing = list(marker.get("pre_existing") or [])
        inventory_complete = marker.get("inventory_complete") is not False
    else:
        known = sorted(Path(path).name for path, _ in list_snapshots(cwd))
        inventory_complete = len(known) <= MAX_INVENTORY
        existing = known[:MAX_INVENTORY]
    persisted = write_marker(
        session_id,
        {
            "state": "pending",
            "at": now,
            "pct": round(pct, 2),
            "used_tokens": used,
            "context_limit": limit,
            "model": model,
            # Recorded here, not derived at PreCompact: this is the reading the
            # cost is measured FROM, and a later call can land on a different
            # transcript format after a resume.
            "host": measured_host(),
            "cwd": cwd,
            "tag": tag,
            "pre_existing": existing,
            "inventory_complete": inventory_complete,
        },
    )
    if not persisted:
        # Without a marker nothing suppresses the next detection, so blocking
        # here would block again, and again. Stay silent instead.
        return ""
    if day_dir == DAY_DIR_UNSAFE:
        reason = UNSAFE_DIR_REASON.format(pct=pct, threshold=threshold, cwd=cwd or ".")
    else:
        ready = day_dir == DAY_DIR_READY
        reason = BLOCK_REASON.format(
            pct=pct,
            threshold=threshold,
            today=today,
            tag=tag,
            dir_note=(DIR_READY_NOTE if ready else DIR_MISSING_NOTE),
            mkdir_note=(MKDIR_BANNED_NOTE if ready else MKDIR_ALLOWED_NOTE),
        )
    note_blocker(session_id, "precompact")
    return reason


def _log_cycle(session_id, payload, marker, now, bound, path):
    """Record what this precompact cycle cost, at the one moment it is known.

    ``used_at_stop`` is what the Stop hook measured when it asked for the
    snapshot; re-measuring here gives ``used_at_precompact``. Their difference
    is what the Codex-side threshold needs and what nothing currently keeps --
    clearing the marker throws it away.

    Named ``turn_cost_upper_bound`` rather than a snapshot cost because that is
    what it is. No hook runs when the file is written, so the second reading is
    taken after the whole turn: the number bounds the write from above and is
    safe to size a headroom with, but calling it the write's cost would be a
    claim the data does not support.

    It is only computed when the two readings are COMPARABLE: both present,
    occupancy non-decreasing, and no known pair of host, window or model
    disagreeing. That is deliberately weaker than "the same context epoch" --
    a value missing on one side cannot disagree -- and the field is named for
    the check it performs rather than for the property one might want it to
    prove. Rows that fail it still record both readings and leave the bound
    null, because knowing a cycle happened is worth more than a fabricated
    number for it.

    Host and window are recorded on every row. Without them the ledger mixes
    Claude and Codex samples into one distribution, and a threshold set from
    that distribution is set for neither. ``model`` is often "" on Codex: it is
    stated on records that are usually out of the scanned tail, and inventing
    one from the environment would say the wrong thing confidently.
    """
    used_at_stop = marker.get("used_tokens")
    if not isinstance(used_at_stop, int):
        used_at_stop = None
    host_at_stop = marker.get("host") or ""
    try:
        _pct, used_now, limit_now, model_now, exact = measure_context(
            payload.get("transcript_path"),
            marker.get("cwd") or payload.get("cwd") or "",
        )
        host_now = measured_host()
    except Exception:  # noqa: BLE001 - a measurement must never cost a compaction
        used_now, limit_now, model_now, exact, host_now = 0, 0, "", False, ""
    limit_at_stop = marker.get("context_limit") or 0

    # What this does and does not prove. Both readings must exist, occupancy
    # must not have gone backwards, and no KNOWN pair of host, window or model
    # may disagree. Where a value is missing on one side it cannot disagree,
    # and that is a weaker test than "the epoch is the same" -- Codex states no
    # model in the scanned tail, so the model check is usually vacuous there.
    # The flag is therefore named for the comparison it performs; a reader
    # deciding a threshold from these rows should know the guarantee is
    # "nothing observable contradicts it", not "proven identical".
    def _agrees(a, b):
        return not a or not b or a == b

    comparable = (
        isinstance(used_at_stop, int)
        and bool(used_now)
        and used_now >= used_at_stop
        and _agrees(host_at_stop, host_now)
        and _agrees(limit_at_stop, limit_now)
        and _agrees(marker.get("model") or "", model_now or "")
    )
    row = {
        "contract_rev": CYCLE_CONTRACT_REV,
        "at": round(now, 3),
        "session": _safe_session(session_id),
        "trigger": payload.get("trigger") or "unknown",
        "requested": bool(marker),
        "host": host_now or host_at_stop or "",
        "host_at_stop": host_at_stop,
        "model_at_stop": marker.get("model") or "",
        "model_at_precompact": model_now or "",
        # Three fields, not one with fallbacks. doctor groups on the stop-time
        # window, and a field that silently borrows the other end's value
        # produces groups describing no real session. "context_limit" is kept
        # for readers that only want a number and is explicitly NOT what the
        # grouping reads.
        "context_limit_at_stop": limit_at_stop or 0,
        "context_limit_at_precompact": limit_now or 0,
        "context_limit": limit_at_stop or limit_now or 0,
        "limit_exact": bool(exact),
        "used_at_stop": used_at_stop,
        "used_at_precompact": used_now or None,
        "turn_cost_upper_bound": (used_now - used_at_stop) if comparable else None,
        "comparable_measurement": bool(comparable),
        "pct_at_stop": marker.get("pct"),
        "pct_at_precompact": (
            round(used_now / limit_now * 100.0, 2) if used_now and limit_now else None
        ),
        "outcome": "bound" if bound else "missing",
        # The name only. The path is the user's working tree, and a ledger in
        # the home directory is the wrong place to accumulate one.
        "snapshot": Path(path).name if path else "",
    }
    record_cycle(row)


def hook_precompact() -> int:
    """PreCompact hook: bind the snapshot to this session before context dies."""
    payload = read_hook_input()
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return 0

    bind_pane(session_id)
    now = time.time()
    marker = read_marker(session_id)

    # A cycle that asked for this compaction told us which file it wrote. That
    # is better evidence than anything inferable from the directory, and it is
    # the only thing that rescues the hand-run case, whose snapshot carries no
    # session tag and may sit beside another recent one.
    stated = ""
    if peek_self_fire_intent(session_id):
        # Only a live intent speaks for this compaction; a stale sidecar would
        # otherwise bind an old snapshot to a much later manual compaction.
        claimed = _read_json(intent_path(session_id)).get("snapshot")
        if isinstance(claimed, str):
            stated = _verified_snapshot(
                claimed, marker.get("cwd") or payload.get("cwd") or ""
            )
    if stated:
        record = dict(marker)
        record["state"] = "snapshotted"
        record["at"] = now
        record["trigger"] = payload.get("trigger") or "unknown"
        record["cwd"] = marker.get("cwd") or payload.get("cwd") or ""
        record["snapshot"] = stated
        write_marker(session_id, record)
        _log_cycle(session_id, payload, marker, now, bound=True, path=stated)
        return 0

    if marker.get("state") == "pending":
        try:
            floor = float(marker.get("at") or 0) - BOUND_SLACK_SEC
        except (TypeError, ValueError):
            floor = now - UNBOUND_FRESH_SEC
        cwd = marker.get("cwd") or payload.get("cwd")
        # A truncated inventory cannot prove novelty: a file missing from it
        # may simply be one that did not fit. None disables the novelty test
        # entirely -- an empty set would instead make every file look novel,
        # which is how recency creeps back in.
        if marker.get("inventory_complete") is False:
            exclude = None
        else:
            exclude = set(marker.get("pre_existing") or [])
        tag = marker.get("tag") or session_tag(session_id)
        allow_recency = False
    else:
        # No marker. On a MANUAL compaction that means the user ran
        # /sdp:precompact themselves and then /compact, so recency is a
        # reasonable last resort -- a deliberate act by someone who knows what
        # they just wrote.
        #
        # On an AUTOMATIC compaction it means the opposite: the Stop hook never
        # recorded a request, so this session has no claim on anything in the
        # directory. Recency there would bind whatever happens to be newest,
        # which on a shared directory is as likely to be another session's.
        # That path is reachable whenever detection is silent -- an unreadable
        # transcript format, for instance -- so it must bind nothing.
        floor = now - UNBOUND_FRESH_SEC
        cwd = payload.get("cwd")
        exclude = None
        tag = session_tag(session_id)
        allow_recency = payload.get("trigger") == "manual"

    snapshot = find_snapshot(cwd, floor, tag, exclude, allow_recency)
    if snapshot is None and not marker:
        # Nothing was asked for and nothing is bound: not a cycle, so not a row.
        return 0
    _log_cycle(session_id, payload, marker, now, bound=snapshot is not None,
               path=snapshot or "")

    record = dict(marker)
    record["state"] = "snapshotted"
    record["at"] = now
    record["trigger"] = payload.get("trigger") or "unknown"
    record["cwd"] = cwd or ""
    if snapshot:
        record["snapshot"] = snapshot
    write_marker(session_id, record)
    return 0


def hook_start() -> int:
    """SessionStart, every source. Binds the pane; resumes after a compaction.

    One hook rather than two on the same event. The Stop hook refreshes the
    binding each turn, but a compaction can be asked for inside the first turn,
    before any Stop has run, so it has to exist from session start. Folding the
    resume into the same verb also removes the ordering question between two
    entries firing on one event.
    """
    payload = read_hook_input()
    session_id = payload.get("session_id")
    if isinstance(session_id, str) and session_id:
        bind_pane(session_id)
    if payload.get("source") == "compact":
        return hook_resume(payload)
    return 0


def cmd_inject(argv: list) -> int:
    """Wait for the session to go idle, then type the given text and submit it.

    Runs detached from whatever started it, because the wait can be long. Every
    give-up path is silent: the injected context is already in place, so the
    worst case is the behaviour that existed before -- the user types something
    and the model resumes on that turn.

    A third argument makes the send conditional on a self-fire intent that is
    still live. The queued compaction uses it: if the host compacts on its own
    first, the resume path consumes the intent and this waiter drops its
    ``/compact`` rather than trigger a second, redundant compaction.
    """
    pane_key = argv[0] if argv else ""
    prompt = argv[1] if len(argv) > 1 else RESUME_INJECT_PROMPT
    require_intent = argv[2] if len(argv) > 2 else ""
    nonce = argv[3] if len(argv) > 3 else ""
    def give_up() -> int:
        # An intent that outlives its failed compaction is live for minutes and
        # will fire a resume prompt at whatever the user compacts next. Only a
        # send that actually happened may leave it standing.
        if require_intent:
            clear_self_fire_intent(require_intent, nonce)
        return 0

    # Checked after give_up exists, not before: a waiter that finds no driver
    # still owns an intent, and leaving it standing arms a resume prompt for
    # whatever the user compacts next.
    if not pane_key or not orca_bin():
        return give_up()

    handle = resolve_handle(pane_key)
    if not handle:
        # Gone, or ambiguous. Retrying cannot make it unambiguous, and guessing
        # is what types into the wrong session.
        return give_up()
    if not wait_tui_idle(handle):
        return give_up()

    # Still wanted? An automatic compaction may have arrived while this waited,
    # in which case the resume path already consumed the intent and this send
    # would compact a second time for no reason.
    if require_intent and not peek_self_fire_intent(require_intent, nonce):
        return 0

    # Re-resolve immediately before sending: the handle rotates across a
    # compaction, and this has just spent up to two minutes waiting.
    send_handle = resolve_handle(pane_key)
    if not send_handle:
        return give_up()
    # Codex does not run SessionStart(compact) until a following message starts,
    # so that hook cannot itself create the message which wakes it. Capture the
    # rollout end immediately before submitting /compact; only a later compact
    # lifecycle may release the resume send. Claude has no Codex rollout and
    # keeps the hook-owned fallback.
    codex_watch = (
        codex_rollout_watermark(require_intent)
        if prompt == "/compact" and require_intent
        else None
    )
    status, info = send_prompt(send_handle, prompt)
    if status == SEND_LEGACY:
        # Round-2 review F5: a send that proceeded WITHOUT proof is recorded too,
        # or `doctor` reports only the cycles that stopped and none of the ones
        # that continued on an unverifiable host.
        note_submission(require_intent, nonce, prompt, status, info,
                        "continued without proof (driver cannot observe)")
    elif status != SEND_PROVEN:
        # Failing to OBSERVE a submission is not evidence that it did not happen.
        # A compaction that already started leaves an ACTIVE marker behind it, and
        # disarming that cycle would strand work the host is already compacting.
        #
        # Round-3 review F1: there is ONE continuation point. Whichever read finds
        # the marker, a kept cycle goes on to the rollout waiter when one is armed
        # -- an earlier revision returned from the second branch and silently
        # dropped the resume the waiter owns.
        #
        # Round-3 review F4: nothing claims a release before it happens. The
        # record written ahead of `give_up()` says it was ATTEMPTED; only the one
        # written afterwards says it was done. An interrupted waiter therefore
        # leaves an honest record instead of asserting an action it never took.
        kept = bool(require_intent) and marker_active(require_intent)
        if not kept:
            note_submission(require_intent, nonce, prompt, status, info,
                            "intent release attempted: no sign the compaction started")
            # Re-read after the write, the last moment before the release. A marker
            # that appeared meanwhile means the compaction did start after all.
            kept = bool(require_intent) and marker_active(require_intent)
        if kept:
            note_submission(require_intent, nonce, prompt, status, info,
                            "intent kept: this cycle's compaction is under way")
        else:
            give_up()
            note_submission(require_intent, nonce, prompt, status, info,
                            "intent released: no sign the compaction started")
            return 0
        if not codex_watch:
            return 0
        # A kept cycle with an armed watcher falls through to it below.

    if codex_watch:
        rollout, offset = codex_watch
        if not wait_codex_compaction_complete(rollout, offset):
            return give_up()
        # A future host may run SessionStart immediately after compact. In that
        # case it consumes the intent and owns the resume send; do not duplicate
        # it. On current Codex the intent remains, and this waiter must wake the
        # hook by submitting the first post-compact message itself.
        if not peek_self_fire_intent(require_intent, nonce):
            return 0
        if not mark_resume_dispatching(require_intent, nonce):
            return give_up()
        resumed_handle = resolve_handle(pane_key)
        if not resumed_handle or not wait_tui_idle(resumed_handle):
            return give_up()
        resumed_handle = resolve_handle(pane_key)
        if not resumed_handle:
            return give_up()
        resume_status, resume_info = send_prompt(resumed_handle, RESUME_INJECT_PROMPT)
        if resume_status == SEND_LEGACY:
            note_submission(require_intent, nonce, RESUME_INJECT_PROMPT, resume_status,
                            resume_info, "resume sent without proof")
        elif resume_status != SEND_PROVEN:
            note_submission(require_intent, nonce, RESUME_INJECT_PROMPT, resume_status,
                            resume_info, "resume not confirmed; nothing was re-sent")
            return give_up()
    return 0


def spawn_send_when_idle(
    pane_key: str, text: str, require_intent: str = "", nonce: str = ""
) -> bool:
    """Queue text to be typed once the session goes idle."""
    return spawn_inject(pane_key, text, require_intent, nonce)


def detach_kwargs(os_name: str = "") -> dict:
    """Popen keywords that outlive the caller, per platform.

    Split out so both branches can be exercised from either platform: on POSIX
    the Windows branch never runs, so a bug there would ship unseen.
    ``start_new_session`` is a setsid call and is ignored on Windows, where the
    child would stay attached to the console and die with it; the equivalent
    there is a creation flag.
    """
    name = os_name or os.name
    if name == "nt":
        flags = getattr(subprocess, "DETACHED_PROCESS", 0x00000008) | getattr(
            subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200
        )
        return {"creationflags": flags}
    return {"start_new_session": True}


def spawn_inject(
    pane_key: str, prompt: str, require_intent: str = "", nonce: str = ""
) -> bool:
    """Start the injector detached and return at once.

    Refuses outright while the suite is running. The suite exercises `resume`
    against a real session id, and on a machine that HAS a terminal driver the
    pane key resolves to the developer's own live terminal -- so without this
    gate the tests type into the window they are being run from. That happened.
    """
    if os.environ.get("SDP_PRECOMPACT_SELFTEST") == "1":
        return False
    if os.environ.get("SDP_PRECOMPACT_DRYRUN") == "1":
        sys.stderr.write("[dryrun] would inject via pane %s\n" % pane_key)
        return True
    argv = (
        [sys.executable, str(Path(__file__).resolve()), "inject", pane_key, prompt]
        + ([require_intent] if require_intent else [])
        + ([nonce] if require_intent and nonce else [])
    )
    # Detach so the waiter outlives the hook that started it. The mechanism is
    # not portable: start_new_session is a POSIX setsid call and is ignored on
    # Windows, where the child would stay attached to the console and die with
    # it. There the equivalent is a creation flag.
    detach = detach_kwargs()
    try:
        subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            **detach
        )
    except (OSError, ValueError):
        return False
    return True


def hook_resume(payload: object = None) -> int:
    """Inject the resume context after a compaction, then re-arm."""
    if not isinstance(payload, dict):
        payload = read_hook_input()
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return 0

    # The Codex waiter marks the intent immediately before it sends the message
    # that caused this hook to run. Spawning here in that case would create a
    # duplicate turn. A host that runs this hook first sees no mark and keeps
    # the original hook-owned fallback.
    intent_record = _read_json(intent_path(session_id))
    resume_already_dispatching = intent_record.get("resume_dispatching") is True

    # Consume the intent on every entry, valid marker or not. Leaving it behind
    # arms an unrelated later compaction to fire a resume prompt into whatever
    # the session is doing by then.
    intent_pane = take_self_fire_intent(session_id)

    marker = read_marker(session_id)
    if not marker:
        return 0

    snapshot = marker.get("snapshot")
    if isinstance(snapshot, str) and snapshot and Path(snapshot).is_file():
        context = RESUME_CONTEXT.format(snapshot=snapshot)
    elif marker.get("state") in ("pending", "snapshotted"):
        context = MISSING_SNAPSHOT_CONTEXT
    else:
        clear_marker(session_id)
        return 0


    # Clear before emitting: the next threshold crossing must be able to re-arm,
    # and a marker left behind would suppress it for the rest of the session.
    clear_marker(session_id)

    # Who types the first post-compaction message.
    #
    # After an AUTOMATIC compaction the host resumes the turn itself and acts
    # on the context above straight away; injecting there would add a second,
    # competing turn. After a MANUAL one the host returns to the prompt and the
    # context sits unread, so someone has to type -- and only if this cycle
    # asked for that, which is what the one-shot intent records. The global
    # mode is deliberately not consulted: it governs detection, not consent to
    # this particular unattended cycle.
    trigger = marker.get("trigger")
    if (
        trigger == "manual"
        and intent_pane
        and not resume_already_dispatching
        and driver_ready(intent_pane)
    ):
        spawn_inject(intent_pane, RESUME_INJECT_PROMPT)

    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": context,
            }
        },
        sys.stdout,
    )
    return 0


# --------------------------------------------------------------------------
# doctor / config CLI
# --------------------------------------------------------------------------


def cmd_doctor() -> int:
    """Loud health report.

    A half-installed automation that reports success is the failure mode this
    exists to prevent, so every unmet precondition is printed as a FAIL line
    and sets a non-zero exit.
    """
    problems = 0
    out = sys.stdout.write

    mode = resolve_mode()
    out("mode              : %s\n" % mode)
    out("config file       : %s%s\n" % (config_path(), "" if config_path().is_file() else "  (absent)"))
    out("threshold         : %.0f%%\n" % resolve_threshold())
    out("state dir         : %s\n" % state_dir())

    # A send that was accepted but never proven to submit is the one failure this
    # feature can hit while every exit status stays 0. It is reported here rather
    # than left for the user to infer from a prompt stranded in the composer.
    latest = None
    try:
        for entry in state_dir().iterdir():
            if not entry.name.endswith(".submit.json"):
                continue
            record = _read_json(entry)
            if not record or record.get("status") in ("", SEND_PROVEN):
                continue
            if latest is None or float(record.get("at") or 0) > float(latest.get("at") or 0):
                latest = record
    except OSError:
        latest = None
    if latest:
        out("last send         : %s (%s) -- %s\n" % (
            latest.get("status", "?"), latest.get("prompt", ""), latest.get("detail", "")))
        # Round-2 review F5: print the disposition that was RECORDED, never a
        # fixed sentence -- an unconfirmed send may have kept the cycle armed.
        disposition = latest.get("disposition") or "disposition not recorded"
        out("        %s\n" % disposition)
        # Round-3/4 review F4: the advice follows that disposition, and NO
        # disposition earns an unconditional re-run. Releasing the intent disarms
        # the automatic resume; it does not cancel a prompt the driver already
        # accepted, which may still be queued or running. Every path therefore
        # ends at "look at the session first".
        out("        Nothing was re-sent. The accepted prompt may still be queued\n")
        out("        or running -- check the session before sending anything again.\n")
        if disposition.startswith("intent released"):
            out("        That cycle is disarmed: once the session is clear, re-run to retry.\n")

    if mode != "auto":
        out("FAIL  automatic detection is off. Enable it with:\n")
        out("        python3 %s config set auto\n" % Path(__file__).resolve())
        problems += 1

    hooks_file = Path(__file__).resolve().parent.parent / "hooks" / "hooks.json"
    if hooks_file.is_file():
        out("hooks manifest    : %s\n" % hooks_file)
        try:
            events = sorted(json.loads(hooks_file.read_text(encoding="utf-8")).get("hooks", {}))
        except (OSError, ValueError):
            events = []
        expected = ["PreCompact", "SessionStart", "Stop"]
        out("hook events       : %s\n" % (", ".join(events) or "none"))
        missing = [event for event in expected if event not in events]
        if missing:
            out("FAIL  hooks manifest is missing: %s\n" % ", ".join(missing))
            problems += 1
    else:
        out("FAIL  hooks manifest not found next to this script: %s\n" % hooks_file)
        problems += 1

    # The state directory must be writable or the Stop hook cannot record a
    # marker, and an unrecorded marker means it stays silent rather than
    # blocking repeatedly. Silent is safe but it is also invisible, so probe it.
    # Cycle history. Reported because the Codex-side threshold is meant to be
    # set from these rows and cannot be set without them (KNOWN_GAPS NC-34),
    # and because a run of "missing" is the one symptom of a threshold with no
    # headroom left -- which is otherwise invisible until a snapshot is lost.
    rows = read_cycles()
    if rows:
        out("cycle ledger      : %s\n" % cycles_path())
        current = [r for r in rows if r.get("contract_rev") == CYCLE_CONTRACT_REV]
        stale = len(rows) - len(current)
        out("cycles recorded   : %d usable, %d from an older contract revision\n"
            % (len(current), stale))
        # Grouped, never pooled. A headroom fitted across two hosts is fitted to
        # neither: the whole finding behind NC-34 is that Claude and Codex
        # compact at different points in the same percentage scale.
        # Keyed on the STOP-time readings alone. "host" and "context_limit"
        # each fall back to the other end of the cycle when their own side is
        # missing, so a row whose two ends disagree would be filed under one
        # end's host and the other's window -- a group that describes no real
        # session. The threshold is read off these counts, so a row in the
        # wrong group is worse than a row in no group.
        groups: dict = {}
        unattributable = 0
        for r in current:
            if not r.get("requested"):
                continue
            host = r.get("host_at_stop") or ""
            limit = r.get("context_limit_at_stop") or 0
            if not host or not limit:
                unattributable += 1
                continue
            g = groups.setdefault((host, limit), {"n": 0, "missing": 0, "costs": []})
            g["n"] += 1
            if r.get("outcome") == "missing":
                g["missing"] += 1
            cost = r.get("turn_cost_upper_bound")
            if isinstance(cost, int) and r.get("comparable_measurement"):
                g["costs"].append(cost)
        if unattributable:
            out("  %d requested cycle(s) name no host or window and are grouped nowhere\n"
                % unattributable)
        if not groups:
            out("        no attributable hook-requested cycles yet\n")
        for (host, limit), g in sorted(groups.items()):
            out("  %-7s window %-8s: %d requested, %d lost the snapshot\n"
                % (host, limit or "?", g["n"], g["missing"]))
            costs = sorted(g["costs"])
            if not costs:
                out("        no comparable cost samples\n")
                continue
            out("        turn cost upper bound: n=%d  min %d  median %d  max %d\n"
                % (len(costs), costs[0], costs[len(costs) // 2], costs[-1]))
            if len(costs) < CYCLES_FOR_THRESHOLD:
                out("        %d of %d samples -- not enough to set a headroom from.\n"
                    % (len(costs), CYCLES_FOR_THRESHOLD))
                out("        The provisional threshold stands. See KNOWN_GAPS NC-34.\n")
    else:
        out("cycle ledger      : none yet (%s)\n" % cycles_path())

    probe = state_dir() / ".doctor-probe.json"
    if _write_json(probe, {"probe": True}):
        out("state dir writable: yes\n")
        try:
            os.unlink(probe)
        except OSError:
            pass
    else:
        out("FAIL  state directory is not writable: %s\n" % state_dir())
        problems += 1

    transcript = os.environ.get("SDP_PRECOMPACT_TRANSCRIPT")
    if transcript:
        pct, used, limit, model, exact = measure_context(transcript)
        # A transcript is named for its session, and the hook applies the
        # session's remembered window on top of the measurement. Reporting the
        # raw measurement would contradict what the hook actually decides.
        sid = Path(transcript).stem
        if sid and not exact:
            limit = sticky_window(sid, limit)
            pct = (used / limit * 100.0) if limit > 0 else 0.0
        out(
            "measured context  : %d / %d tokens (%.1f%%), model %s, window %s\n"
            % (used, limit, pct, model, "host-stated" if exact else "inferred")
        )
        out("would block       : %s\n" % ("yes" if pct >= resolve_threshold() else "no"))
    else:
        out("measured context  : pass SDP_PRECOMPACT_TRANSCRIPT=<session .jsonl> to measure\n")

    # Whether the host has actually registered these hooks is not observable
    # from here. Codex skips a plugin's hooks until they are trusted in /hooks,
    # and saying "armed" without that check is the same overclaim that let the
    # design this replaces report success while its detector was dead.
    out("hook trust        : not verifiable from here; on Codex the plugin's\n")
    out("                    hooks stay skipped until trusted via /hooks\n")

    markers = []
    if state_dir().is_dir():
        try:
            markers = sorted(
                entry.name
                for entry in state_dir().iterdir()
                if entry.name.endswith(".json")
                and not entry.name.endswith(SIDECAR_SUFFIXES)
                # Named explicitly rather than relying on ".ndjson" not ending
                # in ".json". It does not, but a reader should not have to
                # verify that to know the ledger is not a pending marker.
                and entry.name != CYCLES_BASENAME
            )
        except OSError:
            markers = []
    out("live markers      : %s\n" % (", ".join(markers) or "none"))
    # Run-continuation (issue #5) is armed per worktree, not by this config, so
    # report it for the directory doctor runs in. Informational, never a FAIL.
    run_root = find_run_root(os.getcwd())
    run_record = read_run_record(run_root) if run_root is not None else {}
    if run_record:
        out("run record        : %s (dispatch=%s, max idle blocks=%d)\n"
            % (run_record_path(run_root), run_record.get("dispatch", "?"), _idle_max(run_record)))
    else:
        out("run record        : none here -- run-continuation is not armed for this cwd\n")

    if problems == 0:
        out("OK    configuration is armed. Confirm the host registered the hooks:\n")
        out("        Claude -- /hooks lists this plugin's Stop, PreCompact and SessionStart\n")
        out("        Codex  -- /hooks shows them trusted, not skipped\n")
    else:
        out("%d problem(s) found.\n" % problems)
    return 1 if problems else 0


def _verified_snapshot(raw: str, cwd: str) -> str:
    """The given path, only if it is one of this project's own snapshots.

    Resolved and compared against the enumerated set rather than pattern
    matched, so nothing outside the snapshot tree can be named -- and the
    enumeration is the same one that already refuses symlinks and non-regular
    files.
    """
    if not raw or not cwd:
        return ""
    try:
        resolved = str(Path(raw).resolve(strict=True))
    except OSError:
        return ""
    known = {path for path, _ in list_snapshots(cwd)}
    return resolved if resolved in known else ""


def cmd_compact(argv: list = ()) -> int:
    """Type `/compact` into this session's own input box.

    The command calls this after the snapshot is on disk. It is the one step
    neither a hook nor a skill can do for itself: hooks cannot expand a slash
    command, and no host exposes a programmatic compaction trigger. Prints the
    resolved handle on success; exits non-zero, silently, when there is no
    driver or no unambiguous pane, and the caller then falls back to telling
    the user to run `/compact` themselves.
    """
    # The snapshot this cycle just wrote. Passing it is what keeps the binding
    # deterministic: a hand-run command writes an UNTAGGED file, and if the
    # directory already holds another recent one, PreCompact cannot tell them
    # apart, refuses to bind either, and the cycle ends with the context gone
    # and no resume context at all.
    snapshot = ""
    raw = argv[0] if argv else ""
    if raw:
        # Membership in the enumerated snapshot set, not a string test on the
        # path. A substring check accepts /tmp/x.private/precompact-evil/a,
        # and list_snapshots already refuses symlinks, reparse chains and
        # anything that is not a regular precompact_*.md in a day directory.
        snapshot = _verified_snapshot(raw, os.getcwd())
        if not snapshot:
            sys.stderr.write("not a snapshot of this project: %s\n" % raw)
            return 1

    pane_key = tool_pane_key()
    if not driver_ready(pane_key):
        sys.stderr.write("no terminal driver bound to this session\n")
        return 1
    handle = resolve_handle(pane_key)
    if not handle:
        sys.stderr.write("pane not resolvable to exactly one live terminal\n")
        return 1

    # The intent is what makes the resume injection happen after the
    # compaction. Queueing a compaction we cannot pair with an intent produces
    # the worst outcome available: the context is destroyed and nothing types
    # the first message afterwards. So the intent is written FIRST, and a
    # failure at any step here refuses rather than half-commits.
    session_id = tool_session_id()
    if not session_id:
        sys.stderr.write("cannot identify this session; refusing to queue\n")
        return 1
    # One queued compaction at a time. A second call would overwrite the first
    # intent while its waiter is still running, and both waiters would then
    # send. The command documents "do not retry"; this enforces it.
    if peek_self_fire_intent(session_id):
        sys.stderr.write("a compaction is already queued for this session\n")
        return 1
    nonce = set_self_fire_intent(session_id, pane_key, snapshot)
    if not nonce:
        sys.stderr.write("could not record the self-fire intent; refusing to queue\n")
        return 1

    # QUEUE, never send from here. This runs inside a tool call, so the turn is
    # still going and text submitted now would steer it rather than start a new
    # one. The detached waiter blocks on the driver's own idle condition, which
    # is only satisfied once this turn actually ends.
    if not spawn_send_when_idle(pane_key, "/compact", session_id, nonce):
        clear_self_fire_intent(session_id, nonce)
        sys.stderr.write("could not queue the compaction\n")
        return 1
    sys.stdout.write("queued for %s\n" % handle)
    return 0


def cmd_config(argv: list) -> int:
    if not argv or argv[0] == "get":
        sys.stdout.write(resolve_mode() + "\n")
        return 0
    if argv[0] == "set" and len(argv) >= 2:
        try:
            sys.stdout.write(write_mode(argv[1]) + "\n")
        except ValueError as exc:
            sys.stderr.write(str(exc) + "\n")
            return 2
        except OSError as exc:
            # Reporting success here is how someone ends up believing the
            # automation is armed when nothing was saved.
            sys.stderr.write("failed to save mode: " + str(exc) + "\n")
            return 1
        return 0
    sys.stderr.write("usage: precompact_hook.py config [get | set auto|manual]\n")
    return 2


def main(argv: list[str]) -> int:
    command = argv[0] if argv else ""
    if command == "stop":
        return hook_stop()
    if command == "precompact":
        return hook_precompact()
    if command == "resume":
        return hook_resume()
    if command == "start":
        return hook_start()
    if command == "doctor":
        return cmd_doctor()
    if command == "config":
        return cmd_config(argv[1:])
    if command == "inject":
        return cmd_inject(argv[1:])
    if command == "compact":
        return cmd_compact(argv[1:])
    if command == "run":
        return cmd_run(argv[1:])
    sys.stderr.write(
        "usage: precompact_hook.py "
        "{stop | precompact | start | resume | inject | compact | doctor | config | run}\n"
    )
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except BaseException:  # noqa: BLE001 - a hook must never wedge the session
        if os.environ.get("SDP_PRECOMPACT_DEBUG") == "1":
            raise
        raise SystemExit(0)
