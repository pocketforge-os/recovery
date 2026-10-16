#!/usr/bin/env bash
# gpu-14 Steam Link lane check-in timer (owner 2026-10-03: "check in on that one quite often to begin with").
# usage: sl-checkin.sh [wait_seconds=900]
set -u
sleep "${1:-900}"
R=/home/matt/recovery/gpu14
echo "SL_CHECKIN_DUE at=$(date -u +%FT%TZ)"
pgrep -u matt -f 'lane-drive.sh pft-0ad3c95c' >/dev/null && echo "sl-driver=ALIVE" || echo "sl-driver=GONE"
echo "--- sl-drive log"; tail -n 3 $R/sl-drive.log 2>/dev/null | cut -c1-300
PYTHONDONTWRITEBYTECODE=1 python3 $R/lane-peek.py pft-0ad3c95c9b9561614efd450f 18
cd /home/matt/mission-control && echo "--- tsp-mc9m.41.996 last comment" && bd comments tsp-mc9m.41.996 --json 2>/dev/null | jq -r '.[-1] | "\(.created_at) \(.text[0:1000])"'
echo "--- vendor dir"; ls -la /home/matt/recovery/steamlink-vendor/ 2>/dev/null | tail -n +2 | head -8
