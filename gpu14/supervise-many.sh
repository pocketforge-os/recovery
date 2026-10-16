#!/usr/bin/env bash
# gpu-14: supervise several managed Codex runs from ONE background task.
# usage: supervise-many.sh <run_id>:<generation>:<approvals.jsonl> [...]
# Starts lane-supervisor.py per run; when the FIRST one exits (TURN_END, FOREIGN, ...) it prints that
# run's result, stops the other supervisors (they only watch), and prints the re-arm line for the rest.
set -uo pipefail
D=/home/matt/recovery/gpu14/supervise-many.d; mkdir -p "$D"
declare -A PID SPEC
for s in "$@"; do
  IFS=: read -r run gen appr <<<"$s"
  python3 /home/matt/recovery/gpu14/lane-supervisor.py "$run" "$gen" "$appr" 8 400 > "$D/$run.log" 2>&1 &
  PID[$run]=$!; SPEC[$run]=$s
done
wait -n
rest=()
for run in "${!PID[@]}"; do
  if kill -0 "${PID[$run]}" 2>/dev/null; then rest+=("${SPEC[$run]}"); kill "${PID[$run]}" 2>/dev/null
  else echo "== EXITED $run"; tail -n 3 "$D/$run.log"; fi
done
wait 2>/dev/null
echo "REARM: /home/matt/recovery/gpu14/supervise-many.sh ${rest[*]}"
