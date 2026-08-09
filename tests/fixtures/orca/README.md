# tests/fixtures/orca/ — captured Orca CLI responses

These are `orca ... --json` responses captured **live and then redacted**.
They are tracked here because the original, unredacted capture lives under
`.private/` (gitignored) — a test reading from there would pass on one
machine and fail everywhere else. `tests/orca_dispatch.sh` reads only from
this directory.

**Redaction.** These files are not verbatim captures — every owner- and
machine-identifying value has been replaced with a generic one:

- the capturing machine's home path → `/Users/dev`, everywhere it appeared
  (worktree paths, `created_by_process_incarnation` strings, etc.)
- the local Orca desktop app's `runtimeId` (a persistent per-install id that
  appeared, identically, in every single fixture's `_meta`): replaced with
  the fixed placeholder `00000000-0000-4000-8000-000000000000`
- `repo-list.json`'s real inventory (twenty private repositories, three
  GitHub orgs) was replaced wholesale with **three synthetic entries** —
  `example-app` (a full-metadata git repo), `widget-service` (a git repo
  with a leaner field set, mirroring a real entry's shape), and `notes` (a
  `kind: folder` entry with no git remote) — under a fictitious
  `github.com/example-org` and path `/Users/dev/workspace/...`. This keeps
  the real structural diversity (three distinct real shapes were captured;
  all three are represented) without naming anything real.

Consequently these fixtures **match no real machine**, which is what makes
`repo-list.json` a dependable zero-match fixture, and none of the ids above
are read by the adapter or asserted on by the test suite — the redaction
does not touch any value `plugins/sdp/scripts/orca_dispatch.sh` actually
parses (`dispatchId`, `task_id`, `worker.state`/`stage`, `result.repos[].
{id,path}`, etc. are all unchanged). JSON shapes, field names, and nesting
are otherwise unchanged from the live capture.

Captured against:
- **Orca desktop app 1.4.176**
- **agent-context `schemaVersion` 1** (223 commands)
- **2026-08-09**

Files (filenames as captured):

| file | source command | shape |
|---|---|---|
| `status.json` | `orca status --json` | `result.runtime.{reachable,state,appVersion}` — the successful probe case |
| `schema-version.json` | `orca agent-context --json` (trimmed to the field the adapter reads) | top-level `schemaVersion` |
| `repo-list.json` | `orca repo list --json` | `result.repos[].{id,path}` — three synthetic repos (see Redaction above); matches no real path, so it doubles as the "zero match" fixture |
| `run-create.json` | `orca orchestration run-create --json` | `result.run.id` |
| `task-create-ok.json` | `orca orchestration task-create --json` (success) | `result.task.id` |
| `task-create.json` | `orca orchestration task-create --json` (real failure: no Run bound) | `ok: false`, `error.code: run_required` |
| `worker-start.json` | `orca orchestration worker-start --json` | `result.{dispatchId,state,effects[]}` — one `effects[]` entry has `kind: worktree` |
| `worker-show-settled.json` | `orca orchestration worker-show --json` | `result.dispatch.{id,task_id}`, `result.worker.{state,stage,worktree_id}` — a settled/succeeded worker |
| `worker-show-invalid.json` | `orca orchestration worker-show --json` (unknown dispatch id) | `ok: false`, `error.code: dispatch_not_found` |
| `worker-stop-settled.json` | `orca orchestration worker-stop --json` | `result.{dispatchId,state,alreadySettled}` |
| `worker-stop-invalid.json` | `orca orchestration worker-stop --json` (unknown dispatch id) | `ok: false`, `error.code: dispatch_not_found` |

**Deliberately absent.** Two other captures exist but are not needed to drive
a stub: an `orca --version` dump (357 lines of help text containing no
version number at all, which is why the adapter reads `appVersion` from
`orca status --json` instead) and Orca's bundled prose operating guide.

**The unredacted originals are machine-local and gitignored.** Treat these
redacted copies as the only fixtures that exist for this suite.

**Widening `plugins/sdp/scripts/orca_dispatch.sh`'s version allow-list
(`_version_allowed`, currently exactly `1.4.176` / schemaVersion `1`) requires
fresh captures from the newer Orca version** — these fixtures only prove the
adapter behaves correctly for the pair above and for the deliberately-rejected
cases (e.g. a newer `appVersion` such as `1.4.177`, tested with synthetic
JSON since no later version has been captured live).

Some tests in `tests/orca_dispatch.sh` synthesize additional minimal JSON
inline (via `python3 -c`) for shapes these captures don't include — e.g. a
`repo list` response with two entries matching the same path (ambiguous
match), or a `worker-show` reporting `state: failed`. Those are built using
the exact field names confirmed by the real captures above, never invented
ones.
