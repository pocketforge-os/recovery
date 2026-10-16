#!/usr/bin/env bash
. /home/matt/recovery/gpu14/current-lanes.env
# gpu-14 30-minute check-in timer (owner request 2026-10-03). Waits, then prints a compact digest
# of the CX-DEPUTY lane so the check-in needs few extra reads.
# usage: checkin-digest.sh [wait_seconds=1800]
set -u
sleep "${1:-1800}"
export PF_TASK_HOST_CONFIG=/home/matt/.config/pocketforge/pf-task-host.json
H=/home/matt/.pf-task-v2; R=/home/matt/recovery/gpu14
echo "CHECKIN_DUE at=$(date -u +%FT%TZ)"
pgrep -u matt -f "lane-drive.sh ${DEPUTY_RUN:0:12}" >/dev/null && echo "driver=ALIVE" || echo "driver=GONE"
timeout 90 $H/bin/pf-task --home $H --role coordinator run.status "{\"run_id\":\"$DEPUTY_RUN\"}" 2>/dev/null | jq -r '"deputy state=\(.state) alive=\(.controller_alive) native_age=\(.native_activity_age_seconds)"'
echo "--- drive log"; tail -n 4 $R/cx-drive.log 2>/dev/null | cut -c1-300
echo "--- queue (last 6)"; tail -n 6 $R/device-queue.txt | cut -c1-420
cd /home/matt/mission-control && for b in tsp-mc9m.41.995 tsp-mc9m.41.997; do echo "--- $b last comment"; bd comments $b --json 2>/dev/null | jq -r '.[-1] | "\(.created_at) \(.text[0:1200])"'; done
echo "--- deputy peek"; PYTHONDONTWRITEBYTECODE=1 python3 $R/lane-peek.py $DEPUTY_RUN 12
echo "--- place"; pf-automation-tool pf-device.sh status tsp 2>&1 | /usr/bin/grep -E 'labgrid place' | cut -c1-160
