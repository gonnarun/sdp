## What changed and why

<!-- The change, and the problem it solves. Link an issue if there is one. -->

## Test output

<!-- Paste the tail of `bash tests/run.sh`. Required. -->

```
```

## Checklist

- [ ] Edited the canonical tree (`plugins/sdp/`) and regenerated the root mirror with `python3 scripts/build_plugin_tree.py`
- [ ] `bash tests/run.sh` is green
- [ ] Added or updated a test — **required** for any change to gate behavior
- [ ] Updated `docs/KNOWN_GAPS.md` if this closes or opens a gap
- [ ] Added a `CHANGELOG.md` entry under `## [Unreleased]`
- [ ] No domain literals (`gradle`, `npm`, `Flyway`, DB schema, server-start commands) added to `core/`

## Gate impact

<!-- Does this change what the gate accepts, rejects, or how it fails?
     If it relaxes any fail-closed path or widens a trust class, say so
     explicitly — that is a reviewable decision, not an implementation detail.
     Write "none" if the gate is untouched. -->
