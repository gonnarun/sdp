#!/usr/bin/env bash
# =============================================================================
# SDP 6-project regression harness (AC-12 / NFR-07).
# "After de-domaining/renaming, confirm the plugin installs/anchors cleanly and
#  its gate is not weakened across the reference projects." (design §4 step 10)
#
# Per-project checks (derived from AC-12 / NFR-07 / REQ-U-02·03·05·07 / REQ-P-03):
#   1 config discoverable  : .sdp/defaults.yaml OR scripts/sdp/defaults.yaml (REQ-U-05)
#   2 anchor resolves      : sdp-anchor.sh writes runtime env + creates/gitignores
#                            .private (REQ-P-03 / REQ-U-07) — idempotent, safe to re-run
#   3 no forced_ext weaken : sdp_cfg_check_no_weakening passes (base safety keys not weakened)
#   4 gate strength intact : gates.yaml cadence.escalate_from <= 6 AND halt.max_block <= 13
#                            (a project may only make the gate EARLIER/STRICTER, never later)
#   5 fail-closed checklist: if gates require_checklist=true, review_checklist_include must be
#                            set to a non-empty existing file (AC-12: no silent domain-gate skip)
# Plugin preflight (once): agy fallback + gate script + 3 command adapters shipped (REQ-G-09/P-01).
#
# Projects (colon-separated) resolved from, in order: CLI args > SDP_REGRESSION_PROJECTS env >
#   regression.projects in the plugin's .sdp/defaults.yaml. Empty = nothing to run (neutral skip).
# NEVER hardcodes machine paths. Run natively pointed at the 6 real repos.
# Usage: sdp-regression.sh [project-dir ...]
# =============================================================================
set -u
_src="${BASH_SOURCE[0]:-$0}"
SDP_SCRIPTS="$(cd "$(dirname "$_src")" && pwd)"
SDP_ROOT="$(cd "$SDP_SCRIPTS/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$SDP_SCRIPTS/lib/sdp-config.sh" ] && . "$SDP_SCRIPTS/lib/sdp-config.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }
hdr() { printf '== %s ==\n' "$1"; }

# ---- resolve project list: args > env > config (colon-separated) ----
PROJECTS=""
if [ "$#" -gt 0 ]; then
  PROJECTS="$*"
elif [ -n "${SDP_REGRESSION_PROJECTS:-}" ]; then
  PROJECTS="$(printf '%s' "$SDP_REGRESSION_PROJECTS" | tr ':' ' ')"
elif [ -f "$SDP_ROOT/.sdp/defaults.yaml" ] && command -v sdp_cfg_get >/dev/null 2>&1; then
  PROJECTS="$(sdp_cfg_get "$SDP_ROOT/.sdp/defaults.yaml" regression.projects | tr ':' ' ')"
fi

# ---- plugin preflight (constant across all projects) ----
hdr "plugin preflight (REQ-G-09 / REQ-P-01)"
# P9: codex-gate.sh + agy-gate-fallback.sh retired; the gate is now review_gate.py
# (its ported controls + agy fallback live in-process). Preflight the surviving gate.
if [ -f "$SDP_SCRIPTS/review_gate.py" ]; then ok "review_gate.py shipped (single source)"; else bad "review_gate.py missing"; fi
for c in sdp batch-sdp worktree-dispatch; do
  if [ -f "$SDP_ROOT/commands/$c.md" ]; then ok "command adapter $c.md present"; else bad "command adapter $c.md missing"; fi
done

# ---- per-project checks ----
cfgv() { sdp_cfg_get "$1" "$2" 2>/dev/null; }
check_project() {
  local p="$1" defaults="" gates=""
  hdr "project: $p"
  [ -d "$p" ] || { bad "project dir not found: $p"; return; }

  # 1 config discoverable (REQ-U-05 order)
  for c in "$p/.sdp/defaults.yaml" "$p/scripts/sdp/defaults.yaml"; do [ -f "$c" ] && { defaults="$c"; break; }; done
  if [ -n "$defaults" ]; then ok "config discoverable ($(basename "$(dirname "$defaults")")/$(basename "$defaults"))"; else bad "no defaults.yaml (REQ-U-05)"; fi
  for c in "$p/.sdp/gates.yaml" "$p/scripts/sdp/gates.yaml"; do [ -f "$c" ] && { gates="$c"; break; }; done

  # 2 anchor resolves (REQ-P-03 / REQ-U-07) — idempotent
  local rt
  rt="$(CLAUDE_PROJECT_DIR="$p" bash "$SDP_SCRIPTS/sdp-anchor.sh" 2>/dev/null)" || true
  if [ -n "$rt" ] && [ -f "$rt" ] && grep -q '^BASE_DIR=' "$rt" 2>/dev/null && [ -d "$p/.private" ] && grep -qxF '.private/' "$p/.gitignore" 2>/dev/null; then
    ok "anchor resolves (runtime env + .private + gitignore)"
  else
    bad "anchor did not resolve cleanly (REQ-P-03/U-07)"
  fi

  # 3 no forced_ext weakening
  if [ -n "$defaults" ] && command -v sdp_cfg_check_no_weakening >/dev/null 2>&1; then
    if sdp_cfg_check_no_weakening "$defaults" >/dev/null 2>&1; then ok "no forced_ext weakening"; else bad "forced_ext weakens base safety keys"; fi
  fi

  # 4 gate-strength thresholds not weakened (AC-12) — only if the project overrides them
  if [ -n "$gates" ]; then
    local ef mb
    ef="$(cfgv "$gates" cadence.escalate_from)"; mb="$(cfgv "$gates" halt.max_block)"
    case "$ef" in ''|*[!0-9]*) ef=6 ;; esac
    case "$mb" in ''|*[!0-9]*) mb=13 ;; esac
    if [ "$ef" -le 6 ] && [ "$mb" -le 13 ]; then
      ok "gate thresholds not weakened (escalate_from=$ef<=6, max_block=$mb<=13)"
    else
      bad "gate weakened (escalate_from=$ef, max_block=$mb; must be <=6 / <=13)"
    fi

    # 5 fail-closed checklist (AC-12): require_checklist=true => include must be a non-empty file
    local rc inc
    rc="$(cfgv "$gates" require_checklist)"; inc="$(cfgv "$gates" review_checklist_include)"
    if [ "$rc" = "true" ]; then
      if [ -n "$inc" ] && { [ -s "$p/$inc" ] || [ -s "$inc" ]; }; then ok "fail-closed checklist satisfied (require_checklist + include present)"; \
      else bad "require_checklist=true but review_checklist_include missing/empty (gate would BLOCK — AC-12)"; fi
    else
      ok "checklist not required (core minimal security baseline applies)"
    fi
  fi
}

if [ -z "${PROJECTS// /}" ]; then
  printf '\n(no regression projects configured — set regression.projects in .sdp/defaults.yaml,\n or SDP_REGRESSION_PROJECTS=/p1:/p2, or pass paths as args. Neutral skip.)\n'
else
  for p in $PROJECTS; do check_project "$p"; done
fi

printf '\n== regression summary: %s passed, %s failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
