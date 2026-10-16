#!/usr/bin/env bash
# usage: run-tail.sh <run_id> [chars=2500] -- print the END of the LATEST result's full final text
r=$1; n=${2:-2500}
PFT=(pf-task --home /home/matt/.pf-task --role coordinator)
tot=$("${PFT[@]}" run.result "{\"run_id\":\"$r\",\"limit\":1}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')
rc=$("${PFT[@]}" run.result "{\"run_id\":\"$r\",\"offset\":$((tot-1)),\"limit\":1}" | python3 -c 'import json,sys; d=json.load(sys.stdin)["results"][0]; print(d["evidence"]["receipt"])')
echo "[result $tot/$tot $rc]"
python3 -B /home/matt/recovery/gpu14/full_result.py "$r" "$rc" | tail -c "$n"
