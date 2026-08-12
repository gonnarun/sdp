#!/usr/bin/env bash
# sdp-anchor.sh — anchoring (REQ-P-03).
# Resolve SDP_ROOT / base_dir / output_locale from a KNOWN location (this
# script's own path), NOT from ${CLAUDE_PLUGIN_ROOT} (which may not propagate
# into later body-bash calls, §4.9). Writes ${base_dir}/.sdp_runtime.env as
# agent-readable metadata; no script or stage may source it as shell code.
#
# Also: create ${CLAUDE_PROJECT_DIR}/.private if absent and register it in
# .gitignore, idempotently (REQ-U-07).
set -eu
unset CDPATH   # a user-exported CDPATH makes `cd … && pwd` echo extra lines, corrupting the resolved paths

# --- SDP_ROOT: derive from this script's real path (robust anchor) ---
_src="${BASH_SOURCE[0]:-$0}"
SDP_SCRIPTS="$(cd "$(dirname "$_src")" && pwd)"
SDP_ROOT="$(cd "$SDP_SCRIPTS/.." && pwd)"
SDP_CORE="$SDP_ROOT/core"
# Version of the tree this anchor belongs to, read from the manifest rather than
# the directory name: a plugin-cache install is named by version, a checkout is
# not. Absent/unreadable is not fatal -- it becomes "unknown" and doctor reports
# it as such instead of the anchor refusing to run.
SDP_VERSION="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("version") or "unknown")
except Exception:
    print("unknown")' "$SDP_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo unknown)"

# shellcheck source=/dev/null
. "$SDP_SCRIPTS/lib/sdp-config.sh"

# --- project dir ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- config discovery (REQ-U-05): project override -> XDG/passwd-home fallback.
# config_discovery.py owns precedence and fail-closed path/read validation. ---
DEFAULTS="$(sdp_cfg_discover "$PROJECT_DIR" defaults.yaml)"
GATES="$(sdp_cfg_discover "$PROJECT_DIR" gates.yaml)"

# --- no-weakening guard (REQ-U-04) ---
[ -n "$DEFAULTS" ] && sdp_cfg_check_no_weakening "$DEFAULTS"

# --- base_dir ---
if [ -n "$DEFAULTS" ]; then
  bd="$(sdp_cfg_base_dir "$DEFAULTS")"
else
  bd=".private/sdp-artifacts"
fi
case "$bd" in
  /*) BASE_DIR="$bd" ;;                 # absolute
  *)  BASE_DIR="$PROJECT_DIR/$bd" ;;    # project-relative
esac
# isolation guard: a project-relative base_dir must not escape PROJECT_DIR via `..` traversal (REQ-U-07).
# Normalize `.`/`..` LEXICALLY (no filesystem access) so a legit in-project path that doesn't exist yet
# (e.g. build/../sdp-artifacts on first run) isn't wrongly refused — the old `cd`-based canon required existence.
_lexnorm() {  # lexically collapse . and .. in an absolute path (no filesystem access)
  local seg out="" oldIFS="$IFS" wasf   # save noglob state via $- (no fork / no external grep, safe under set -e)
  case "$-" in *f*) wasf=1 ;; *) wasf=0 ;; esac
  set -f; IFS=/                          # set -f: no globbing on unquoted $1
  for seg in $1; do
    case "$seg" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  IFS="$oldIFS"; [ "$wasf" = 1 ] || set +f; printf '%s' "${out:-/}"
}
_PROJ_CANON="$(_lexnorm "$PROJECT_DIR")"   # normalize PROJECT_DIR too (trailing slash / root) for a clean prefix match
case "$bd" in
  /*) : ;;                              # absolute: allowed but gitignore below warns it can't be ignored
  *..*)
    _bd_canon="$(_lexnorm "$BASE_DIR")"     # BASE_DIR = $PROJECT_DIR/$bd
    case "$_bd_canon" in
      "$_PROJ_CANON"|"$_PROJ_CANON"/*) : ;;   # stays inside the project
      *) printf 'ERROR: base_dir (%s) escapes the project via ".." — refused (REQ-U-07 isolation)\n' "$bd" >&2; exit 2 ;;
    esac ;;
  *)  # plain relative base_dir (no `..`): a SYMLINK can still escape the lexical
      # check, so resolve PHYSICALLY (cd/pwd -P follows links) and WARN if it lands
      # outside the project — the same "outside the project" WARN (REQ-025 / L7).
    _bd_phys="$(cd "$BASE_DIR" 2>/dev/null && pwd -P)" || _bd_phys=""     # empty if not yet created (set -e safe)
    _proj_phys="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || _proj_phys=""
    if [ -n "$_bd_phys" ] && [ -n "$_proj_phys" ]; then
      case "$_bd_phys" in
        "$_proj_phys"|"$_proj_phys"/*) : ;;
        *) printf 'WARN: base_dir (%s) physically resolves outside the project — cannot .gitignore it; ensure it is not tracked by git\n' "$bd" >&2 ;;
      esac
    fi ;;
esac

# --- output_locale: config -> LC_ALL/LANG -> en (REQ-U-08) ---
ol=""
[ -n "$DEFAULTS" ] && ol="$(sdp_cfg_get "$DEFAULTS" output_locale)"
# MODE lets downstream distinguish `auto` (English canonical + synced copy) from a fixed single-language locale,
# which OUTPUT_LOCALE alone cannot (it holds only the resolved target language). Closes KNOWN_GAPS.md #2.
if [ -z "$ol" ] || [ "$ol" = "auto" ]; then OUTPUT_LOCALE_MODE="auto"; else OUTPUT_LOCALE_MODE="fixed"; fi
if [ -z "$ol" ] || [ "$ol" = "auto" ]; then
  envloc="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"   # POSIX message-locale precedence: LC_ALL > LC_MESSAGES > LANG
  case "$envloc" in
    ""|C|C.*|POSIX) ol="en" ;;
    *) ol="${envloc%%.*}"; ol="${ol%%@*}"; ol="${ol%%_*}"; ol="${ol%%-*}" ;;   # ko_KR.UTF-8 / zh-CN / ca_ES@euro -> ko/zh/ca
  esac
fi
OUTPUT_LOCALE="$ol"

# --- .private auto-create + gitignore register (REQ-U-07, idempotent) ---
_private_root="$PROJECT_DIR/.private"
case "$BASE_DIR" in
  "$PROJECT_DIR"/.private/*) : ;;        # base_dir under .private (default)
  *) _private_root="$(dirname "$BASE_DIR")" ;;   # override: guard its parent too
esac
mkdir -p "$BASE_DIR"
if [ ! -d "$_private_root" ]; then mkdir -p "$_private_root"; fi
mkdir -p "$PROJECT_DIR/.private"   # gate-config provenance always stays project-local + gitignored
_gi="$PROJECT_DIR/.gitignore"
# derive the ignore entry from BASE_DIR (a project may override base_dir away from .private) so the
# artifact dir — gate logs, review outputs, secret-scan results — is never left committable (REQ-U-07).
# use the normalized, `..`-free path (git .gitignore has no `..` semantics) against the normalized project dir
_bd_norm="$(_lexnorm "$BASE_DIR")"
case "$_bd_norm" in
  "$_PROJ_CANON"/.private/*) _ignore_line=".private/" ;;                        # default: ignore whole private tree
  "$_PROJ_CANON") _ignore_line="" ; _bd_is_proj=1 ;;                            # base_dir IS the project root (misconfig)
  "$_PROJ_CANON"/*) _ignore_line="${_bd_norm#"$_PROJ_CANON"/}"; _ignore_line="${_ignore_line%/}/" ;;  # override under repo
  *) _ignore_line="" ;;                                                          # absolute/outside repo -> can't gitignore
esac
if [ "${_bd_is_proj:-0}" = 1 ]; then
  printf 'WARN: base_dir resolves to the project root itself — SDP artifacts would sit in the repo root; set a subdir\n' >&2
elif [ -z "$_ignore_line" ]; then
  printf 'WARN: base_dir (%s) is outside the project — cannot .gitignore it; ensure it is not tracked by git\n' "$BASE_DIR" >&2
elif [ -e "$_gi" ]; then
  if ! grep -qxF "$_ignore_line" "$_gi" 2>/dev/null; then
    # ensure the existing file ends in a newline before appending, else the new rule fuses onto the last line
    [ -s "$_gi" ] && [ "$(tail -c1 "$_gi" 2>/dev/null; echo x)" != $'\nx' ] && printf '\n' >> "$_gi"
    printf '%s\n' "$_ignore_line" >> "$_gi"
  fi
else
  printf '%s\n' "$_ignore_line" > "$_gi"
fi
if ! grep -qxF '.private/' "$_gi" 2>/dev/null; then
  [ -s "$_gi" ] && [ "$(tail -c1 "$_gi" 2>/dev/null; echo x)" != $'\nx' ] && printf '\n' >> "$_gi"
  printf '.private/\n' >> "$_gi"
fi

# Metadata-only coherence record. Never source this JSON or .sdp_runtime.env.
python3 "$SDP_SCRIPTS/config_discovery.py" write-provenance "$PROJECT_DIR" "$GATES" >/dev/null

# --- write runtime metadata (agents read values; scripts never source it) ---
DATE="${SDP_DATE:-$(date +%Y-%m-%d)}"
RUNTIME_ENV="$BASE_DIR/.sdp_runtime.env"
# POSIX-portable single-quote wrapping keeps metadata unambiguous for readers.
_shq() { local s=$1; s=${s//\'/\'\\\'\'}; printf "'%s'" "$s"; }
{
  printf 'SDP_ROOT=%s\n'           "$(_shq "$SDP_ROOT")"
  printf 'SDP_CORE=%s\n'           "$(_shq "$SDP_CORE")"
  printf 'SDP_SCRIPTS=%s\n'        "$(_shq "$SDP_SCRIPTS")"
  printf 'PROJECT_DIR=%s\n'        "$(_shq "$PROJECT_DIR")"
  printf 'BASE_DIR=%s\n'           "$(_shq "$BASE_DIR")"
  printf 'DATE=%s\n'               "$(_shq "$DATE")"
  printf 'OUTPUT_LOCALE=%s\n'      "$(_shq "$OUTPUT_LOCALE")"
  printf 'OUTPUT_LOCALE_MODE=%s\n' "$(_shq "$OUTPUT_LOCALE_MODE")"
  printf 'DEFAULTS=%s\n'           "$(_shq "$DEFAULTS")"
  printf 'GATES=%s\n'              "$(_shq "$GATES")"
  # Provenance. This file is written once per command entry and is NEVER
  # refreshed by a plugin reinstall, so between runs it can name an engine that
  # is no longer the installed one. When old plugin-cache versions are still on
  # disk -- they are, because live sessions hold them -- a stale SDP_ROOT still
  # resolves, and the stale engine runs silently. Recording which version wrote
  # this file, and when, is what lets `review_gate.py doctor` say so out loud
  # (a missing directory fails noisily; an old one that still exists does not).
  printf 'SDP_VERSION=%s\n'        "$(_shq "$SDP_VERSION")"
  printf 'ANCHORED_AT=%s\n'        "$(_shq "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
} > "$RUNTIME_ENV"

printf '%s\n' "$RUNTIME_ENV"
