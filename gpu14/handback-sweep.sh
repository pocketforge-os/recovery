#!/usr/bin/env bash
# gpu-14 2026-10-11: qdbus pft-1a82405a sat on a HANDBACK for 13 h (2026-10-10 12:45Z -> 01:50Z) because my
# lane sweeps were hand-typed lists that had dropped it. This lists EVERY <lane>-drive.log touched in the
# last N hours whose lane has no live lane-drive.sh and whose run is not released: those lanes are waiting
# on gpu-14 with nothing to wake it. Read-only (run.status primary-key lookups only).
# usage: handback-sweep.sh [hours=72]
set -uo pipefail
G=/home/matt/recovery/gpu14; hours=${1:-72}
live=$(ps -eo args | /usr/bin/grep -E '[l]ane-drive\.sh pft-' || true)
n=0
while IFS= read -r log; do
  lane=$(basename "$log" -drive.log)
  run=$(/usr/bin/grep -oE 'driver start run=pft-[0-9a-f]{24}' "$log" | tail -n 1 | cut -d= -f2)
  [ -n "$run" ] || continue
  printf '%s\n' "$live" | /usr/bin/grep -qF -- "$run" && continue
  st=$(/usr/bin/grep -oE '[A-Z0-9_]+_STATUS state=[A-Z_]+[^"]{0,120}' "$log" | tail -n 1)
  ts=$(/usr/bin/grep -E 'status\(result' "$log" | tail -n 1 | cut -c1-20)
  # Read-only caller: registry-only lookup.  It must not spend a positive probe
  # per cached row or turn a transient service stall into a false board alarm.
  if ! resolved_home=$("$G/pf-task-run-home" lookup "$run" --format shell); then
    echo "UNDRIVEN lane=$lane run=$run run_state=unresolved last_status_at=${ts:-?} ${st:-<no status line>}"; n=$((n+1)); continue
  fi
  eval "$resolved_home"
  rs=$(timeout 60 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$run\"}" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state","?"))' 2>/dev/null || echo "?")
  case "$rs" in released) continue ;; esac
  n=$((n+1))
  printf 'UNDRIVEN lane=%s run=%s run_state=%s last_status_at=%s %s\n' "$lane" "$run" "$rs" "${ts:-?}" "${st:-<no status line>}"
done < <(find "$G" -maxdepth 1 -name '*-drive.log' -mmin -$((hours * 60)) | sort)
echo "SWEEP undriven=$n hours=$hours at=$(date -u +%FT%TZ)"
