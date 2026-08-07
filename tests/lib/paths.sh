# tests/lib/paths.sh — the single definition of SDP_ROOT / PLUGIN_ROOT.
#
# SDP_ROOT = the repo root; PLUGIN_ROOT = the one plugin root for both hosts.
# ADR-005's P11 tree move landed: marketplace `source` now points at
# `./plugins/sdp`, so PLUGIN_ROOT is `$SDP_ROOT/plugins/sdp` (the canonical tree).
# Centralising both here keeps the move (and P12's root-mirror deletion) a
# one-line change, not 13 separate edits. Source it as:
#
#   . "$(cd "$(dirname "$0")" && pwd)/lib/paths.sh"
#
# shellcheck shell=bash
SDP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_ROOT="$SDP_ROOT/plugins/sdp"
export SDP_ROOT PLUGIN_ROOT
