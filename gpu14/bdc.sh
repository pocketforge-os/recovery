#!/usr/bin/env bash
# gpu-14 bead comment helper (forcing function; rebuilt 2026-10-11 after an accidental overwrite, same contract).
# usage: bdc.sh <bead-id> <<'EOF'
#        body text (QUOTED heredoc: no expansion, backticks stay literal)
#        EOF
# - stamps `date -u` itself (2026-10-06: typed times were hours off), REFUSES a body whose first line starts
#   with a timestamp;
# - body comes only from stdin, so callers use a quoted heredoc (2026-10-11: an unquoted heredoc executed a
#   backticked `pf-lock` and dropped it from a .995.50 comment).
set -euo pipefail
id=${1:?bead id}
body=$(cat)
[ -n "$body" ] || { echo "BDC_REFUSED reason=empty_body" >&2; exit 2; }
first=$(printf '%s\n' "$body" | head -n1)
if printf '%s' "$first" | grep -qE '^[[:space:]]*(gpu-14[[:space:]]+)?(\[?[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2})?|[0-9]{1,2}:[0-9]{2}Z)'; then
  echo "BDC_REFUSED reason=typed_timestamp first_line=$(printf '%s' "$first" | cut -c1-60) hint=drop it; bdc.sh stamps date -u" >&2; exit 2
fi
cd /home/matt/mission-control
printf 'gpu-14 %s: %s\n' "$(date -u +%FT%TZ)" "$body" | bd comment "$id" --stdin
