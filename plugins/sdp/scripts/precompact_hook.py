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
import pwd
import stat
import sys
import time
from pathlib import Path

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
    return Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(strict=True)


def sdp_home() -> Path:
    return passwd_home() / SDP_HOME_DIRNAME


def config_path() -> Path:
    return sdp_home() / CONFIG_BASENAME


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
    except (OSError, ValueError, KeyError):
        return ""
    return str(resolved)


def state_dir() -> Path:
    override = _selftest_override("SDP_PRECOMPACT_STATE_DIR")
    return Path(override) if override else sdp_home() / STATE_DIRNAME


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
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
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
    _write_json(config_path(), current)
    return mode


# --------------------------------------------------------------------------
# context measurement
# --------------------------------------------------------------------------


def explicit_window() -> int | None:
    """A window the operator stated outright. Overrides every inference."""
    for name in ("SDP_PRECOMPACT_CONTEXT_TOKENS", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"):
        try:
            value = int(os.environ.get(name))  # type: ignore[arg-type]
        except (TypeError, ValueError):
            continue
        if value > 0:
            return value
    return None


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


def context_limit(model: str | None, observed_tokens: int = 0, cwd: str = "") -> int:
    """Usable context window in tokens.

    Hook stdin carries no context-usage field and a plugin cannot ship a
    statusLine, so the window has to be inferred from what is on disk. The
    model id in the transcript is NOT reliable for this: a wide-window session
    records plain ``claude-opus-5``, with no ``[1m]`` marker, so trusting it
    would under-read the window by 5x and fire on nearly every turn.

    Order: an explicit override wins; then the largest context this session has
    actually reached, which cannot lie; then the user's model setting; then the
    narrow default.
    """
    explicit = explicit_window()
    if explicit is not None:
        return explicit
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


def measure_context(
    transcript_path: str | None, cwd: str = ""
) -> tuple[float, int, int, str | None]:
    """Return (pct, used_tokens, limit, model) from the newest usage record.

    The transcript records per-assistant-message usage. Context occupancy is
    input + cache_creation + cache_read; output tokens are not resident.
    """
    if not transcript_path:
        return (0.0, 0, DEFAULT_CONTEXT_TOKENS, None)

    latest_used: int | None = None
    latest_model: str | None = None
    peak_used = 0

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
        return (0.0, 0, DEFAULT_CONTEXT_TOKENS, None)

    limit = context_limit(latest_model, peak_used, cwd)
    pct = (latest_used / limit * 100.0) if limit > 0 else 0.0
    return (pct, latest_used, limit, latest_model)


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
    try:
        day_dirs = sorted(base.iterdir())
    except OSError:
        return found
    for day_dir in day_dirs:
        if not day_dir.is_dir():
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
# marker state
# --------------------------------------------------------------------------


def _safe_session(session_id: str) -> str:
    return "".join(ch for ch in session_id if ch.isalnum() or ch in "-_")


def marker_path(session_id: str) -> Path:
    return state_dir() / (_safe_session(session_id) + ".json")


def window_path(session_id: str) -> Path:
    return state_dir() / (_safe_session(session_id) + ".window.json")


WINDOW_PRUNE_SEC = 7 * 24 * 3600


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
    """Drop window records for sessions that ended long ago."""
    cutoff = time.time() - WINDOW_PRUNE_SEC
    try:
        entries = list(state_dir().iterdir())
    except OSError:
        return
    for entry in entries:
        if not entry.name.endswith(".window.json"):
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
    pct, used, limit, model = measure_context(
        payload.get("transcript_path"), payload.get("cwd") or ""
    )
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

    now = time.time()
    marker = read_marker(session_id)
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
        # Manual route: the user ran /sdp:precompact and then /compact, so there
        # is no marker and no inventory. Only the tag can bind here, and the
        # user is unlikely to have typed it, so fall back to recency -- the
        # manual route is a deliberate act by someone who knows what they wrote.
        floor = now - UNBOUND_FRESH_SEC
        cwd = payload.get("cwd")
        exclude = None
        tag = session_tag(session_id)
        allow_recency = True

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


def hook_resume() -> int:
    """SessionStart(compact) hook: inject the resume context, then re-arm."""
    payload = read_hook_input()
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return 0

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
        pct, used, limit, model = measure_context(transcript)
        # A transcript is named for its session, and the hook applies the
        # session's remembered window on top of the measurement. Reporting the
        # raw measurement would contradict what the hook actually decides.
        sid = Path(transcript).stem
        if sid:
            limit = sticky_window(sid, limit)
            pct = (used / limit * 100.0) if limit > 0 else 0.0
        out("measured context  : %d / %d tokens (%.1f%%), model %s\n" % (used, limit, pct, model))
        out("would block       : %s\n" % ("yes" if pct >= resolve_threshold() else "no"))
    else:
        out("measured context  : pass SDP_PRECOMPACT_TRANSCRIPT=<session .jsonl> to measure\n")

    markers = []
    if state_dir().is_dir():
        try:
            markers = sorted(
                entry.name
                for entry in state_dir().iterdir()
                if entry.name.endswith(".json") and not entry.name.endswith(".window.json")
            )
        except OSError:
            markers = []
    out("live markers      : %s\n" % (", ".join(markers) or "none"))

    if problems == 0:
        out("OK    precompact automation is armed.\n")
    else:
        out("%d problem(s) found.\n" % problems)
    return 1 if problems else 0


def cmd_config(argv: list[str]) -> int:
    if not argv or argv[0] == "get":
        sys.stdout.write(resolve_mode() + "\n")
        return 0
    if argv[0] == "set" and len(argv) >= 2:
        try:
            sys.stdout.write(write_mode(argv[1]) + "\n")
        except ValueError as exc:
            sys.stderr.write(str(exc) + "\n")
            return 2
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
    if command == "doctor":
        return cmd_doctor()
    if command == "config":
        return cmd_config(argv[1:])
    sys.stderr.write(
        "usage: precompact_hook.py {stop | precompact | resume | doctor | config}\n"
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
