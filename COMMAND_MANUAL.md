# SDP command manual

Four commands. The first three run the same SDP core (Stages 1–8, two gates); they differ only in how the work is split and where it runs.

> **Invocation.** In Claude Code use the slash form `/sdp …`. In Codex use the skill form `$sdp:sdp …`. Both are shown below; pick the one your host uses.

| Command | Use it for |
|---|---|
| [`sdp`](#sdp) | One task, run serially through Stages 1–8 |
| [`batch-sdp`](#batch-sdp) | A large scope, split into segments and run one after another |
| [`worktree-dispatch`](#worktree-dispatch) | Several independent tasks, run in parallel git worktrees |
| [`precompact`](#precompact) | Save work state and a resume prompt before compacting context |

---

## `sdp`

Runs one task through interview → design → implementation → test → verification, applying the review gate to the plan (Gate A) and to the test results (Gate B).

```text
/sdp add a per-user login attempt limit
```
```text
$sdp:sdp add a per-user login attempt limit
```

Small, low-risk tasks take a fast-path that collapses the interview and skips the standalone design document — the gates still run.

**Use it when** the work is one coherent change you want done end to end in this session.

---

## `batch-sdp`

Splits a large scope into independent segments, then runs the full SDP workflow on each segment in turn. Suitable when the pieces have ordering dependencies.

```text
/batch-sdp implement the complete user management feature
```
```text
$sdp:batch-sdp implement the complete user management feature
```

Engine is selected by `dispatch.batch_engine` in the **anchor-selected** `defaults.yaml`. Discovery runs project `.sdp/` → project `scripts/sdp/` → `$XDG_CONFIG_HOME/sdp/` **only when that variable is explicitly set, otherwise passwd-home `~/.config/sdp/`** → passwd-home `~/.sdp/`. The first **safe, existing** candidate wins; a present but unsafe or unreadable one aborts discovery rather than falling through. A user-global file counts: a missing project-local `.sdp/defaults.yaml` does **not** mean the key is unset, and with `XDG_CONFIG_HOME` unset the file actually read is usually `~/.config/sdp/defaults.yaml`. See [Configuration](README.md#configuration) for the no-weakening and fail-closed rules.

| Value | Behavior |
|---|---|
| `agent_tool` (default) | Each segment runs as a subagent in this session. No extra tooling. |
| `tmux_long_lived` | One long-lived **Codex** worker session per batch inside `tmux`; segments are pushed in as prompts. Requires `tmux`, `codex` and `git` on `PATH` and a git-backed cwd, otherwise falls back to `agent_tool`. Claude Code is used only by the review gates. |

Segment completion is signalled by a `STATUS.md` file, never by scraping the terminal.

**Use it when** the scope is too large for one pass but the pieces must land in order.

---

## `worktree-dispatch`

Interviews you once to settle a list of *mutually independent* tasks, then hands each one to its own git worktree to run the full SDP workflow in parallel.

```text
/worktree-dispatch
1. implement the login API
2. implement the user management screen
3. add the deploy configuration
```

A long list can live in a Markdown file instead:

```text
/worktree-dispatch run the task list in TASKS.md in parallel
```
```text
$sdp:worktree-dispatch run the task list in TASKS.md in parallel
```

**Preconditions.** The tasks must not share dependencies, modified files, database state, or ports. If they do, use `batch-sdp` instead.

Mode is selected by `dispatch.worktree_mode` in the anchor-selected `defaults.yaml` — same discovery order and same fail-closed rule as `dispatch.batch_engine` above, so `manual` means *the selected file sets no mode*, not *no project-local file exists*:

| Value | Behavior |
|---|---|
| `manual` (default) | Each task produces a handover document you launch yourself. |
| `auto` | Each worktree gets a headless **Codex** session spawned for it. Requires `tmux`, `codex` and `git`, otherwise falls back to `manual`. |

Worktree sessions produce verification checklists only. Runtime/screen tests run serially on main after merge (`worktree.runtime_isolation: serial_main`), unless the project opts into per-worktree ephemeral runtimes.

**Use it when** you have several unrelated changes and want them all moving at once.

---

## `precompact`

Utility command — does **not** run the SDP core. Writes the current work state to `.private/precompact/{date}/` and prints a resume prompt to paste into the next context.

```text
/precompact login-limit
```
```text
$sdp:precompact login-limit
```

**Use it when** the context window is filling up and you want the next session to pick up cleanly.

### Automatic mode (Claude host)

The plugin ships three hooks that link compaction to the next prompt, so nothing
has to be typed by hand:

1. **`Stop`** reads context usage from the session transcript. Past the threshold
   it answers `decision: block`, which gives the model one more tool-capable turn
   and tells it to write the snapshot.
2. **`PreCompact`** binds that snapshot to this `session_id`, so a second session
   working in the same directory cannot resume the wrong snapshot.
3. **`SessionStart`** (matcher `compact`) injects the snapshot path and resume
   instructions as `additionalContext`, then clears the marker so the cycle
   re-arms.

After an automatic compaction the host continues the turn on its own, so the work
resumes with no user input. After a manual `/compact` the injected context is used
on the next message instead.

It is off until each user turns it on, and an unset mode is never treated as on:

```bash
PLUGIN="$(ls -d ~/.claude/plugins/cache/sdp-marketplace/sdp/*/ | sort -V | tail -1)"
python3 "${PLUGIN}scripts/precompact_hook.py" config set auto   # or manual
python3 "${PLUGIN}scripts/precompact_hook.py" doctor            # health report
```

`doctor` exits non-zero and names every unmet precondition, so a half-installed
automation cannot report success. Pass `SDP_PRECOMPACT_TRANSCRIPT=<session .jsonl>`
to have it measure a real session and say whether it would block.

The threshold defaults to 78 percent of the context window — below the host's own
auto-compact point, so the snapshot wins the race. Override it with
`SDP_PRECOMPACT_THRESHOLD`, or `threshold` in `~/.sdp/precompact.json`.

The window itself has to be inferred: hooks receive no context-usage field, and the
model id recorded in a transcript is the same whether the session has a 200k or a
1M window. It is taken from the largest occupancy the session has actually reached
(including any recorded compaction), then from a configured `[1m]` model, and it
never narrows again within a session. A session that has never compacted and names
no wide model anywhere can therefore ask for a snapshot earlier than it needs to;
set `SDP_PRECOMPACT_CONTEXT_TOKENS` (or the host's `CLAUDE_CODE_MAX_CONTEXT_TOKENS`)
to settle it outright.

Both hosts support these three events and both auto-load a plugin's
`hooks/hooks.json`, so one manifest drives Claude Code and Codex. Two host
differences remain. Codex **skips a plugin's hooks until they are trusted** —
run `/hooks` there once and accept them, or they stay registered and never
fire. And the two hosts write different transcripts: Claude records
per-assistant `message.usage`, Codex records `token_count` events, and
occupancy is read from `last_token_usage.input_tokens` against the
`model_context_window` Codex states outright (never `total_token_usage`, which
is the cumulative session bill). Both come from the **same, newest** event: a
session can change model mid-flight, and dividing the latest usage by the
widest window the session ever had reads 210k of a 258400 window as 21% instead
of 81% — the threshold is never crossed and the snapshot is never taken.

A window the host states this way is used as-is. The remembered widen-only
window and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` are both devices for the case where
the window has to be inferred, and neither overrules it; a Claude-only variable
exported into a Codex session must not decide that session's window.
`SDP_PRECOMPACT_CONTEXT_TOKENS` remains the one override that outranks
everything, on either host.

Neither transcript format is a documented interface; if one changes,
measurement returns nothing and the hook stays silent rather than guessing.

`doctor` cannot see whether the host actually registered the hooks, so it
reports configuration only and names what to check.

---

## Where the output goes

All commands write under the configured `base_dir` (default `.private/sdp-artifacts`):

```
.private/sdp-artifacts/{YYYY-MM-DD}/{topic}/{doc-type}
```

`.private/` is created and added to `.gitignore` automatically on first run. Deliverable language follows `output_locale` in the anchor-selected `defaults.yaml` — same discovery order as above (`auto` = the language of your environment).
