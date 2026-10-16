#!/usr/bin/env bash
# usage: rt2.sh <run_id> [chars] -- resolved-home run-tail
r=$1; n=${2:-3000}; R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
resolved_home=$("$R/pf-task-run-home" resolve "$r" --format shell) || { echo "RT2_REFUSED reason=run_home_unresolved run=$r" >&2; exit 2; }
eval "$resolved_home"
P=("$PFT" --home "$H" --role coordinator)
tot=$("${P[@]}" run.result "{\"run_id\":\"$r\",\"limit\":1}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')
rc=$("${P[@]}" run.result "{\"run_id\":\"$r\",\"offset\":$((tot-1)),\"limit\":1}" | python3 -c 'import json,sys; d=json.load(sys.stdin)["results"][0]; print(d["evidence"]["receipt"])')
echo "[result $tot $rc]"
python3 -B "$R/full_result.py" "$r" "$rc" | tail -c "$n"
