#!/usr/bin/env bash
# gpu-14 driver for the CX-DEPUTY Codex coordinator lane (tsp-mc9m.41.995, 2026-10-03).
# Waits on each turn of <run>. If the turn ends with `CX_DEPUTY_STATUS state=CONTINUE`,
# the driver continues the lane with a fixed text. Every other outcome EXITS, which wakes
# gpu-14: HANDBACK, IDLE, a missing status line, a non-awaiting_release state, a supervisor
# rc != 0, the continue cap, or the wall cap.
# usage: cx-drive.sh <run_id> [max_continues=10] [wall_hours=30]
set -u
export PF_V2=1 PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-host.json
H=/home/matt/.pf-task-v2; PFT=$H/bin/pf-task; R=/home/matt/recovery/gpu14
# 2026-10-15: helpers moved out of the session scratchpad (lost on reboot/new session) into the durable gpu14 dir.
Sd=/home/matt/recovery/gpu14
run=$1; max=${2:-10}; wall=$(( $(date +%s) + ${3:-30} * 3600 )); n=0
A=$R/approvals-cx-deputy-g1.jsonl; touch "$A"
LOG=$R/cx-drive.log
cont=$R/cx-deputy-continue.txt
while :; do
  G=$(timeout 200 $PFT --home $H --role coordinator run.status "{\"run_id\":\"$run\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["generation"])') || { echo "DRIVER_EXIT reason=status_unreadable"; exit 0; }
  out=$(python3 $R/lane-supervisor.py "$run" "$G" "$A" 7 400 2>&1); rc=$?
  te=$(printf '%s\n' "$out" | /usr/bin/grep -E '^TURN_END' | tail -n 1)
  echo "$(date -u +%FT%TZ) rc=$rc $te" >> "$LOG"
  [ "$rc" -eq 0 ] || { printf '%s\n' "$out" | tail -n 5; echo "DRIVER_EXIT reason=supervisor_rc_$rc"; exit 0; }
  case "$te" in *"state=awaiting_release"*) ;; *) echo "$te"; echo "DRIVER_EXIT reason=turn_state"; exit 0 ;; esac
  st=$($Sd/rt2.sh "$run" 30000 2>&1 | /usr/bin/grep -E '^\**`?CX_DEPUTY_STATUS' | tail -n 1)
  echo "$(date -u +%FT%TZ) status: $st" >> "$LOG"
  case "$st" in
    *"state=CONTINUE"*)
      n=$((n+1))
      if [ "$n" -gt "$max" ]; then echo "$st"; echo "DRIVER_EXIT reason=continue_cap n=$n"; exit 0; fi
      if [ "$(date +%s)" -ge "$wall" ]; then echo "$st"; echo "DRIVER_EXIT reason=wall_cap"; exit 0; fi
      s=$($Sd/send.sh "$run" "$cont" cxd-cont 2>&1)
      echo "$(date -u +%FT%TZ) continue#$n -> $s" >> "$LOG"
      case "$s" in *refused*|*error*|"") echo "$s"; echo "DRIVER_EXIT reason=send_failed"; exit 0 ;; esac
      sleep 20 ;;
    *) echo "${st:-<no CX_DEPUTY_STATUS line>}"; $Sd/rt2.sh "$run" 2500; echo "DRIVER_EXIT reason=lane_status"; exit 0 ;;
  esac
done
