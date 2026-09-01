# SDP gate operations

**Root-only. This file is not shipped in `plugins/sdp/` and is never read by an agent as instructions.**

Operator procedures live here rather than in either `README.md` because a shipped,
agent-read document that carries a copy-pasteable command for mutating gate state is a
laundering primitive by construction. Nothing in this file mutates gate state, and the
two READMEs point here and carry no commands.

Any timestamp written by hand uses the POSIX form `date -u +%Y-%m-%dT%H:%M:%SZ`. Never use
`%N` or `%6N`: they are GNU extensions, and BSD/macOS `date` **emits them literally and exits
0**, so a documented `|| date -u +%Y-%m-%dT%H:%M:%SZ` fallback can never fire. The engine
itself never shells out to `date` at all — every timestamp it writes comes from Python.

---

## Deploy

**A repo-local commit changes nothing for any consumer**, including the very sessions a gate
fix exists to unblock. The plugin cache at `~/.claude/plugins/cache/sdp-marketplace/sdp/<version>/`
is a **plain, version-keyed copy** — not a symlink and not a git checkout — so every change is
**inert** until a human performs all four of these steps:

1. `git push`
2. `git -C ~/.claude/plugins/marketplaces/sdp-marketplace pull`
3. Reinstall the plugin. This creates a new version-keyed cache directory;
   `.githooks/pre-commit` already bumped the version manifests as a cachebuster.
4. **Restart every live session.** The `.in_use/<pid>` refcount keeps old copies alive
   otherwise, and the restart is what closes the old-engine parity drift recorded as
   `NC-19` in `docs/KNOWN_GAPS.md` — an engine that does not know a log head counts it
   toward `max_block`.

Step 4 is an **instruction, not a mechanism**: the refcount probe is not wired into the
deploy procedure, and it cannot see an engine invoked from a checkout or from the generated
root mirror at all (`NC-20`).

Two engine versions coexisting on disk after a deploy is **harmless**: both use the same key
scheme and the same files, so there is no split-brain and no migration. Reverting is
"reinstall the previous version and restart sessions"; markers already written stay readable.

---

## Deferred: gate-state key migration

The gate-state key scheme change, its directory move and its migration are **deferred to a
standalone dispatch** (`NC-02`). The successor is an offline tool a human runs **once**, inside
a quiescent window, between "all sessions stopped" and "new engine in use": walk
`<gate>/review_gate_*.log`, derive the new key **and** the new directory for each, copy with a
manifest, and refuse on any physical anomaly. Rollback is "run the tool in reverse in the same
window". Crash-safety is "rerun the tool — it is idempotent, because nothing else writes."

The following **eight obligations are binding preconditions on that dispatch's design, not
suggestions**. Their owner is that dispatch's Stage-4 author.

1. State that the quiescence precondition is **procedural, not mechanical**, and enumerate the
   unprobeable class by name: a `.in_use/<pid>` probe sees only plugin-cache-installed
   engines, so a developer or test invoking a checkout's own `scripts/review_gate.py`, or the
   generated root mirror, is an old engine **with no ref file at all** — and a missing ref file
   is fail-**open**, unlike `kill -0` on a recycled pid, which is fail-closed.
2. Migrate the **directory** as well as the key, in **one operation with one manifest**. The
   deleted migration apparatus moved keys *within* a directory and never covered the directory
   itself.
3. The tool's **own** state files — its manifest and its lock — must be inside its
   physical-validation scope **from the first draft**. This is the exact defect that generated a
   whole gate round and it must not recur. Carry the `O_NOFOLLOW` / `lstat` point with it:
   `_state_lock` opens its lock file with `O_CREAT|O_RDWR` and **follows a symlink**.
4. Whatever config key selects the tool's behaviour, its **absent-and-unreadable default** must
   be stated in an ADR and pinned by a test. `_read_gates_yaml` returns `{}` on a missing file,
   on a symlink **and on any `OSError`**, so "absent" and "transiently unreadable" are the same
   input.
5. If the tool publishes via `os.link`, `st_nlink == 2` between the link and the unlink breaks
   any lock-free `nlink == 1` check — prefer `os.rename` from a temp file in the same directory.
6. Any concurrency assertion must be **timed against the window it claims to cover**, not
   against a shorter window that happens to contain the same call.
7. List the `tests/concurrency.sh` edit (the executable spec for `_state_lock`) and the
   `tests/codex_plugin.sh` edit (it asserts the shipped file set) for **any** file added or
   changed. `tests/run.sh`'s orphan detector globs `tests/*.sh` only, so a new `scripts/`
   executable is invisible to it.
8. The cross-worktree escalation bypass (`NC-01`) **remains open and approved**. This dispatch
   does not close it and it must not be reported as if it does.

---

## Reading gate state

All gate state for one artifact lives beside its log, under
`<base_dir>/gate/review_gate_<key>.*`. Everything below is **read-only**: this section
deliberately contains **no command that mutates gate state**, and in particular no redirection
into a `.log` and no removal or renaming of a `.halt`. Clearing a halt is a decision, not a
file operation, and the sanctioned paths for it are named in each row.

| File | Means | What clears it |
|---|---|---|
| `…​.log` | The append-only record of record: `BLOCK_ATTEMPT`, `ALLOW`, `INFRA_ERROR`, `RESET`, `OVERRIDE`, `PIVOT_RESET`, `TEAM_REVIEW` / `TEAM_CARRY`, `ESCALATION_STALL`, `MARKER_AUDIT_FAILED`. | Nothing. It is never rewritten. |
| `…​.halt` | The gate is **stuck** and refuses every review pre-provider. Written on an identical BLOCK reason twice, at `max_block`, at `max_stall` consecutive escalation stalls, and on a team `decision=halt`. | A human decision, applied through the attended override path or by the operator deliberately clearing the halt outside the tooling. There is no gate command that clears it. |
| `…​.infra_flag` | The **toolchain** failed — a provider was unreachable, an audit row could not be written, or a marker could not be audited. Stage 8 refuses merge/push while it exists. | A clean content `ALLOW`, or the override path. |
| `…​.needs_human` | **The gate refused to run a review and nobody has retried.** Written on the *first* escalation stall. This is not an infra failure: it means a human owes the artifact a team review. | A review actually executing — L5's `ALLOW` and BLOCK arms — or the override path. An `INFRA_ERROR` deliberately does **not** clear it, because no review ran. |
| `…​.inflight` | A review is running between the two lock acquisitions. `record-marker` refuses while it is younger than 555 s; older ones are stale and are removed automatically. | The end of the review, on all three outcomes including `INFRA_ERROR`. |
| `…​.marker-request` | A `prepare-marker` request file: data for a human, never instructions. It is advisory and stamps its own staleness. | Nothing reads it but a person; the next `prepare-marker` replaces it atomically. |
| `…​.split-request` | A `prepare-split` request file: the halt-recovery split a human would record, data for a person and never instructions. Advisory; stamps its own staleness. | Nothing reads it but a person; the next `prepare-split` replaces it atomically. |
| `…​.lock` | The `fcntl.flock` file. Its **presence proves nothing** — it is never unlinked. | Kernel release on process exit. |

`python3 scripts/review_gate.py --cwd <dir> doctor` reports all of this and **exits non-zero**
on any artifact carrying `.needs_human`, `.halt`, a stale `.inflight`, or a trailing escalation
stall. It reports two counters separately and they are not interchangeable:

- **`stall_run`** — how many *consecutive* stalls. It drives `max_stall`, and it is **not** reset
  by an `ALLOW`, deliberately: an `ALLOW` line is counter-neutral, so admitting it as a reset
  would restore a reset primitive that looks like ordinary history.
- **`stall_trailing`** — whether the artifact has stalled *since the last verdict or reset*. This,
  never `stall_run`, is what `doctor`'s exit code keys on, so a **successful recovery returns
  `doctor` to zero** while `max_stall` keeps counting.

`doctor`'s exit code is repo-wide load-bearing: `core/SDP.md` refuses Stage-8 merge/push while
an infra flag exists **or while `doctor` exits non-zero**. That parenthetical is the whole
mechanism by which `.needs_human` reaches Stage 8.

## Recording a team-review marker

When the gate escalates, the sanctioned channel is:

```
python3 scripts/review_gate.py --cwd <dir> prepare-marker <artifact> --marker-roster a,b --marker-outputs p1,p2
```

which writes a request file for a human and prints its path and a PASS/FAIL checklist — never
the command itself. The human then runs `record-marker` at a terminal. It requires a TTY and
`SDP_MARKER_HUMAN` matching `~/.sdp/marker.token`, and `--marker-decision pivot|halt`
additionally requires `--i-am-recording-a-state-changing-decision` and a typed confirmation
phrase.

Provisioning the token is a one-time operator step: write a non-empty value to
`~/.sdp/marker.token`, `chmod 600` it, and export `SDP_MARKER_HUMAN` with the same value in the
interactive shell. **The token is an intent signal, not a secret** — the file is same-uid
readable, so anything that can run `cat` can supply it. The only affordance barrier is the TTY
test, and the token exists so an accidental invocation from a non-interactive context cannot
succeed even under a pty.

Running `record-marker` twice is safe and **the second marker wins**: both lines stay in the log
as an audit trail, and only the last is consumed by the escalation check.

## Splitting a halted artifact

A halt is terminal: the artifact is not reviewed again, and the agent's only sanctioned move is
to stop and report. When the halt is a **scope** problem — every round raised a different defect
rather than the same one — the recovery is to split the artifact into narrower ones. Ceremony is
deliberately pivot-strength, because splitting restarts each child's counter.

```
python3 scripts/review_gate.py --cwd <dir> prepare-split <parent> \
  --split-child <narrower-1> --split-child <narrower-2> --split-rationale "<why>"
```

`prepare-split` writes the request file, prints its path and a PASS/FAIL checklist, and touches
no gate state — never the `record-split` command, which lives only inside the request file. The
human then runs that command at a terminal: it needs a TTY, `SDP_MARKER_HUMAN` matching
`~/.sdp/marker.token`, `--i-am-recording-a-state-changing-decision`, and the typed phrase
`record split for <stem> into <n> at round <r>`.

What it refuses, and why each refusal is load-bearing — gate state is keyed by the artifact's
absolute path, so splitting has **always** restarted the counter as a side effect. Making it
sanctioned without these would turn an accident into a supported bypass:

| Refusal | Reason |
|---|---|
| the artifact is not halted | the split is a halt recovery, not a shortcut past the fix loop |
| already split | a parent is closed once |
| fewer than two children, or a child that is the parent | that is a rename, not a split |
| a child path that does not exist | a split registered against paths nobody wrote is a promise recorded as a fact |
| a child that already carries gate state | children are new work, not a way to move a counter |
| no rationale | the log has to say why the scope could not converge |
| fewer than two distinct BLOCK reasons in the log | one reason repeated is an unfixed finding; a narrower artifact does not cure it |
| chain depth past `halt.split_depth_cap` (default 2) | uncapped, the path becomes "split until it passes" |

Write order is **children first, parent last**: a half-finished split leaves the parent halted
and recoverable rather than sealed with nowhere to go. If the audit row cannot be written the
split is compensated with `SPLIT_AUDIT_FAILED`, which makes the `SPLIT` line inert and returns
the parent to the halted-but-unsealed state.

After the split, the parent answers `BLOCK: artifact was split; gate the children` and keeps its
own BLOCK history; each child's log opens with
`SPLIT_CHILD_OF parent=<key> parent_round=<n> depth=<d>`, and its counter starts at zero.
