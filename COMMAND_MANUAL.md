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

---

## Where the output goes

All commands write under the configured `base_dir` (default `.private/sdp-artifacts`):

```
.private/sdp-artifacts/{YYYY-MM-DD}/{topic}/{doc-type}
```

`.private/` is created and added to `.gitignore` automatically on first run. Deliverable language follows `output_locale` in the anchor-selected `defaults.yaml` — same discovery order as above (`auto` = the language of your environment).
