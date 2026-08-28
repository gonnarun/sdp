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
context is acted on with no user input -- that is the automatic link between
compaction and the next prompt. After a MANUAL ``/compact`` the host returns to
the prompt, so the same context sits there until the user types anything.

Deliberately host-native: no terminal driver, no ``statusLine`` (a plugin cannot
ship one), no external process. Works in any terminal on either host.

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
import os
import shlex
import shutil
import stat
import subprocess
import sys
import time
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

RESUME_INJECT_PROMPT = (
    "Continue from the precompact snapshot named in the injected context. Read "
    "that file first, then resume from section 0 (Current Work) and section 2 "
    "(Remaining). Open with one line confirming the precompact cycle completed."
)

BLOCK_REASON = (
    "Context usage is at {pct:.0f}% of the window, past the SDP precompact "
    "threshold of {threshold:.0f}%. Auto-compact is close and will discard the "
    "working state. Before ending this turn, run the SDP precompact workflow "
    "now: gather the measured in-progress state and write the snapshot to "
    ".private/precompact/{today}/precompact_{{topic}}_{tag}.md following the "
    "precompact skill -- the _{tag} suffix is required, it is what binds this "
    "snapshot to this session. Infer the topic from the work in progress and "
    "say in one line what you picked; do not ask the user to choose. Write the "
    "file and nothing else -- do not print the resume prompt, do not start new "
    "work, and do not commit or push. The post-compact resume is injected "
    "automatically once the snapshot exists."
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
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
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
    if not transcript_path:
        return (0.0, 0, DEFAULT_CONTEXT_TOKENS, None, False)

    latest_used: int | None = None
    latest_model: str | None = None
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
            if codex_used > peak_used:
                peak_used = codex_used
            if latest_used is None:
                # Newest usable event wins, and its window comes with it.
                latest_used = codex_used
                declared_window = codex_window
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
        return (0.0, 0, DEFAULT_CONTEXT_TOKENS, None, False)

    limit = context_limit(latest_model, peak_used, cwd, declared_window)
    exact = declared_window > 0 and limit == declared_window
    pct = (latest_used / limit * 100.0) if limit > 0 else 0.0
    return (pct, latest_used, limit, latest_model, exact)


# --------------------------------------------------------------------------
# snapshot discovery
# --------------------------------------------------------------------------


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
    if done.returncode != 0:
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


def send_text(handle: str, text: str) -> bool:
    """Type text into a terminal and submit it.

    ``--enter`` is not optional: without it the text lands in the input box and
    sits there unsent, which reads as the feature silently doing nothing.
    """
    if not handle:
        return False
    argv = driver_argv(
        ["terminal", "send", "--terminal", handle, "--text", text, "--enter"]
    )
    if not argv:
        return False
    try:
        done = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return done.returncode == 0


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
    data = _orca_json(
        ["terminal", "wait", "--terminal", handle,
         "--for", "tui-idle", "--timeout-ms", str(int(timeout_ms)), "--json"],
        timeout_sec=(timeout_ms / 1000.0) + 15.0,
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
    if wait.get("condition") != "tui-idle":
        return False
    # The reply names the handle it is about, and it must be the one asked
    # about. Measured on a real idle terminal: result.wait carries handle,
    # condition, satisfied, status and exitCode. Requiring it stops a cached or
    # malformed success for some other terminal reading as "this pane is idle".
    if wait.get("handle") != handle:
        return False
    return wait.get("satisfied") is True


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
# Files that sit beside a marker but are not one. doctor must not report
# them as pending snapshot requests, and the prune has to reach them or
# they accumulate one per session forever.
SIDECAR_SUFFIXES = (".window.json", ".pane.json", ".selffire.json")


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


def hook_stop() -> int:
    """Stop hook: detect the threshold, block once, and demand the snapshot."""
    payload = read_hook_input()
    # The host sets this on the Stop that follows a block. Honouring it is what
    # bounds the loop -- without it the same block repeats to the host's cap.
    session_id_for_bind = payload.get("session_id")
    if isinstance(session_id_for_bind, str):
        # Every turn, cheaply: the tool that later queues a compaction cannot
        # read the pane key from its own environment on every host.
        bind_pane(session_id_for_bind)
    if payload.get("stop_hook_active"):
        return 0
    # A subagent finishing raises SubagentStop, not Stop, but an agent_id here
    # would still mean this is not the main thread. Never block a subagent.
    if payload.get("agent_id"):
        return 0
    if not is_auto_enabled():
        return 0

    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return 0

    now = time.time()
    marker = read_marker(session_id)
    if marker and marker_is_live(marker, now):
        return 0

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
        return 0

    cwd = payload.get("cwd") or ""
    tag = session_tag(session_id)
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
            "cwd": cwd,
            "tag": tag,
            "pre_existing": existing,
            "inventory_complete": inventory_complete,
        },
    )
    if not persisted:
        # Without a marker nothing suppresses the next detection, so blocking
        # here would block again, and again. Stay silent instead.
        return 0
    reason = BLOCK_REASON.format(
        pct=pct,
        threshold=threshold,
        today=time.strftime("%Y%m%d", time.localtime(now)),
        tag=tag,
    )
    json.dump({"decision": "block", "reason": reason}, sys.stdout)
    return 0


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
        return 0

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
    if not send_text(send_handle, prompt):
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
    if trigger == "manual" and intent_pane and driver_ready(intent_pane):
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
            )
        except OSError:
            markers = []
    out("live markers      : %s\n" % (", ".join(markers) or "none"))

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
    sys.stderr.write(
        "usage: precompact_hook.py "
        "{stop | precompact | start | resume | inject | compact | doctor | config}\n"
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
