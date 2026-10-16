#!/usr/bin/env bash
# gpu-14 2026-10-13: append a bead comment from STDIN with a clock stamp added here, so callers always use a QUOTED
# heredoc (bd-note.sh <bead> <<'EOF'). Why: an unquoted heredoc (needed only for $(date)) executed the backticked
# `debug`, `journalctl ...` and `sudo -n journalctl` from the comment text; the cached sudo started dumping the laptop
# journal into the comment before it was killed (witness #6 of unquoted-heredoc-executes-backticks).
set -euo pipefail
export BEADS_DIR=${BEADS_DIR:-/home/matt/mission-control/.beads}  # works from any cwd
bead=${1:?usage: bd-note.sh <bead> <<'EOF' ... EOF}
body=$(cat)
[ -n "$body" ] || { echo "BD_NOTE_REFUSED reason=empty_body"; exit 2; }
[ "${#body}" -le 60000 ] || { echo "BD_NOTE_REFUSED reason=body_too_large bytes=${#body}"; exit 2; }
# 2026-10-13: three comments led with typed times (18:45Z/18:55Z) ahead of the clock (18:41Z); this helper
# already stamps date -u, so a typed lead time is both redundant and wrong. Same guard as bdc.sh.
first=$(printf '%s\n' "$body" | head -n1)
if printf '%s' "$first" | grep -qE '^[[:space:]]*(gpu-14[[:space:]]+)?(\[?[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2})?|~?[0-9]{1,2}:[0-9]{2}Z)'; then
  echo "BD_NOTE_REFUSED reason=typed_timestamp first_line=$(printf '%s' "$first" | cut -c1-60) hint=drop it; bd-note.sh stamps date -u"; exit 2
fi
printf 'gpu-14 %s: %s\n' "$(date -u +%FT%TZ)" "$body" | timeout 90 bd comment "$bead" --stdin
