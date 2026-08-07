# Security policy

## Reporting a vulnerability

**Do not open a public issue for a security report.**

Use GitHub's private reporting: **Security → Report a vulnerability** on this repository. Include a description, affected version (`plugins/sdp/.claude-plugin/plugin.json`), and reproduction steps.

Expect an initial response within 7 days. There is no bounty program — this is a single-maintainer project.

---

## Threat model

SDP runs an external reviewer CLI over content that the reviewer must be assumed not to trust. The security-relevant surface is `scripts/review_gate.py` and `scripts/sdp_mcp_server.py`.

**In scope:**

- Escaping the reviewer sandbox — the reviewer runs read-only, with an empty tool allowlist and no session persistence. A path that lets it write, run tools, or persist a session is a vulnerability.
- **Prompt injection through artifact content.** Artifact bodies are wrapped as untrusted data. Content that escapes that wrapper and steers the reviewer's verdict is a vulnerability.
- Artifact path traversal outside the workspace.
- Executing an untrusted reviewer binary — workspace-local binaries and group/world-writable paths are rejected; a bypass is a vulnerability.
- Credential leakage into the reviewer process, a gate log, or the audit ndjson.
- A concurrency bug in the per-artifact `fcntl.flock` critical section that lets two sessions race one artifact's BLOCK counter.
- A fail-**open** path — anywhere `INFRA_ERROR` or a validation failure results in `ALLOW` rather than `BLOCK`.

**Out of scope — known and documented, not vulnerabilities:**

- **Gate-log forgery by a same-uid process.** The gate log is written by an agent running as your user; any process with that uid can append to it. The gate validates marker structure, roster cardinality, distinctness and output freshness, but it cannot prove authorship. This is stated in the README and in `docs/KNOWN_GAPS.md`, and it is a design limit, not a defect. Cryptographic log integrity would require a trust anchor SDP does not have.
- Anything requiring an attacker to already have local code execution as the user running the gate.
- The quality or correctness of a reviewer model's verdict. SDP guarantees that a review *ran* under the stated constraints, not that the reviewer was right.
- Behavior of the `codex`, `claude`, or `agy` CLIs themselves — report those upstream.

---

## Supported versions

Only the latest release is supported. SDP is pre-1.0; fixes land on `master`.

---

## Operator note

`docs/GATE_OPERATIONS.md` documents procedures that mutate gate state. It is deliberately **not** shipped in the plugin tree and is never read by an agent as instructions — a shipped, agent-read document carrying a copy-pasteable state mutation would be a laundering primitive by construction. `tests/docs.sh` enforces this. Keep it that way when editing.
