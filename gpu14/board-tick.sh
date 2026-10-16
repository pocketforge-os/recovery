#!/usr/bin/env bash
# gpu-14 2026-10-11: the owner's ~20-min board tick lapsed for 6.6 h (13:11Z -> 19:50Z) because re-arming it was a
# remembered step. This is the whole tick as one background command: sleep, sweep undriven lanes, refresh the board,
# print what needs gpu-14, then EXIT, so the harness notification itself is the reminder to act and re-arm.
# usage (always run_in_background): board-tick.sh [sleep_s=1200]
# After acting on the output: publish fleet-board/fleet-board.html to the board URL, then start the next tick.
set -uo pipefail
R=/home/matt/recovery/gpu14
sleep "${1:-1200}"
echo "TICK start=$(date -u +%FT%TZ)"
echo "--- handback-sweep (undriven lanes)"
sw=$(PF_V2=1 timeout 300 "$R/handback-sweep.sh" 24 2>&1)
parked=$(cut -f1 "$R/fleet-board/parked.tsv" | grep -E '^pft-' | sort -u)
printf '%s\n' "$sw" | while IFS= read -r line; do
  run=$(printf '%s' "$line" | grep -oE 'run=pft-[0-9a-f]+' | cut -d= -f2)
  if [ -n "$run" ] && printf '%s\n' "$parked" | grep -qx "$run"; then continue; fi
  printf '%s\n' "$line" | cut -c1-300
done
echo "(parked runs hidden: $(printf '%s\n' "$sw" | grep -oE 'run=pft-[0-9a-f]+' | cut -d= -f2 | grep -cxF -f <(printf '%s\n' "$parked")))"
echo "--- board refresh"
timeout 300 "$R/fleet-board/refresh.sh" 2>&1 | cut -c1-400
echo "TICK end=$(date -u +%FT%TZ) next=publish fleet-board.html, act on NEEDS_GPU14, re-arm board-tick.sh"
