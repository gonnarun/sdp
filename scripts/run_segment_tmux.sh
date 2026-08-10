#!/usr/bin/env bash
# =============================================================================
# SDP Segment Runner (tmux long-lived Codex) — vendored, de-domained.
# Ported from the Project-A reference (scripts/meta_wf/run_segment_tmux.sh);
# all project-specific literals externalized to config. Backs batch-sdp's
# `tmux_long_lived` engine and worktree-dispatch's `auto` mode (REQ-C-03/07).
#
# Purpose: run one long-lived interactive Codex worker per batch inside tmux;
# each segment prompt is pushed via paste-buffer. Claude Code is review-gate only.
# Completion signal = SEGMENT_DIR/STATUS.md (never scrape the TUI).
#
# Usage:  run_segment_tmux.sh <BATCH_DIR> <SEGMENT_DIR> <MODE> [TIMEOUT_SECONDS]
#   MODE = init | continue | resume | compact | shutdown ; TIMEOUT default from
#          dispatch.default_timeout (14400).
# Session name: <prefix>-<batch_basename>-<sha8>   (prefix = dispatch.session_prefix)
# Boot: `codex --ask-for-approval never --sandbox danger-full-access -C <git-cwd>`
# Prompt push: load-buffer + paste-buffer + size-proportional sleep + one C-m
#              (one Enter submits the pasted prompt in the Codex TUI).
# Completion: poll STATUS.md (1s; mtime>=invoke_ts; non-empty).
# Exit codes: 0 SUCCESS · 1 usage · 2 BATCH_DIR missing · 3 required input missing ·
#             4 bad MODE · 5 tmux/codex/git missing · 6 session-state conflict ·
#             7 session dead · 8 token budget exceeded (NFR-05) ·
#             9 STATUS.md content unrecognized · 10 FAIL_12X · 11 HALT_BLOCK (content) ·
#             12 PAUSE_USER_INPUT_REQUIRED · 124 timeout · 125 no STATUS written.
# Caller (batch-sdp) mapping: 12 -> stop + report (user input needed); 10/11 are
#   content outcomes that follow the core loop, NOT an unattended-stop; INFRA_ERROR
#   (surfaced inside the segment) is the ONLY unattended-stop trigger (L13).
# Env: SDP_TMUX_DRYRUN=1 validates + prints the plan without spawning/polling
#      (returns 0 on a valid dry-run, or the real error exit code). Also:
#      CLAUDE_PROJECT_DIR, SDP_CORE_FILE, SDP_SESSION_PREFIX, SDP_RULES_INCLUDE,
#      SDP_SESSION_CWD override the resolved config.
# =============================================================================
set -euo pipefail

# ---- usage / args ----
usage() { echo "usage: run_segment_tmux.sh <BATCH_DIR> <SEGMENT_DIR> <MODE=init|continue|resume|compact|shutdown> [TIMEOUT_SECONDS]" >&2; }
[ "$#" -ge 3 ] || { usage; exit 1; }
BATCH_DIR="$1"; SEGMENT_DIR="$2"; MODE="$3"; TIMEOUT_ARG="${4:-}"
DRYRUN="${SDP_TMUX_DRYRUN:-}"

# ---- tool/dir guards (builtin-only; run before config so they are reachable
#      even under a stripped PATH, and keep exit-code precedence 2 before 5) ----
[ -d "$BATCH_DIR" ] || { echo "ERROR: BATCH_DIR not found: $BATCH_DIR" >&2; exit 2; }
command -v tmux   >/dev/null 2>&1 || { echo "ERROR: tmux not installed (adapters should fall back to agent_tool/manual)" >&2; exit 5; }
command -v codex  >/dev/null 2>&1 || { echo "ERROR: codex CLI not installed (adapters should fall back)" >&2; exit 5; }
command -v git    >/dev/null 2>&1 || { echo "ERROR: git not installed (Codex worker requires a repository)" >&2; exit 5; }

# ---- anchor/config resolution ----
_src="${BASH_SOURCE[0]:-$0}"
SDP_SCRIPTS="$(cd "$(dirname "$_src")" && pwd)"
SDP_ROOT="$(cd "$SDP_SCRIPTS/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$SDP_SCRIPTS/lib/sdp-config.sh" ] && . "$SDP_SCRIPTS/lib/sdp-config.sh"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DEFAULTS=""
for _c in "$PROJECT_DIR/.sdp/defaults.yaml" "$PROJECT_DIR/scripts/sdp/defaults.yaml"; do
  [ -f "$_c" ] && { DEFAULTS="$_c"; break; }
done
cfg() { { [ -n "$DEFAULTS" ] && command -v sdp_cfg_get >/dev/null 2>&1 && sdp_cfg_get "$DEFAULTS" "$1"; } || printf ''; }

SESSION_PREFIX="${SDP_SESSION_PREFIX:-$(cfg dispatch.session_prefix)}"; : "${SESSION_PREFIX:=sdp-seg}"
# security: prefix flows into the tmux session name and shell argv -> restrict charset.
case "$SESSION_PREFIX" in *[!A-Za-z0-9-]*) echo "WARN: illegal dispatch.session_prefix=$SESSION_PREFIX -> using sdp-seg" >&2; SESSION_PREFIX="sdp-seg" ;; esac
CORE_FILE="${SDP_CORE_FILE:-$SDP_ROOT/core/SDP.md}"
RULES_INCLUDE="${SDP_RULES_INCLUDE:-$(cfg dispatch.rules_include)}"
DEF_TIMEOUT="$(cfg dispatch.default_timeout)"; : "${DEF_TIMEOUT:=14400}"
TIMEOUT_SECONDS="${TIMEOUT_ARG:-$DEF_TIMEOUT}"
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) TIMEOUT_SECONDS="$DEF_TIMEOUT" ;; esac
case "$DEF_TIMEOUT" in ''|*[!0-9]*) DEF_TIMEOUT=14400; TIMEOUT_SECONDS=14400 ;; esac
# token hard cap (NFR-05): per-task ceiling; 0 = off. Enforced before (re)spawning a segment.
TOKEN_BUDGET="${SDP_TOKEN_BUDGET:-$(cfg dispatch.token_budget)}"; : "${TOKEN_BUDGET:=0}"
case "$TOKEN_BUDGET" in ''|*[!0-9]*) TOKEN_BUDGET=0 ;; esac

# Session cwd must be a git checkout. Never fall back to the plugin install root:
# the Codex worker runs unattended with danger-full-access, so an explicit git cwd
# is a required targeting guard (not a sandbox boundary).
SESSION_CWD="${SDP_SESSION_CWD:-}"
[ -z "$SESSION_CWD" ] && SESSION_CWD="$SEGMENT_DIR"
[ -d "$SESSION_CWD" ] || { echo "ERROR: session cwd not found: $SESSION_CWD" >&2; exit 3; }
git -C "$SESSION_CWD" rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "ERROR: session cwd is not inside a git repository: $SESSION_CWD" >&2; exit 3; }
printf -v _quoted_session_cwd '%q' "$SESSION_CWD"
WORKER_COMMAND="codex --ask-for-approval never --sandbox danger-full-access -C $_quoted_session_cwd"

# ---- per-batch state files ----
SESSION_NAME_FILE="${BATCH_DIR}/.tmux_session_name"
HISTORY_FILE="${BATCH_DIR}/.session_history.log"; touch "$HISTORY_FILE"
if [ -d "$SEGMENT_DIR" ]; then LOG_DIR="$SEGMENT_DIR"; else LOG_DIR="$BATCH_DIR"; fi
STDERR_LOG="${LOG_DIR}/run_segment_tmux.stderr.log"; touch "$STDERR_LOG"

gen_session_name() {
  local base hash
  base="$(basename "$BATCH_DIR" | tr -c 'a-zA-Z0-9' '-' | cut -c1-24)"
  hash="$(printf '%s' "$BATCH_DIR" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-8)"
  printf '%s-%s-%s' "$SESSION_PREFIX" "$base" "$hash"
}
session_alive() { tmux has-session -t "$1" 2>/dev/null; }

# send_prompt_safe: load-buffer -> paste-buffer -d -> size-proportional sleep
# (1 + size/3000, cap 5s) -> one C-m to submit in the Codex TUI.
send_prompt_safe() {
  local session="$1" payload="$2" tmpfile size wait_s buf
  # N2 (REQ-033): the tmux buffer namespace is server-global, so a fixed buffer
  # name collides across concurrent segment runs -- make it per-invocation. The
  # RETURN trap guarantees the tmpfile + buffer are cleaned even if a tmux call
  # fails under set -e.
  buf="sdp-prompt-$$-${RANDOM}"
  tmpfile="$(mktemp -t sdp-prompt-XXXXXX)"
  trap 'rm -f "$tmpfile"; tmux delete-buffer -b "$buf" 2>/dev/null || true' RETURN
  printf '%s' "$payload" > "$tmpfile"
  tmux load-buffer  -t "$session" -b "$buf" "$tmpfile"
  tmux paste-buffer -t "$session" -b "$buf" -d
  size="$(printf '%s' "$payload" | wc -c | tr -d ' ')"
  wait_s=$((1 + size/3000)); [ "$wait_s" -gt 5 ] && wait_s=5
  sleep "$wait_s"
  tmux send-keys -t "${session}:0.0" C-m
}

# wait_status_md: poll until deadline; success = target non-empty && mtime>=invoke_ts.
wait_status_md() {
  local target="$1" invoke_ts="$2" deadline="$3" mtime
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$target" ]; then
      mtime="$(stat -f %m "$target" 2>/dev/null || stat -c %Y "$target" 2>/dev/null || echo 0)"
      [ "${mtime:-0}" -ge "$invoke_ts" ] && return 0
    fi
    session_alive "$SESSION_NAME" || return 7
    sleep 1
  done
  return 124
}

# de-domained prompt preamble: anchor first, then run the shared SDP core unattended.
_rules_clause=""; [ -n "$RULES_INCLUDE" ] && _rules_clause="Obey the project rules in: ${RULES_INCLUDE}. "
_preamble() {
  printf 'First anchor this session: run  CLAUDE_PROJECT_DIR="%s" bash "%s/sdp-anchor.sh" . ' "$SESSION_CWD" "$SDP_SCRIPTS"
  printf 'Then read %s and run the full SDP workflow (Stages 1-8 + the two Claude gates) UNATTENDED; pause and report on INFRA_ERROR. ' "$CORE_FILE"
  printf 'Confine ALL outputs to %s. Ask the user NO questions. %s' "$SEGMENT_DIR" "$_rules_clause"
}

SESSION_NAME=""; PROMPT=""; STATUS_TARGET=""; NEED_WAIT=0; COMPACT_SLEEP=0; CONTROL_PROMPT="<task prompt>"
case "$MODE" in
  init)
    [ -f "$SESSION_NAME_FILE" ] && { echo "ERROR: session already exists ($SESSION_NAME_FILE); use continue/shutdown" >&2; exit 6; }
    [ -f "${SEGMENT_DIR}/INPUT.md" ] || { echo "ERROR: ${SEGMENT_DIR}/INPUT.md required for init" >&2; exit 3; }
    SESSION_NAME="$(gen_session_name)"
    PROMPT="$(_preamble)Read ${SEGMENT_DIR}/INPUT.md FIRST as the segment scope; skip the Stage 1 interview and start at Stage 2. On completion write ${SEGMENT_DIR}/STATUS.md as exactly one of: SUCCESS | FAIL_12X | HALT_BLOCK | PAUSE_USER_INPUT_REQUIRED."
    STATUS_TARGET="${SEGMENT_DIR}/STATUS.md"; NEED_WAIT=1 ;;
  continue)
    [ -f "$SESSION_NAME_FILE" ] || { echo "ERROR: no session file; run init first" >&2; exit 6; }
    SESSION_NAME="$(cat "$SESSION_NAME_FILE")"
    [ -f "${SEGMENT_DIR}/INPUT.md" ] || { echo "ERROR: ${SEGMENT_DIR}/INPUT.md required for continue" >&2; exit 3; }
    PROMPT="$(_preamble)This is the NEXT segment. Read ${SEGMENT_DIR}/INPUT.md and scope strictly to this new segment. Write ${SEGMENT_DIR}/STATUS.md as one of: SUCCESS | FAIL_12X | HALT_BLOCK | PAUSE_USER_INPUT_REQUIRED."
    STATUS_TARGET="${SEGMENT_DIR}/STATUS.md"; NEED_WAIT=1 ;;
  resume)
    [ -f "$SESSION_NAME_FILE" ] || { echo "ERROR: no session file; run init first" >&2; exit 6; }
    SESSION_NAME="$(cat "$SESSION_NAME_FILE")"
    [ -f "${SEGMENT_DIR}/USER_RESPONSE.md" ] || { echo "ERROR: ${SEGMENT_DIR}/USER_RESPONSE.md required for resume" >&2; exit 3; }
    PROMPT="$(_preamble)Resume from the prior PAUSE. Read ${SEGMENT_DIR}/USER_RESPONSE.md, keep existing outputs, continue from the last PAUSE point, and update ${SEGMENT_DIR}/STATUS.md."
    STATUS_TARGET="${SEGMENT_DIR}/STATUS.md"; NEED_WAIT=1 ;;
  compact)
    [ -f "$SESSION_NAME_FILE" ] || { echo "ERROR: no session file" >&2; exit 6; }
    SESSION_NAME="$(cat "$SESSION_NAME_FILE")"
    PROMPT="/compact"; CONTROL_PROMPT="/compact"; NEED_WAIT=0; COMPACT_SLEEP=120 ;;
  shutdown)
    [ -f "$SESSION_NAME_FILE" ] || { echo "no session to shut down"; exit 0; }
    SESSION_NAME="$(cat "$SESSION_NAME_FILE")"
    if [ -n "$DRYRUN" ]; then echo "DRYRUN shutdown: would /exit + kill-session $SESSION_NAME"; exit 0; fi
    if session_alive "$SESSION_NAME"; then
      tmux send-keys -t "${SESSION_NAME}:0.0" "/exit" C-m || true; sleep 5
      tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    fi
    rm -f "$SESSION_NAME_FILE"
    echo "session $SESSION_NAME shut down"; exit 0 ;;
  *)
    echo "ERROR: unknown MODE '$MODE' (init|continue|resume|compact|shutdown)" >&2; exit 4 ;;
esac

# ---- token hard cap (NFR-05) GUARD, currently INERT (N9/REQ-040): NO writer for
# .tokens_used has ever existed, so the cap only fires when SDP_TOKENS_USED is
# injected (env) or a future accounting hook writes ${BATCH_DIR}/.tokens_used. The
# comparison is kept in place for that future writer -- it is NOT a live enforced
# budget. Applies to spawning modes only. ----
if [ "$TOKEN_BUDGET" -gt 0 ]; then
  case "$MODE" in
    init|continue|resume)
      TOKENS_USED="${SDP_TOKENS_USED:-$(cat "${BATCH_DIR}/.tokens_used" 2>/dev/null || echo 0)}"
      case "$TOKENS_USED" in ''|*[!0-9]*) TOKENS_USED=0 ;; esac
      if [ "$TOKENS_USED" -ge "$TOKEN_BUDGET" ]; then
        echo "ERROR: token budget exceeded (used=$TOKENS_USED >= budget=$TOKEN_BUDGET) — refusing to spawn (NFR-05)" >&2
        exit 8
      fi ;;
  esac
fi

# ---- dry-run: report the resolved plan, do not spawn/poll ----
if [ -n "$DRYRUN" ]; then
  echo "DRYRUN ok"
  echo "  mode          : $MODE"
  echo "  session_prefix: $SESSION_PREFIX"
  echo "  session_name  : $SESSION_NAME"
  echo "  core_file     : $CORE_FILE"
  echo "  session_cwd   : $SESSION_CWD"
  echo "  worker_command: $WORKER_COMMAND"
  echo "  control_prompt: $CONTROL_PROMPT"
  echo "  rules_include : ${RULES_INCLUDE:-<none>}"
  echo "  timeout       : $TIMEOUT_SECONDS"
  echo "  status_target : ${STATUS_TARGET:-<none>}"
  echo "  need_wait     : $NEED_WAIT"
  exit 0
fi

# ---- live path ----
INVOKE_TS="$(date +%s)"
{ printf '%s mode=%s batch=%s segment=%s session=%s timeout=%s\n' "$(date -Iseconds)" "$MODE" "$BATCH_DIR" "$SEGMENT_DIR" "$SESSION_NAME" "$TIMEOUT_SECONDS"; } | tee -a "$STDERR_LOG" "$HISTORY_FILE" >/dev/null

if [ "$MODE" = "init" ]; then
  # N12 (REQ-043): spawn FIRST, then write .tmux_session_name only after the
  # session is confirmed live. A failed spawn must not leave a stale session
  # file; cleanup is scoped to the spawn (the file is simply never written on
  # failure) -- a blanket trap-remove would wrongly delete it on a good init.
  tmux new-session -d -s "$SESSION_NAME" -c "$SESSION_CWD" "$WORKER_COMMAND"
  sleep 5
  session_alive "$SESSION_NAME" || { echo "ERROR: session $SESSION_NAME did not come up" >&2; exit 7; }
  printf '%s' "$SESSION_NAME" > "$SESSION_NAME_FILE"
else
  session_alive "$SESSION_NAME" || { echo "ERROR: session $SESSION_NAME is dead" >&2; exit 7; }
fi

# N13 (REQ-044): preserve any prior STATUS.md as evidence (mv, never rm) so a stale
# file cannot be mistaken for this run's completion and a later 124 keeps the trail.
if [ "$NEED_WAIT" -eq 1 ] && [ -f "$STATUS_TARGET" ]; then
  mv -f "$STATUS_TARGET" "${STATUS_TARGET%.md}.prev.md"
fi

send_prompt_safe "$SESSION_NAME" "$PROMPT"

EXIT_CODE=0
if [ "$NEED_WAIT" -eq 1 ]; then
  DEADLINE=$((INVOKE_TS + TIMEOUT_SECONDS))
  set +e; wait_status_md "$STATUS_TARGET" "$INVOKE_TS" "$DEADLINE"; rc=$?; set -e
  case "$rc" in
    0)
      # N3 (REQ-034): gate on STATUS.md CONTENT, not merely its presence. Map the
      # four documented completion states to distinct exit codes so the caller
      # (batch-sdp) can act. Only INFRA_ERROR -- surfaced inside the segment, never
      # a content HALT/FAIL here -- is an unattended-stop trigger (L13).
      _status="$(head -n1 "$STATUS_TARGET" 2>/dev/null | tr -d '[:space:]')"
      case "$_status" in
        SUCCESS)                   EXIT_CODE=0 ;;
        FAIL_12X)                  EXIT_CODE=10 ;;
        HALT_BLOCK)                EXIT_CODE=11 ;;
        PAUSE_USER_INPUT_REQUIRED) EXIT_CODE=12 ;;
        *)                         EXIT_CODE=9 ;;   # present but unrecognized content
      esac ;;
    7) EXIT_CODE=7 ;;
    124) EXIT_CODE=124 ;;
    *) EXIT_CODE=125 ;;
  esac
else
  [ "$COMPACT_SLEEP" -gt 0 ] && sleep "$COMPACT_SLEEP"
fi

{ printf '%s exit mode=%s session=%s code=%s\n' "$(date -Iseconds)" "$MODE" "$SESSION_NAME" "$EXIT_CODE"; } | tee -a "$STDERR_LOG" "$HISTORY_FILE" >/dev/null
exit "$EXIT_CODE"
