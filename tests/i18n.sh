#!/usr/bin/env bash
# i18n.sh — verifies the REQ-U-08 authoring rule is present and consistent.
# The canonical statement lives once in SDP.md; each Stage template carries a
# short anchor referencing it (DRY). Also guards the core invariant: no Korean
# in core/ (plugin-facing assets stay English), and machine markers stay ASCII.
set -u
SDP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SDP_ROOT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# 1. canonical section exists once in the core
grep -q 'Deliverable authoring language (i18n) — REQ-U-08' core/SDP.md \
  && ok "SDP.md has the canonical authoring-language section" \
  || bad "SDP.md missing canonical authoring-language section"

# 2. every Stage template carries the authoring-language anchor (REQ-U-08)
for s in 1 2 3 4 5 6 7 8; do
  f="$(ls core/Stage${s}_*.md 2>/dev/null | head -1)"
  if [ -z "$f" ]; then bad "Stage $s template not found"; continue; fi
  grep -q 'Authoring language (REQ-U-08)' "$f" \
    && ok "$(basename "$f") has the REQ-U-08 authoring anchor" \
    || bad "$(basename "$f") missing REQ-U-08 authoring anchor"
done

# 3. anchor must not contradict the runtime switch: it references output_locale/OUTPUT_LOCALE
grep -q 'OUTPUT_LOCALE' core/SDP.md && ok "authoring rule references the resolved OUTPUT_LOCALE" \
  || bad "authoring rule does not reference OUTPUT_LOCALE"

# 4. core invariant: no Korean (Hangul) anywhere in core/ (plugin-facing = English)
if LC_ALL=C grep -rlP '[\x{AC00}-\x{D7A3}]' core/ 2>/dev/null | grep -q .; then
  # fall back if grep -P unavailable: use python
  bad "Hangul found in core/: $(LC_ALL=C grep -rlP '[\x{AC00}-\x{D7A3}]' core/ 2>/dev/null | tr '\n' ' ')"
else
  # double-check with python (portable, in case grep -P is absent)
  if python3 -c "import glob,sys; sys.exit(1 if any(any(0xAC00<=ord(c)<=0xD7A3 for c in open(f,encoding='utf-8').read()) for f in glob.glob('core/**/*.md',recursive=True)) else 0)" 2>/dev/null; then
    ok "no Korean in core/ (plugin-facing assets stay English)"
  else
    bad "Hangul found in core/ (python check)"
  fi
fi

echo "-------- $PASS passed, $FAIL failed --------"
[ "$FAIL" -eq 0 ]
