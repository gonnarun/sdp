#!/usr/bin/env bash
# =============================================================================
# SDP 6-project regression harness (AC-12 / NFR-07).
# "After de-domaining/renaming, confirm the plugin installs/anchors cleanly and
#  its gate is not weakened across the reference projects." (design §4 step 10)
#
# Per-project checks (derived from AC-12 / NFR-07 / REQ-U-02·03·05·07 / REQ-P-03):
#   1 config discoverable  : project override OR user-global fallback (REQ-U-05)
#   2 anchor resolves      : sdp-anchor.sh writes runtime env + creates/gitignores
#                            .private (REQ-P-03 / REQ-U-07) — idempotent, safe to re-run
#   3 no forced_ext weaken : sdp_cfg_check_no_weakening passes (base safety keys not weakened)
#   4 gate strength intact : (a) BASELINE escalate_from <= 6 AND marker_span <= 1 AND
#                            max_block <= 13 — a project may always make the gate
#                            EARLIER/STRICTER. Relaxing past baseline is allowed only
#                            inside the sanctioned envelope (<=8 / <=4 / <=13) AND only
#                            with an explicit cadence.relaxation_ack, reported loudly.
#                            (b) COMBINATION: the anchors over rounds
#                            [escalate_from, max_block] must demand TEAM_REVIEW at
#                            least once — otherwise a legal ef/span/review_on triple
#                            makes every window TEAM_CARRY and no fresh outputs=
#                            evidence is ever required.
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

  # 1 canonical discovery: local override -> XDG/passwd-home; no file uses built-ins.
  defaults="$(sdp_cfg_discover "$p" defaults.yaml)" || { bad "defaults discovery failed (REQ-U-05)"; return; }
  gates="$(sdp_cfg_discover "$p" gates.yaml)" || { bad "gates discovery failed (REQ-U-05)"; return; }
  if [ -n "$defaults" ]; then ok "config discoverable ($defaults)"; else ok "no defaults override (safe built-ins)"; fi

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
    local ef mb ms ro ack
    ef="$(cfgv "$gates" cadence.escalate_from)"; mb="$(cfgv "$gates" halt.max_block)"
    ms="$(cfgv "$gates" cadence.marker_span)"; ro="$(cfgv "$gates" cadence.review_on)"
    ack="$(cfgv "$gates" cadence.relaxation_ack)"
    case "$ef" in ''|*[!0-9]*) ef=6 ;; esac
    case "$mb" in ''|*[!0-9]*) mb=13 ;; esac
    case "$ms" in ''|*[!0-9]*) ms=1 ;; esac
    [ "$ro" = "odd" ] || ro=even

    # 4a BASELINE (the shipped default: escalate_from 6, marker_span 1). A project
    # may always make the gate EARLIER/STRICTER. Going LATER/LOOSER is not silently
    # certified any more: it requires an explicit cadence.relaxation_ack, which is
    # reported loudly so a widened ceiling can never ride along unnoticed.
    if [ "$ef" -le 6 ] && [ "$ms" -le 1 ] && [ "$mb" -le 13 ]; then
      ok "gate thresholds at or below baseline (escalate_from=$ef<=6, marker_span=$ms<=1, max_block=$mb<=13)"
    elif [ -n "$ack" ] && [ "$ef" -le 8 ] && [ "$ms" -le 4 ] && [ "$mb" -le 13 ]; then
      ok "gate RELAXED within the sanctioned envelope, declared: escalate_from=$ef<=8 marker_span=$ms<=4 max_block=$mb<=13 (relaxation_ack=$ack)"
    elif [ -z "$ack" ] && { [ "$ef" -gt 6 ] || [ "$ms" -gt 1 ]; }; then
      bad "gate relaxed past baseline without cadence.relaxation_ack (escalate_from=$ef, marker_span=$ms); declare the reason or restore 6/1"
    else
      bad "gate weakened beyond the sanctioned envelope (escalate_from=$ef, max_block=$mb, marker_span=$ms; envelope is <=8 / <=13 / <=4)"
    fi

    # 4b COMBINATION invariant. The three scalars above are independent, but the
    # property that matters is joint: with a wide span the required marker KIND is
    # fixed by each window's anchor parity, so ef=7/span=4/review_on=even (anchors
    # 7,11) or ef=8/span=4/review_on=odd (anchors 8,12) make EVERY window a
    # TEAM_CARRY -- which carries no outputs=, so fresh evidence is never demanded
    # anywhere in the escalation range. Simulate the anchors and require at least
    # one TEAM_REVIEW window (codex review, HIGH-1).
    # NOTE the loop variable is `round`, NOT `p`: `p` is check_project's project
    # path and shadowing it here silently redirected check 5's relative
    # review_checklist_include lookup to the caller's cwd (codex review, F1).
    #
    # RANGE is HALF-OPEN [escalate_from, max_block). review_gate.py returns the
    # max_block halt BEFORE the escalation block, so round == max_block never
    # consults the cadence at all; counting it can invent a TEAM_REVIEW window that
    # never executes (codex review, F2).
    #
    # An EMPTY range (escalate_from >= max_block) is NOT a weakening and must not be
    # rejected (codex review, F3). The existential below guards against a cadence
    # that lets the reviewer keep returning ALLOW without ever citing fresh
    # evidence. With no permissive escalation round at all there is no such path:
    # the gate halts and demands human intervention instead. That is strictly
    # earlier/stricter -- the extreme of the already-permitted "lower max_block" --
    # so the existential applies only when the range is non-empty. Requiring a team
    # review before every halt would be a separate, user-approved requirement.
    local round anchor kind seen_review=no
    round="$ef"
    while [ "$round" -lt "$mb" ]; do
      anchor=$(( round - ( (round - ef) % ms ) ))
      if [ $(( anchor % 2 )) -eq 0 ]; then
        [ "$ro" = "odd" ] && kind=TEAM_CARRY || kind=TEAM_REVIEW
      else
        [ "$ro" = "odd" ] && kind=TEAM_REVIEW || kind=TEAM_CARRY
      fi
      [ "$kind" = "TEAM_REVIEW" ] && seen_review=yes
      round=$(( round + 1 ))
    done
    if [ "$ef" -ge "$mb" ]; then
      ok "no permissive escalation window: max_block=$mb <= escalate_from=$ef, so the halt precedes escalation (earlier/stricter, not a bypass)"
    elif [ "$seen_review" = yes ]; then
      ok "cadence demands fresh TEAM_REVIEW evidence at least once in rounds $ef-$((mb - 1)) (span=$ms, review_on=$ro)"
    else
      bad "cadence never demands a TEAM_REVIEW in rounds $ef-$((mb - 1)) (escalate_from=$ef, marker_span=$ms, review_on=$ro): every window anchor is TEAM_CARRY, so outputs= evidence is never required"
    fi

    # 5 fail-closed checklist (AC-12): require_checklist=true => include must be a non-empty file
    local rc inc
    rc="$(cfgv "$gates" require_checklist)"; inc="$(cfgv "$gates" review_checklist_include)"
    if [ "$rc" = "true" ]; then
      # Resolve the include the way the gate does: absolute as given, relative under
      # the PROJECT. The old `|| [ -s "$inc" ]` fallback resolved a relative include
      # against the CALLER'S CWD, which is what let a repo-root run mask F1 -- a
      # harness whose verdict depends on where it was invoked from proves nothing.
      local incpath=""
      case "$inc" in
        /*) incpath="$inc" ;;
        "") incpath="" ;;
        *)  incpath="$p/$inc" ;;
      esac
      if [ -n "$incpath" ] && [ -s "$incpath" ]; then ok "fail-closed checklist satisfied (require_checklist + include present)"; \
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
