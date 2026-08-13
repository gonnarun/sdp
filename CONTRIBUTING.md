# Contributing to SDP

Thanks for taking an interest. This document covers the repository's one structural rule (a generated mirror), how to run the tests, and what a reviewable change looks like.

---

## Setup

```bash
git clone https://github.com/gonnarun/sdp.git
cd sdp
git config core.hooksPath .githooks   # required — see "Pre-commit hook" below
```

No dependency install step exists. Everything is bash + Python 3.9+ standard library. `shellcheck` is **required** to run the suite — `tests/run.sh` runs the lint step on both the `--fast` and full paths and does not skip it when the binary is missing. Optional: `tmux` for the long-lived batch engine, and a `codex` and/or `claude` CLI if you want to exercise the gate against a live reviewer.

---

## The one structural rule: edit the canonical tree

`plugins/sdp/` is the **single source of truth** for `scripts/`, `skills/`, and `commands/`. The copies at the repository root are **generated**:

```bash
python3 scripts/build_plugin_tree.py            # regenerate the root mirror
python3 scripts/build_plugin_tree.py --check    # verify it is current (no writes)
```

Edit `plugins/sdp/scripts/foo.sh`, then regenerate. A hand-edited root copy cannot be committed — `tests/run.sh --fast` runs `--check` and the pre-commit hook runs the fast suite.

Two exceptions, both registered inside the generator:

- **`ROOT_ONLY`** — `scripts/build_plugin_tree.py` and `scripts/bump_codex_plugin_version.py` have no canonical counterpart.
- **`HOST_DIVERGENT`** — `scripts/run_segment_tmux.sh` and the three `commands/*.md` files legitimately differ per host and are hand-maintained in *both* trees. If you touch one, touch the other.

`core/` is **not** mirrored. The two `core/` trees are specialized on reviewer *direction* only — the Claude host reviews with codex, the codex host reviews with Claude. `tests/docs.sh` guard (xi) pins the per-file divergent-line count and requires every divergent line to carry a direction token, so an added contradiction trips the suite.

The same applies to `README.md` / `plugins/sdp/README.md` and `.sdp/` / `plugins/sdp/.sdp/`: two trees, hand-maintained, kept in sync.

---

## Tests

```bash
bash tests/run.sh --fast   # regen-check + orphan detector + packaging + smoke + lint. Seconds.
bash tests/run.sh          # full suite — every command in every test.layers.* layer
```

`tests/run.sh` is the **only** entry point. Layers are read from `.sdp/defaults.yaml`; the orphan detector enforces that every `tests/*.sh` is reachable from exactly one `test.commands.<name>` and that every layer entry resolves to a defined command. Adding a suite means adding both.

Roughly 280 assertions across 15 suites. The full suite must be green before a pull request is merged.

### Writing tests

Follow the existing style — a flat script with `ok` / `bad` counters and a `-------- N passed, M failed --------` footer, exiting non-zero on failure. No test framework, no network, no model calls in the default path.

**Any change to gate behavior must come with a test.** The gate is the part of this project that is load-bearing for correctness, and the suite is the only thing standing between a refactor and a silently weakened gate.

---

## Pre-commit hook

`.githooks/pre-commit` does exactly two things:

1. Runs `tests/run.sh --fast`, blocking the commit on any failure (including a stale root mirror).
2. Bumps `plugins/sdp/.claude-plugin/plugin.json` and `plugins/sdp/.codex-plugin/plugin.json` to the same UTC timestamp version and stages them. This is a cachebuster for the plugin install cache, and it is the only write the hook is permitted to make.

Enable it with `git config core.hooksPath .githooks`. Do not bypass it with `--no-verify` on a commit you intend to push.

---

## Making a change

1. Branch off `master`.
2. Edit the canonical tree; regenerate the mirror.
3. Add or update tests.
4. `bash tests/run.sh` — all green.
5. Update `docs/KNOWN_GAPS.md` if you closed a gap or opened one. That file is the authoritative "advertised but not implemented" register; a change that ships less than the docs claim must be recorded there rather than left implicit.
6. Update `CHANGELOG.md` under `## [Unreleased]`.
7. Open a pull request describing **what changed and why**, plus the test output.

### Commit messages

Conventional Commits, matching the existing history:

```
feat(gate): sanctioned marker recording + durable stall signal
fix(mcp): resolve gate server via CLAUDE_PLUGIN_ROOT, not cwd-relative
docs: describe fcntl.flock lock in README; align docs.sh assertion
test(gate): close Stage-7 argv-level coverage gaps
build(plugin): plugins/sdp becomes the one plugin root
```

Scopes in use: `gate`, `mcp`, `dispatch`, `anchor`, `plugin`, `generator`, `bump`, `core`, `codex-gate`.

---

## Things that will get a change rejected

- **Weakening the gate without saying so.** Loosening a fail-closed path, widening a trust class, or relaxing a validation is fine *if it is the point of the change* and the pull request says so. Doing it as a side effect of a refactor is not.
- **Domain literals in `core/`.** No `gradle`, `npm`, `Flyway`, DB schema, or server-start commands. Those belong in `.sdp/defaults.yaml` (as config) or `.sdp/project-rules.md` (as prose). `tests/i18n.sh` also enforces English-only in `core/`.
- **A copy-pasteable gate-state mutation in a shipped, agent-read document.** `docs/GATE_OPERATIONS.md` is root-only and deliberately excluded from the plugin tree; `tests/docs.sh` guard (iv) enforces that no shipped file carries such a recipe.
- **Overclaiming in documentation.** Several test guards pin exact honesty sentences about what the gate can and cannot guarantee. If you find one inaccurate, change the sentence *and* the guard, and explain why in the pull request.
- **A hand-edited generated file.**

---

## Documentation language

Plugin-facing assets — both READMEs, `core/`, `commands/`, `skills/` — are **English only**. Machine-parsed tokens (`ALLOW:`, `BLOCK:`, `TEAM_REVIEW`, REQ-IDs, config keys) stay ASCII regardless of locale. Translations of root-level documents are welcome as `NAME.<lang>.md` alongside the English original, which stays canonical.

---

## Reporting bugs and requesting features

Use the GitHub issue templates. For anything with security impact, do **not** open a public issue — follow [`SECURITY.md`](SECURITY.md).
