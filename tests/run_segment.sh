#!/usr/bin/env bash
# run_segment.sh — dry-run test for scripts/run_segment_tmux.sh.
# Real tmux/Codex sessions are not spawned in CI, so this exercises
# arg parsing, MODE validation, exit codes, and de-domained config resolution via
# SDP_TMUX_DRYRUN=1 (validates + prints the plan, never spawns/polls). In the
# smoke/gate test style. Exit codes 7/124/125 need a live session (untested here).
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$SDP_ROOT/scripts/run_segment_tmux.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# require tmux+codex+git present so we reach the MODE logic;
# if absent, every call would exit 5 and the codes below couldn't be asserted.
if ! command -v tmux >/dev/null 2>&1 || ! command -v codex >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "SKIP - tmux/codex/git absent; cannot exercise MODE logic (exit-5 fallback path only)"
  echo "-------- 0 passed, 0 failed (skipped) --------"; exit 0
fi

TMP="$(mktemp -d -t sdp_run_seg.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/batch" "$TMP/seg"
export CLAUDE_PROJECT_DIR="$SDP_ROOT"   # resolve .sdp/defaults.yaml
export SDP_SESSION_CWD="$SDP_ROOT"      # Codex runner requires a git-backed cwd
run() { SDP_TMUX_DRYRUN=1 bash "$RUN" "$@" >/dev/null 2>&1; echo $?; }

# exit codes
[ "$(run "$TMP/batch" "$TMP/seg")" = 1 ]            && ok "missing MODE arg -> exit 1" || bad "usage exit 1"
[ "$(run "$TMP/batch" "$TMP/seg" bogus)" = 4 ]      && ok "bad MODE -> exit 4"          || bad "bad MODE exit 4"
[ "$(run "$TMP/nope" "$TMP/seg" init)" = 2 ]        && ok "BATCH_DIR missing -> exit 2" || bad "BATCH_DIR exit 2"
[ "$(run "$TMP/batch" "$TMP/seg" init)" = 3 ]       && ok "init w/o INPUT.md -> exit 3" || bad "init exit 3"
[ "$(run "$TMP/batch" "$TMP/seg" continue)" = 6 ]   && ok "continue w/o session -> exit 6" || bad "continue exit 6"
[ "$(run "$TMP/batch" "$TMP/seg" resume)" = 6 ]     && ok "resume w/o session -> exit 6"   || bad "resume exit 6"
bad_cwd_rc="$(SDP_SESSION_CWD="$TMP/not-a-worktree" SDP_TMUX_DRYRUN=1 bash "$RUN" "$TMP/batch" "$TMP/seg" init >/dev/null 2>&1; echo $?)"
[ "$bad_cwd_rc" = 3 ] && ok "missing/non-git worker cwd -> exit 3" || bad "invalid worker cwd exit $bad_cwd_rc"

# exit 5 when tmux/codex/git are absent (stripped PATH; guards run first).
# Use bash's absolute path so only the SCRIPT's internal `command -v` sees the empty PATH.
BASH_BIN="$(command -v bash)"
rc5="$(PATH=/nonexistent SDP_TMUX_DRYRUN=1 "$BASH_BIN" "$RUN" "$TMP/batch" "$TMP/seg" init >/dev/null 2>&1; echo $?)"
[ "$rc5" = 5 ] && ok "tmux/codex/git absent -> exit 5 (graceful fallback signal)" || bad "tool-absent exit 5 (got $rc5)"

# init OK once INPUT.md exists
echo scope > "$TMP/seg/INPUT.md"
[ "$(run "$TMP/batch" "$TMP/seg" init)" = 0 ]       && ok "init w/ INPUT.md -> exit 0"     || bad "init ok exit 0"

# init exit 6 when a session file already exists
echo somename > "$TMP/batch/.tmux_session_name"
[ "$(run "$TMP/batch" "$TMP/seg" init)" = 6 ]       && ok "init w/ existing session -> exit 6" || bad "init-existing exit 6"
# resume needs USER_RESPONSE.md (session file now present -> passes the 6 guard, hits 3)
[ "$(run "$TMP/batch" "$TMP/seg" resume)" = 3 ]     && ok "resume w/o USER_RESPONSE.md -> exit 3" || bad "resume exit 3"
rm -f "$TMP/batch/.tmux_session_name"

# de-domain config resolution: default prefix, and override honored
out="$(SDP_TMUX_DRYRUN=1 bash "$RUN" "$TMP/batch" "$TMP/seg" init 2>/dev/null)"
printf '%s' "$out" | grep -q 'session_prefix: sdp-seg' && ok "default session_prefix from config (sdp-seg)" || bad "default prefix"
printf '%s' "$out" | grep -q "core_file .*core/SDP.md" && ok "core_file resolves to core/SDP.md (de-domained)" || bad "core_file resolution"
{ printf '%s' "$out" | grep -qF 'worker_command: codex --ask-for-approval never --sandbox danger-full-access -C ' \
    && ! printf '%s' "$out" | grep -qF 'claude --permission-mode'; } \
  && ok "worker identity: dry-run launches Codex, never Claude" || bad "worker command is not Codex-only"
out2="$(SDP_SESSION_PREFIX=myproj SDP_TMUX_DRYRUN=1 bash "$RUN" "$TMP/batch" "$TMP/seg" init 2>/dev/null)"
printf '%s' "$out2" | grep -q 'session_prefix: myproj' && ok "SDP_SESSION_PREFIX override honored" || bad "prefix override"
# illegal prefix rejected -> falls back to sdp-seg
out3="$(SDP_SESSION_PREFIX='bad;rm -rf' SDP_TMUX_DRYRUN=1 bash "$RUN" "$TMP/batch" "$TMP/seg" init 2>/dev/null)"
printf '%s' "$out3" | grep -q 'session_prefix: sdp-seg' && ok "illegal session_prefix rejected (charset guard)" || bad "prefix charset guard"

# shutdown with no session is a clean no-op (exit 0)
[ "$(run "$TMP/batch" "$TMP/seg" shutdown)" = 0 ]   && ok "shutdown w/o session -> exit 0 (no-op)" || bad "shutdown noop"

# Codex TUI control verbs are explicit and observable without a live model run.
echo live > "$TMP/batch/.tmux_session_name"
compact_out="$(SDP_TMUX_DRYRUN=1 bash "$RUN" "$TMP/batch" "$TMP/seg" compact 2>/dev/null)"
printf '%s' "$compact_out" | grep -qF 'control_prompt: /compact' \
  && ok "Codex TUI compact control is /compact" || bad "compact control prompt"
shutdown_out="$(SDP_TMUX_DRYRUN=1 bash "$RUN" "$TMP/batch" "$TMP/seg" shutdown 2>/dev/null)"
printf '%s' "$shutdown_out" | grep -qF 'would /exit + kill-session' \
  && ok "Codex TUI shutdown control is /exit" || bad "shutdown control prompt"
rm -f "$TMP/batch/.tmux_session_name"
send_keys_count="$(sed -n '/^send_prompt_safe()/,/^}/p' "$RUN" | grep -c 'send-keys.*C-m')"
[ "$send_keys_count" = 1 ] && ok "Codex prompt submit uses one Enter" || bad "prompt submit Enter count=$send_keys_count"

# --- token budget cap (NFR-05), with injected token counts ---
runb() { SDP_TMUX_DRYRUN=1 SDP_TOKEN_BUDGET="$1" SDP_TOKENS_USED="$2" bash "$RUN" "$TMP/batch" "$TMP/seg" init >/dev/null 2>&1; echo $?; }
[ "$(runb 0 999999)" = 0 ]     && ok "token_budget=0 -> cap OFF (no enforcement)"         || bad "budget off default"
[ "$(runb 1000 2000)" = 8 ]    && ok "used(2000) >= budget(1000) -> exit 8 (refuse spawn)" || bad "budget exceeded exit 8"
[ "$(runb 1000 500)" = 0 ]     && ok "used(500) < budget(1000) -> exit 0 (proceed)"        || bad "budget under limit"
# budget check skips non-spawning modes (compact needs a session; assert it is NOT budget-blocked)
echo n > "$TMP/batch/.tmux_session_name"
rc="$(SDP_TMUX_DRYRUN=1 SDP_TOKEN_BUDGET=1 SDP_TOKENS_USED=999 bash "$RUN" "$TMP/batch" "$TMP/seg" compact >/dev/null 2>&1; echo $?)"
[ "$rc" != 8 ] && ok "token cap skipped for non-spawning mode (compact, rc=$rc)" || bad "compact wrongly budget-blocked"
rm -f "$TMP/batch/.tmux_session_name"
# used-token source can be the ${BATCH_DIR}/.tokens_used file
echo 5000 > "$TMP/batch/.tokens_used"
[ "$(SDP_TMUX_DRYRUN=1 SDP_TOKEN_BUDGET=1000 bash "$RUN" "$TMP/batch" "$TMP/seg" init >/dev/null 2>&1; echo $?)" = 8 ] \
  && ok ".tokens_used file honored as used-token source -> exit 8" || bad ".tokens_used file source"
rm -f "$TMP/batch/.tokens_used"

# --- REQ-034 (N3): STATUS.md CONTENT gates the exit code (live path) --------------
# The content->exit mapping (SUCCESS 0 / FAIL_12X 10 / HALT_BLOCK 11 / PAUSE 12 /
# unrecognized 9) lives ONLY on the live path — SDP_TMUX_DRYRUN exits before it, so
# the dry-run cases above cannot reach it. We drive `continue` for real with a STUB
# tmux that (a) reports the session alive (has-session -> 0) and (b) writes the
# wanted STATUS.md content when the prompt is pasted, simulating what the Codex
# session would eventually do. No real tmux/Codex session is spawned. Asserts each
# documented completion state yields a NON-success exit (REQ-034).
STUBD="$TMP/stubbin"; mkdir -p "$STUBD"
cat > "$STUBD/tmux" <<'TMUXSTUB'
#!/usr/bin/env bash
# minimal tmux stand-in: has-session => alive; paste-buffer => write the STATUS.md
# the test asked for (SDP_TEST_STATUS_FILE / _CONTENT). Everything else is a no-op.
case "${1:-}" in
  has-session) exit 0 ;;
  paste-buffer)
    [ -n "${SDP_TEST_STATUS_FILE:-}" ] && printf '%s\n' "${SDP_TEST_STATUS_CONTENT:-}" > "$SDP_TEST_STATUS_FILE"
    exit 0 ;;
  *) exit 0 ;;
esac
TMUXSTUB
chmod +x "$STUBD/tmux"

SEG2="$TMP/seg2"; mkdir -p "$SEG2"; echo scope > "$SEG2/INPUT.md"
echo live-session > "$TMP/batch/.tmux_session_name"      # continue needs a session file
# statusexit <content> -> prints the gate exit code for a STATUS.md of that content
statusexit() {
  rm -f "$SEG2/STATUS.md" "$SEG2/STATUS.prev.md"
  PATH="$STUBD:$PATH" SDP_TOKEN_BUDGET=0 \
    SDP_TEST_STATUS_FILE="$SEG2/STATUS.md" SDP_TEST_STATUS_CONTENT="$1" \
    bash "$RUN" "$TMP/batch" "$SEG2" continue 5 >/dev/null 2>&1; echo $?
}
[ "$(statusexit SUCCESS)" = 0 ]                    && ok "REQ-034: STATUS.md=SUCCESS -> exit 0 (control: success is 0)" || bad "REQ-034 SUCCESS exit 0"
[ "$(statusexit FAIL_12X)" = 10 ]                  && ok "REQ-034: STATUS.md=FAIL_12X -> exit 10 (NON-success)" || bad "REQ-034 FAIL_12X exit 10"
[ "$(statusexit HALT_BLOCK)" = 11 ]                && ok "REQ-034: STATUS.md=HALT_BLOCK -> exit 11 (NON-success)" || bad "REQ-034 HALT_BLOCK exit 11"
[ "$(statusexit PAUSE_USER_INPUT_REQUIRED)" = 12 ] && ok "REQ-034: STATUS.md=PAUSE_USER_INPUT_REQUIRED -> exit 12 (NON-success)" || bad "REQ-034 PAUSE exit 12"
[ "$(statusexit WeirdUnknownState)" = 9 ]          && ok "REQ-034: unrecognized STATUS.md content -> exit 9 (fail-closed NON-success)" || bad "REQ-034 unknown exit 9"
rm -f "$TMP/batch/.tmux_session_name"

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
